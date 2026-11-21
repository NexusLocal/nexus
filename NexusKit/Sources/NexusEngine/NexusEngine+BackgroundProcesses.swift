import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// One program of the list of a site. owner names the workspace or the main checkout. worktree is the
// root of the linked worktree of this program. git removes only such a worktree. So a program in a
// real main checkout has none. A site can have its folder in a linked worktree. devServerCommand is
// the command of the plan of a dev server, with {port:vite}. A failure records that command. The
// next sync compares the failure with the plan (owner, 2026-11-15). server names a database server
// of a workspace, for the gate of its port.
struct BackgroundProcess: Sendable, Equatable {
    let owner: String
    let command: String
    let log: String
    let worktree: String?
    let definition: ServiceDefinition
    var devServerCommand: String?
    var server: GatedServer?

    var isDevServer: Bool {
        devServerCommand != nil
    }
}

// What the main checkout needs for its list. These values come from a probe. A workspace keeps them
// in its record, but the main checkout has no record. viteFileDates is only in the plan of the dev
// server. A change of these dates reads the folder again (owner, 2026-11-15).
struct MainProcessPlan: Sendable {
    let folder: String
    let preset: [String]
    let database: String?
    let reverbPort: Int?
    var ports: [String: Int] = [:]
    var viteFileDates: [String: Date] = [:]
}

struct MainProbeFailure: Sendable {
    let nextProbe: ContinuousClock.Instant
    let reason: String
}

// The background processes of a site (D52). Each workspace that is ready runs its own copy of the
// list. The main checkout runs one when its switch is on. A workspace that is not isolated runs
// nothing (D48). These programs have their own supervisor, so they do not show as services. One list
// decides what must run, so a change only asks for a sync. Each request that can change something
// ends with a sync, through reconcileWorkspaces.
extension NexusEngine {
    static let processMarker = BackgroundProcessMarker.name
    static let nodeLineKey = "NEXUS_SITE_NODE"
    private static let mainProbeWait: Duration = .seconds(60)
    private static let worktreeWatchLatency: TimeInterval = 0.05
    // The options before the subcommand of git that take their value as the next argument.
    private static let gitOptionsWithValue: Set<String> = ["-C", "-c", "--attr-source", "--config-env", "--git-dir", "--namespace", "--super-prefix", "--work-tree"]

    // One run at a time, because two runs could start one program two times. A request during a run
    // gives one more run. The task ends after the last run.
    func syncBackgroundProcesses() -> Task<Void, Never> {
        if let running = processSync {
            processSyncAgain = true
            return running
        }

        let sync = Task { await runProcessSync() }
        processSync = sync
        return sync
    }

    // processSupervisor has one change handler. The background processes and the links both need it.
    func observeProcessChanges() async {
        guard !observesProcesses else {
            return
        }

        observesProcesses = true
        await processSupervisor.onChange { [weak self] in
            Task {
                await self?.backgroundProcessesChanged()
                await self?.shareProgramsChanged()
            }
        }
    }

    private func runProcessSync() async {
        await observeProcessChanges()

        repeat {
            processSyncAgain = false

            // One read of the state and of the installed runtimes for each run. The list of the
            // processes and the list for the gate both come from it. After "Stop all services" only
            // the list for the gate needs servers, and only those of the stopped workspaces.
            let state = await stateStore.current()
            let servicesStopped = await servicesAreStopped()
            let servers = await workspaceServers(state, includesRunning: !servicesStopped)
            let (wanted, serverStopCauses) = await wantedProcesses(state, servers: servers, servicesStopped: servicesStopped)
            let restartsFailed = restartFailedProcesses

            restartFailedProcesses = false

            // The gate of the database ports gets the servers that stop in this run before their
            // stop, and keeps the servers that start in this run until after their start (owner,
            // 2026-11-15).
            let hold = Self.serversToHold(servers)
            let gate = serverGate

            await gate.hold(heldServers.union(hold))

            // A start of a stopped workspace starts its servers past the sync. That start can come
            // after the list of this run, so its servers are not outdated.
            let failed = restartsFailed ? await failedProcesses() : []
            let outdated = Array(runningProcesses.filter { id, process in
                (wanted[id] != process || failed.contains(id)) && !(workspaceStarts[process.owner] != nil && wanted[id] == nil)
            }.keys)

            await withTaskGroup { group in
                for id in outdated {
                    let server = runningProcesses[id]?.server
                    let cause = Self.stopCause(of: id, wanted: wanted, failed: failed, serverStopCauses: serverStopCauses, servicesStopped: servicesStopped)

                    group.addTask {
                        guard let server else {
                            try? await self.processSupervisor.stop(id, cause: cause)
                            return
                        }

                        await self.stopServer(id, server, cause: cause)
                    }
                }
            }

            // A dev server that got SIGKILL after the stop timeout leaves public/hot (owner,
            // 2026-11-15).
            for id in outdated {
                if let process = runningProcesses[id], process.isDevServer, let folder = process.definition.workingDirectory {
                    checkHotFile(in: folder.path(percentEncoded: false), log: process.log)
                }
            }

            // stopServer removed each server already. A connection during its stop can start it
            // again before this line.
            for id in outdated where runningProcesses[id]?.server == nil {
                runningProcesses[id] = nil
            }

            // The list can come from before a "Stop all services" that ended during the probe of this
            // run or during the stops above.
            let servicesWait = await waitsForStoppedServices()

            for (id, process) in wanted.sorted(by: { $0.key < $1.key }) where runningProcesses[id] == nil && !servicesWait && !watchingStopped && !stoppingAllServices {
                // An update can start after the list of this run, and it replaces the files of a
                // database server. It does not wait for this run, so this run must not start one.
                if updatingServices.contains(process.log) {
                    continue
                }

                // No start in a worktree that git removes now. That removal can start after the list
                // of this run. The watch comes before the start, so no removal falls between them.
                if let worktree = process.worktree {
                    if removingWorktrees.contains(worktree) {
                        continue
                    }

                    watch(worktree)
                }

                guard let reason = await startProcess(process) else {
                    continue
                }

                guard let command = process.devServerCommand else {
                    plannedProcessProblems[process.owner, default: []].append("The background process \(process.command) does not run. \(reason)")
                    continue
                }

                // A dev server without a failure keeps the wait page of nginx (owner, 2026-11-15).
                // The page of the failure sends the user to this log.
                writeToLog(of: process.log, "\(reason)\n")
                recordDevServerFailure(of: process.owner, command: command, reason: reason)
            }

            // A start past the sync can run a server of the list of this run already.
            let running = runningProcesses.values.compactMap(\.server)
            let held = hold.filter { server in !running.contains { $0.isSame(as: server) } }

            await gate.hold(held)
            heldServers = held
            watchWorktrees()
            await backgroundProcessesChanged()
        } while processSyncAgain

        processSync = nil
    }

    // The cause of the stop of a program that the list of this run does not want, for the activity
    // log. Only a database server of a workspace gets a line.
    private static func stopCause(of id: String, wanted: [String: BackgroundProcess], failed: Set<String>, serverStopCauses: [String: String], servicesStopped: Bool) -> String {
        if failed.contains(id) {
            return "a new start after its failure"
        }

        if wanted[id] != nil {
            return "its settings changed"
        }

        if servicesStopped {
            return "the services are stopped"
        }

        return serverStopCauses[id] ?? "no workspace needs it now"
    }

    // The start of one program of the list, for the sync and for the start of a stopped workspace.
    // The entry in runningProcesses comes before the first wait. So no second start of the same
    // program begins in that time. A server that starts leaves the list of hold, as in the gate.
    // Returns the reason of a failure.
    func startProcess(_ process: BackgroundProcess) async -> String? {
        let id = process.definition.id

        writeToLog(of: process.log, "$ \(process.command)\n")
        runningProcesses[id] = process
        serverHandOvers[id] = nil

        var handOver: Int?

        if let server = process.server {
            heldServers = heldServers.filter { !$0.isSame(as: server) }
            handOver = await serverGate.serverWillStart(server)
        }

        do {
            try await processSupervisor.start(process.definition, handedOver: handOver != nil)

            // An end or a stop can reach the supervisor before this start. Then nothing else ends
            // this program.
            guard runningProcesses[id] != nil else {
                await processSupervisor.end(id, cause: "a stop during its start")
                return nil
            }

            serverHandOvers[id] = handOver
            return nil
        } catch {
            let reason = ErrorText.plain(error)

            runningProcesses[id] = nil

            if let server = process.server {
                await serverGate.serverDidNotStart(server, handOver: handOver, reason: reason)
            }

            return reason
        }
    }

    // The stop of one workspace server. The gate takes the port back after serverDidStop, and a
    // connection that waited in the stop can start the workspace at once. That start must not find
    // the server that just stopped. So its entry in runningProcesses goes first (plan item 3e).
    func stopServer(_ id: String, _ server: GatedServer, cause: String) async {
        await serverGate.serverWillStop(server)
        try? await processSupervisor.stop(id, cause: cause)
        runningProcesses[id] = nil
        serverHandOvers[id] = nil
        await serverGate.serverDidStop(server)
    }

    // git has no hook for a removal. It tells nothing until it deleted the files. A program that
    // writes in that time makes git stop with "Directory not empty". Vite does this each time,
    // because it reacts to the removal of its config file. So nexusd watches each worktree with a
    // program in it. The first deleted file reports at once, at each depth of the worktree.
    private func watchWorktrees() {
        guard !watchingStopped else {
            return
        }

        let worktrees = Set(runningProcesses.values.compactMap(\.worktree)).subtracting(removingWorktrees)

        worktreeWatchers = worktreeWatchers.filter { worktrees.contains($0.key) }
        worktrees.forEach(watch)
    }

    private func watch(_ worktree: String) {
        guard worktreeWatchers[worktree] == nil else {
            return
        }

        let folder = URL(filePath: worktree, directoryHint: .isDirectory)

        worktreeWatchers[worktree] = FolderWatcher(folders: [folder], latency: Self.worktreeWatchLatency, reportsFirstChangeAtOnce: true) { [weak self] _ in
            Task { await self?.worktreeChanged(worktree) }
        }
    }

    // A clean stop would give the programs time to write. The worktree goes away anyway. The check
    // ends after git ended. So a removal that git refuses starts the programs again. One check runs at
    // a time. A change during that check gives one more. The first deletion of a removal must not
    // get lost, but a checkout of many files needs no check for each file. The sync comes after the
    // check, because the programs of that sync have a new watch that a next removal must reach.
    func worktreeChanged(_ worktree: String) async {
        guard checkingWorktrees.insert(worktree).inserted else {
            recheckWorktrees.insert(worktree)
            return
        }

        var removing = false

        repeat {
            recheckWorktrees.remove(worktree)
            removing = await worktreeRemovalCheck(worktree)
        } while !removing && recheckWorktrees.contains(worktree)

        guard removing else {
            checkingWorktrees.remove(worktree)
            return
        }

        removingWorktrees.insert(worktree)
        worktreeWatchers[worktree] = nil

        for (id, process) in runningProcesses where process.worktree == worktree {
            await processSupervisor.end(id, cause: "git removes the worktree")
            runningProcesses[id] = nil
        }

        while !watchingStopped, await worktreeRemovalCheck(worktree) {
            try? await Task.sleep(for: .milliseconds(200))
        }

        removingWorktrees.remove(worktree)
        checkingWorktrees.remove(worktree)
        recheckWorktrees.remove(worktree)
        await syncBackgroundProcesses().value
    }

    static func gitRemoves(_ worktree: String) async -> Bool {
        ProcessArguments.ofPrograms(named: "git").contains { removes(worktree, arguments: $0) }
    }

    // A full path names one worktree. git also takes the end of a path. So the last part of that path
    // names the worktree. git ignores upper and lower case in that name on a normal macOS volume. A
    // path such as . gives no name, because it depends on the folder of git. So it counts.
    static func removes(_ worktree: String, arguments: [String]) -> Bool {
        guard let target = worktreeRemovalTarget(arguments) else {
            return false
        }

        if target.hasPrefix("/") {
            return RealPath.of(URL(filePath: target)) == RealPath.of(URL(filePath: worktree))
        }

        let name = (target as NSString).lastPathComponent

        return name == "." || name == ".." || name.caseInsensitiveCompare((worktree as NSString).lastPathComponent) == .orderedSame
    }

    // The first argument is the program. Only options can come before the subcommand of git. So the
    // text of a message, as in git commit -m, does not count. An option of the removal can come
    // before or after the path. git also takes a short form of an option, such as --forc or -fff.
    // So each word with a - before the -- is an option.
    private static func worktreeRemovalTarget(_ arguments: [String]) -> String? {
        var rest = arguments.dropFirst()

        while let option = rest.first, option.hasPrefix("-") {
            rest = rest.dropFirst(gitOptionsWithValue.contains(option) ? 2 : 1)
        }

        guard rest.starts(with: ["worktree", "remove"]) else {
            return nil
        }

        let removal = rest.dropFirst(2)
        let separator = removal.firstIndex(of: "--") ?? removal.endIndex

        return (removal[..<separator].filter { !$0.hasPrefix("-") } + removal[separator...].dropFirst()).last
    }

    // "Stop all services" runs in the queue of the changes, and a sync can wait for that queue. So
    // this stop does not wait for a sync. A server during the hand-over of its port belongs to a
    // workspace that starts. The gate then gives the clients of that start the reason (plan item 3e).
    func stopBackgroundProcesses(cause: String) async {
        let servers = runningProcesses.values.compactMap(\.server)
        let gate = serverGate

        for server in servers {
            await gate.serverWillStop(server)
        }

        await processSupervisor.stopAll(cause: cause)
        runningProcesses = [:]
        serverHandOvers = [:]
        worktreeWatchers = [:]

        // Each call can wait up to 1 second for the bind of its port, as in the stops of the sync.
        await withTaskGroup { group in
            for server in servers {
                group.addTask {
                    await gate.serverDidStop(server)
                }
            }
        }
    }

    // A service that starts again can end the cause, for example a database that a worker needs.
    private func failedProcesses() async -> Set<String> {
        Set(await processSupervisor.status().filter { status in
            if case .failed = status.state {
                return true
            }

            return false
        }.map(\.id))
    }

    // A program that stopped too often has its reason in the supervisor. It stays failed until the
    // next setup or the next start of a service. So the Retry of its workspace starts it again. A dev
    // server fails at its first end that nobody asked for (owner, 2026-11-15). The sync then stops
    // it, and its page says why.
    func backgroundProcessesChanged() async {
        var problems = plannedProcessProblems
        var states: [String: ServiceState] = [:]
        var running: Set<String> = []
        var failed: [(owner: String, command: String)] = []
        var failedServers: [(server: GatedServer, handOver: Int, reason: String)] = []
        let handOversBefore = serverHandOvers

        for status in await processSupervisor.status() {
            guard let process = runningProcesses[status.id] else {
                continue
            }

            // A server that fails during the hand-over of its port gives the clients of that start
            // the reason (plan item 3e). The supervisor starts a server again after an exit. That
            // new start gets the same hand-over, so only a failed state counts. A start during the
            // read of the states changes the number, and the state then can belong to an earlier
            // start. The gate ignores the number of an earlier hand-over.
            if let server = process.server, case .failed(let reason) = status.state, let handOver = serverHandOvers[status.id], handOversBefore[status.id] == handOver {
                failedServers.append((server, handOver, reason))
                serverHandOvers[status.id] = nil
            }

            let isApp = status.id == Self.appProcessID(owner: process.owner)

            if isApp {
                states[status.id] = status.state
            }

            if let command = process.devServerCommand {
                switch status.state {
                case .running: running.insert(process.owner)
                case .restarting, .failed: failed.append((process.owner, command))
                case .stopped: break
                }

                continue
            }

            if case .failed(let reason) = status.state {
                let name = isApp ? "The Node.js app" : "The background process \(process.command)"
                problems[process.owner, default: []].append("\(name) does not run. \(reason)")
            }
        }

        for (owner, command) in failed {
            recordDevServerFailure(of: owner, command: command)
        }

        if !failedServers.isEmpty {
            let gate = serverGate

            Task { [failedServers] in
                for (server, handOver, reason) in failedServers {
                    await gate.serverDidNotStart(server, handOver: handOver, reason: reason)
                }
            }
        }

        if !failed.isEmpty {
            _ = syncBackgroundProcesses()
        }

        guard problems != processProblems || states != appStates || running != runningDevServers || !failed.isEmpty else {
            return
        }

        processProblems = problems
        appStates = states
        runningDevServers = running
        publishSites()
    }

    // After "Stop all services" the programs have no database, so they wait for the services. Each
    // workspace server that must not run gets the cause of its stop.
    private func wantedProcesses(_ state: EngineState, servers: [WorkspaceServerEntry], servicesStopped: Bool) async -> (processes: [String: BackgroundProcess], serverStopCauses: [String: String]) {
        plannedProcessProblems = [:]
        plannedDevServers = [:]
        plannedOnDemandPrograms = [:]

        guard !servicesStopped else {
            usePlannedDevServers()
            return ([:], [:])
        }

        let resolved = resolvedSites(state).map(\.site)
        let (_, conflicts, sitesOfRecord, _, _) = workspaceSites(state, resolved: resolved)
        // A public link with Build holds back the dev server of its owner (group 4, 4e).
        buildShareOwners = Self.buildShareOwners(state.shares, targets: shareTargets(state, sites: resolved, sitesOfRecord: sitesOfRecord, conflicts: conflicts))
        let serverPlan = workspaceServerProcesses(servers)
        var serverStopCauses = serverPlan.stopCauses
        var wanted = serverPlan.processes

        for (id, process) in runningProcesses where process.isDevServer && buildShareOwners.contains(process.owner) {
            serverStopCauses[id] = Self.shareBuildStopCause
        }

        let hasMainSwitch = { (key: String) in sitesOfRecord[key]?.contains(where: \.runsMainProcesses) == true }

        mainProcessPlans = mainProcessPlans.filter { hasMainSwitch($0.key) }
        mainProbeFailures = mainProbeFailures.filter { hasMainSwitch($0.key) }
        mainDevServerPlans = mainDevServerPlans.filter { sitesOfRecord[$0.key] != nil }
        forgetGoneOwners(keeping: Set(sitesOfRecord.keys.flatMap { key in
            [Self.processOwner(key: key, workspace: nil)] + (state.worktrees[key]?.workspaces ?? []).map { Self.processOwner(key: key, workspace: $0.name) }
        }))

        // A Node.js app is the site itself (D67). So it runs without the switches of the background
        // processes. A dev server also runs without the switch of the workspaces (owner, 2026-11-15).
        // A stopped workspace runs neither. The plan of its dev server stays, so its first page gets
        // the wait page and not the error of Vite.
        for (key, sites) in sitesOfRecord {
            let running = sites.filter(\.runsWorkspaceProcesses)

            for workspace in state.worktrees[key]?.workspaces ?? [] where conflicts[workspace] == nil {
                guard workspace.runState != .stopped else {
                    _ = await backgroundProcesses(of: workspace, sites: sites, running: [], key: key, tld: state.tld)
                    continue
                }

                wanted += await backgroundProcesses(of: workspace, sites: sites, running: running, key: key, tld: state.tld)
                wanted += await appProcesses(of: workspace, sites: sites, key: key, tld: state.tld)
            }

            wanted += await mainProcesses(of: sites, key: key, state: state)
        }

        usePlannedDevServers()
        return (Dictionary(wanted.map { ($0.definition.id, $0) }) { first, _ in first }, serverStopCauses)
    }

    // The plans of this sync replace the plans of the last sync at once. A page or an idle check
    // during the sync reads the complete plans of the last sync.
    private func usePlannedDevServers() {
        devServerPlans = plannedDevServers
        onDemandPrograms = plannedOnDemandPrograms
        writeDevServerPages()
    }

    // sites holds each site of the project, so {host} and the log are the same as in the setup.
    // running holds the sites with their switch on. The dev server runs with the first page, also
    // while the switch is off.
    private func backgroundProcesses(of workspace: Workspace, sites: [Site], running: [Site], key: String, tld: String) async -> [BackgroundProcess] {
        guard workspace.state == .ready, let preset = workspace.backgroundPreset, FileManager.default.fileExists(atPath: "\(workspace.worktree)/.git") else {
            return []
        }

        guard let folder = await fileFolders(of: workspace, key: key)?.worktree else {
            return []
        }

        let host = workspace.hosts(of: sites, tld: tld).first ?? ""
        let list = BackgroundList(
            owner: Self.processOwner(key: key, workspace: workspace.name),
            workspace: workspace.name,
            host: host,
            log: "workspace-\(host)",
            folder: folder,
            worktree: workspace.worktree,
            node: (running.first ?? sites[0]).node,
            database: workspace.database,
            ports: workspace.ports
        )

        let others = Self.backgroundCommandGroups(of: running, preset: preset).others
        let devServers = Self.backgroundCommandGroups(of: sites, preset: preset).devServers

        return await backgroundProcesses(of: others, in: list) + devServerProcesses(of: devServers, in: list)
    }

    private func appProcesses(of workspace: Workspace, sites: [Site], key: String, tld: String) async -> [BackgroundProcess] {
        guard let app = sites.first(where: { $0.kind == .node }), workspace.state == .ready, FileManager.default.fileExists(atPath: "\(workspace.worktree)/.git") else {
            return []
        }

        guard let folder = await fileFolders(of: workspace, key: key)?.worktree else {
            return []
        }

        let owner = Self.processOwner(key: key, workspace: workspace.name)

        // A record from before its site ran as a Node.js app has no port for it.
        guard workspace.ports[NodeAppLaunch.portName] != nil else {
            plannedProcessProblems[owner, default: []].append("The Node.js app of \(workspace.name) has no port yet. Use Retry to set up the workspace again.")
            return []
        }

        let host = workspace.hosts(of: sites, tld: tld).first ?? ""
        let list = BackgroundList(
            owner: owner,
            workspace: workspace.name,
            host: host,
            log: "workspace-\(host)",
            folder: folder,
            worktree: workspace.worktree,
            node: app.node,
            database: workspace.database,
            ports: workspace.ports
        )

        return await appProcess(of: app, in: list, hosts: [host], tld: tld).map { [$0] } ?? []
    }

    // The main checkout runs its background processes when its switch is on. Its Node.js app and its
    // dev server start with the first page, also while the switch is off (owner, 2026-11-15).
    private func mainProcesses(of sites: [Site], key: String, state: EngineState) async -> [BackgroundProcess] {
        let switched = sites.filter(\.runsMainProcesses)
        var apps: [BackgroundProcess] = []

        if let app = sites.first(where: { $0.kind == .node }) {
            apps = await mainApp(app, key: key, state: state)
        }

        let devServers = await mainDevServerProcesses(of: sites, key: key)

        guard let site = switched.first, FileManager.default.fileExists(atPath: ProjectFolder.projectFolder(of: site)) else {
            return apps + devServers
        }

        let owner = Self.processOwner(key: key, workspace: nil)

        do {
            let plan = try await mainProcessPlan(of: switched, key: key)
            let list = BackgroundList(owner: owner, workspace: nil, host: site.host, log: "main-\(site.host)", folder: plan.folder, worktree: ProjectFolder.worktree(holding: plan.folder)?.root, node: site.node, database: plan.database, ports: plan.ports)
            let commands = Self.backgroundCommandGroups(of: switched, preset: plan.preset).others

            return await backgroundProcesses(of: commands, in: list) + apps + devServers
        } catch {
            plannedProcessProblems[owner, default: []].append("Nexus cannot start the background processes of the main checkout. \(ErrorText.plain(error))")
            return apps + devServers
        }
    }

    // The app has the port that nginx sends its requests to. The web configuration gives that port.
    private func mainApp(_ app: Site, key: String, state: EngineState) async -> [BackgroundProcess] {
        let folder = ProjectFolder.projectFolder(of: app)
        let owner = Self.processOwner(key: key, workspace: nil)

        guard FileManager.default.fileExists(atPath: folder) else {
            return []
        }

        guard let port = state.appPorts[key] else {
            plannedProcessProblems[owner, default: []].append("The Node.js app waits for its port. Nexus gives it a port when it writes the configuration of nginx.")
            return []
        }

        let list = BackgroundList(owner: owner, workspace: nil, host: app.host, log: "main-\(app.host)", folder: folder, worktree: ProjectFolder.worktree(holding: folder)?.root, node: app.node, database: nil, ports: [NodeAppLaunch.portName: port])

        return await appProcess(of: app, in: list, hosts: app.hosts, tld: state.tld).map { [$0] } ?? []
    }

    // The main checkout keeps its .env, so {port:reverb} is the port that this .env gives the server.
    // Each other {port:<name>} gets a free port, as in a workspace. A name keeps its port, because a
    // port that a program of this list uses is not free, and a new port would restart that program.
    private func mainProcessPlan(of sites: [Site], key: String) async throws -> MainProcessPlan {
        var plan: MainProcessPlan

        if let known = mainProcessPlans[key] {
            plan = known
        } else {
            plan = try await probedMainProcessPlan(of: sites, key: key)
        }

        // The dev server has its port in mainDevServerPlans.
        let names = WorkspaceKeys.portNames(in: Self.backgroundCommandGroups(of: sites, preset: plan.preset).others)
        let kept = plan.ports.merging(plan.reverbPort.map { ["reverb": $0] } ?? [:]) { _, fixed in fixed }

        // A probe can take 30 seconds, and a setup can record a port in that time.
        plan.ports = freePorts(for: names, keeping: kept, in: await stateStore.current())
        mainProcessPlans[key] = plan
        return plan
    }

    // A probe can take 30 seconds before it fails, and each request and each setup wait for a sync.
    // So a failed probe does not run again for a minute. A change of the main switch or of the PHP
    // version tries at once.
    private func probedMainProcessPlan(of sites: [Site], key: String) async throws -> MainProcessPlan {
        let project = URL(filePath: ProjectFolder.projectFolder(of: sites[0]), directoryHint: .isDirectory)
        let root = sites[0].kind == .php ? LaravelProject.root(containing: project) : nil
        let folder = RealPath.of(root ?? project)

        guard root != nil else {
            return MainProcessPlan(folder: folder, preset: [], database: nil, reverbPort: nil)
        }

        if let failure = mainProbeFailures[key], ContinuousClock.now < failure.nextProbe {
            throw RuntimeError.unsupported(failure.reason)
        }

        let configuration: LaravelConfiguration

        do {
            configuration = try await self.configuration(of: sites[0], folder: folder)
            mainProbeFailures[key] = nil
        } catch {
            mainProbeFailures[key] = MainProbeFailure(nextProbe: .now + Self.mainProbeWait, reason: ErrorText.plain(error))
            throw error
        }

        return MainProcessPlan(
            folder: folder,
            preset: await presetCommands(configuration, in: folder),
            database: BackgroundPreset.databaseName(configuration),
            reverbPort: BackgroundPreset.reverbServerPort(configuration)
        )
    }

    // workspace is nil for the main checkout.
    struct BackgroundList {
        let owner: String
        let workspace: String?
        let host: String
        let log: String
        let folder: String
        let worktree: String?
        let node: String?
        let database: String?
        let ports: [String: Int]

        // The value of {workspace} and the name in a problem.
        var name: String {
            workspace ?? "main"
        }
    }

    // Programs of one owner share a log. A site without its PHP version can still run a command that
    // needs no PHP, as a command of a setup does. The link for npm chooses the Node line when a
    // program starts. The line goes into the environment, so a new line of the site restarts that
    // program. The folder of the dump viewer is in the environment too. So a change of that setting
    // restarts a queue worker.
    func backgroundProcesses(of commands: [String], in list: BackgroundList) async -> [BackgroundProcess] {
        // toolCommand scans the parked folders and the installed runtimes. Each sync gets here for
        // each workspace that is ready, also without commands.
        guard !commands.isEmpty else {
            return []
        }

        let tool = try? await toolCommand(.php, folder: list.folder)
        let added = [Self.processMarker: processMarkerValue, Self.nodeLineKey: list.node ?? ""]
        let programEnvironment = environment(of: tool).merging(added) { _, new in new }

        return commands.compactMap { command in
            guard list.database != nil || !command.contains(WorkspaceKeys.databasePlaceholder) else {
                plannedProcessProblems[list.owner, default: []].append("The background process \(command) needs a database, and \(list.name) has none.")
                return nil
            }

            let expanded = WorkspaceKeys.expanded(command, workspace: list.name, host: list.host, database: list.database.map(ShellWord.quoted), ports: list.ports)

            return BackgroundProcess(owner: list.owner, command: expanded, log: list.log, worktree: list.worktree, definition: ServiceDefinition(
                id: "\(list.owner)\n\(expanded)",
                displayName: expanded,
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", expanded],
                environment: programEnvironment,
                workingDirectory: URL(filePath: list.folder, directoryHint: .isDirectory),
                logFile: paths.log(list.log),
                stopsGroup: true
            ))
        }
    }

    static func backgroundCommands(of sites: [Site], preset: [String]) -> [String] {
        distinct(sites.flatMap { $0.backgroundCommands ?? preset })
    }

    // A dev server starts with the first page (owner, 2026-11-15). The other commands follow the
    // switches of the site.
    static func backgroundCommandGroups(of sites: [Site], preset: [String]) -> (others: [String], devServers: [String]) {
        let commands = backgroundCommands(of: sites, preset: preset)

        return (commands.filter { !DevServer.isDevServer($0) }, commands.filter(DevServer.isDevServer))
    }

    static func processOwner(key: String, workspace: String?) -> String {
        "\(key)\n\(workspace ?? "")"
    }

    // The owner of the main checkout is the start of the owner of each workspace of its project.
    static func isOwner(_ owner: String, ofProject key: String) -> Bool {
        owner.hasPrefix(processOwner(key: key, workspace: nil))
    }

    func presetCommands(_ configuration: LaravelConfiguration, in folder: String) async -> [String] {
        BackgroundPreset.commands(for: configuration, runsVite: await runsVite(in: folder))
    }

    // A build writes the output folder, and a dev server writes the hot file. A file that git sees
    // would change in the worktree (D52). A folder without git has no such file.
    func runsVite(in folder: String) async -> Bool {
        guard let output = BackgroundPreset.viteOutput(inRoot: URL(filePath: folder, directoryHint: .isDirectory)) else {
            return false
        }

        guard let git = await GitTool.executable() else {
            return true
        }

        for path in [output, BackgroundPreset.hotFile] {
            if let ignored = try? await GitTool.ignores(path, in: folder, git: git), !ignored {
                return false
            }
        }

        return true
    }

    // What the Site screen shows for a site that follows the preset.
    func backgroundPreset(host: String) async throws -> [String] {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.host == host }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        guard let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return []
        }

        let folder = RealPath.of(main)

        return await presetCommands(try await configuration(of: site, folder: folder), in: folder)
    }

    // git deletes the worktree while Vite runs. Vite reacts to the removal of its config file and
    // writes a new cache into that folder. So git reports that the folder is not empty, and the folder
    // would block a new worktree on this path. That cache is no file of the user. A folder with its
    // .git file is still a worktree, for example after the removal of its site, and a folder with
    // other files stays (part 8k).
    static func removeViteCache(of workspace: Workspace) {
        let manager = FileManager.default

        guard !manager.fileExists(atPath: "\(workspace.worktree)/.git") else {
            return
        }

        try? manager.removeItem(atPath: "\(workspace.folder)/.vite")

        var folder = URL(filePath: workspace.folder, directoryHint: .isDirectory)

        while RealPath.contains(workspace.worktree, folder.path(percentEncoded: false)), rmdir(folder.path(percentEncoded: false)) == 0 {
            folder.deleteLastPathComponent()
        }
    }

    // A crash of nexusd leaves these programs without a supervisor. The next start would run each
    // one a second time, and no stop would reach the first one. The marker in their environment
    // finds them, and it also finds a program that a worker started. macOS hides the environment
    // of its own programs, such as /bin/sh and /bin/sleep. So one PHP or Node program in a group is
    // enough, and a shell loop without such a program stays.
    func endProcessesOfEarlierRun() async {
        let list = try? await CommandRunner.run(Command(executable: URL(filePath: "/bin/ps"), arguments: ["-A", "-E", "-ww", "-o", "pgid=,command="]))
        let marker = "\(Self.processMarker)=\(processMarkerValue)"
        let lines = (list?.standardOutput ?? "").split(separator: "\n").map { $0.split(separator: " ") }
        let groups = lines.filter { $0.contains { $0 == marker } }.compactMap { $0.first.flatMap { Int32($0) } }

        for group in Set(groups) where group > 1 {
            kill(-group, SIGKILL)
        }
    }

    // The path has no spaces this way, so the marker is one word in the list of ps. Each root has its
    // own value, so a test does not end the programs of the real nexusd.
    var processMarkerValue: String {
        paths.root.path(percentEncoded: true)
    }
}
