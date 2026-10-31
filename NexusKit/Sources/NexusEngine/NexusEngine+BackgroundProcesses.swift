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
// real main checkout has none. A site can have its folder in a linked worktree.
struct BackgroundProcess: Sendable, Equatable {
    let owner: String
    let command: String
    let log: String
    let worktree: String?
    let definition: ServiceDefinition
}

// What the main checkout needs for its list. These values come from a probe. A workspace keeps them
// in its record, but the main checkout has no record.
struct MainProcessPlan: Sendable {
    let folder: String
    let preset: [String]
    let database: String?
    let reverbPort: Int?
    var ports: [String: Int] = [:]
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
    private static let processMarker = "NEXUS_BACKGROUND_PROCESS"
    private static let nodeLineKey = "NEXUS_SITE_NODE"
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

    private func runProcessSync() async {
        if !observesProcesses {
            observesProcesses = true
            await processSupervisor.onChange { [weak self] in
                Task { await self?.backgroundProcessesChanged() }
            }
        }

        repeat {
            processSyncAgain = false

            let wanted = await wantedProcesses()
            let restartsFailed = restartFailedProcesses

            restartFailedProcesses = false

            let failed = restartsFailed ? await failedProcesses() : []
            let outdated = Array(runningProcesses.filter { wanted[$0.key] != $0.value || failed.contains($0.key) }.keys)

            await withTaskGroup { group in
                for id in outdated {
                    group.addTask { try? await self.processSupervisor.stop(id) }
                }
            }

            outdated.forEach { runningProcesses[$0] = nil }

            // The list can come from before a "Stop all services" that ended during the probe of this
            // run or during the stops above.
            let servicesWait = await waitsForStoppedServices()

            for (id, process) in wanted.sorted(by: { $0.key < $1.key }) where runningProcesses[id] == nil && !servicesWait && !watchingStopped && !stoppingAllServices {
                // No start in a worktree that git removes now. That removal can start after the list
                // of this run. The watch comes before the start, so no removal falls between them.
                if let worktree = process.worktree {
                    if removingWorktrees.contains(worktree) {
                        continue
                    }

                    watch(worktree)
                }

                writeToLog(of: process.log, "$ \(process.command)\n")
                runningProcesses[id] = process

                do {
                    try await processSupervisor.start(process.definition)

                    // An end or a stop can reach the supervisor before this start. Then nothing
                    // else ends this program.
                    if runningProcesses[id] == nil {
                        await processSupervisor.end(id)
                    }
                } catch {
                    runningProcesses[id] = nil
                    plannedProcessProblems[process.owner, default: []].append("The background process \(process.command) does not run. \(error)")
                }
            }

            watchWorktrees()
            await backgroundProcessesChanged()
        } while processSyncAgain

        processSync = nil
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
            await processSupervisor.end(id)
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
    // this stop does not wait for a sync.
    func stopBackgroundProcesses() async {
        await processSupervisor.stopAll()
        runningProcesses = [:]
        worktreeWatchers = [:]
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
    // next setup or the next start of a service. So the Retry of its workspace starts it again.
    func backgroundProcessesChanged() async {
        var problems = plannedProcessProblems

        for status in await processSupervisor.status() {
            if case .failed(let reason) = status.state, let process = runningProcesses[status.id] {
                problems[process.owner, default: []].append("The background process \(process.command) does not run. \(reason)")
            }
        }

        guard problems != processProblems else {
            return
        }

        processProblems = problems
        publishSites()
    }

    // After "Stop all services" the programs have no database, so they wait for the services.
    private func wantedProcesses() async -> [String: BackgroundProcess] {
        let state = await stateStore.current()

        plannedProcessProblems = [:]

        guard !watchingStopped, !stoppingAllServices, await !waitsForStoppedServices() else {
            return [:]
        }

        let (_, conflicts, sitesOfRecord) = workspaceSites(state)
        var wanted: [BackgroundProcess] = []

        let hasMainSwitch = { (key: String) in sitesOfRecord[key]?.contains(where: \.runsMainProcesses) == true }

        mainProcessPlans = mainProcessPlans.filter { hasMainSwitch($0.key) }
        mainProbeFailures = mainProbeFailures.filter { hasMainSwitch($0.key) }

        for (key, sites) in sitesOfRecord {
            let running = sites.filter(\.runsWorkspaceProcesses)

            for workspace in state.worktrees[key]?.workspaces ?? [] where !running.isEmpty && conflicts[workspace] == nil {
                wanted += await backgroundProcesses(of: workspace, sites: sites, running: running, key: key, tld: state.tld)
            }

            wanted += await mainProcesses(of: sites.filter(\.runsMainProcesses), key: key)
        }

        return Dictionary(wanted.map { ($0.definition.id, $0) }) { first, _ in first }
    }

    // sites holds each site of the project, so {host} and the log are the same as in the setup.
    // running holds the sites with their switch on.
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
            name: workspace.name,
            host: host,
            log: "workspace-\(host)",
            folder: folder,
            worktree: workspace.worktree,
            node: running[0].node,
            database: workspace.database,
            ports: workspace.ports
        )

        return await backgroundProcesses(of: Self.backgroundCommands(of: running, preset: preset), in: list)
    }

    private func mainProcesses(of sites: [Site], key: String) async -> [BackgroundProcess] {
        guard let site = sites.first, FileManager.default.fileExists(atPath: ProjectFolder.projectFolder(of: site)) else {
            return []
        }

        let owner = Self.processOwner(key: key, workspace: nil)

        do {
            let plan = try await mainProcessPlan(of: sites, key: key)
            let list = BackgroundList(owner: owner, name: "main", host: site.host, log: "main-\(site.host)", folder: plan.folder, worktree: ProjectFolder.worktree(holding: plan.folder)?.root, node: site.node, database: plan.database, ports: plan.ports)

            return await backgroundProcesses(of: Self.backgroundCommands(of: sites, preset: plan.preset), in: list)
        } catch {
            plannedProcessProblems[owner, default: []].append("Nexus cannot start the background processes of the main checkout. \(error)")
            return []
        }
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

        let names = WorkspaceKeys.portNames(in: Self.backgroundCommands(of: sites, preset: plan.preset))

        // A probe can take 30 seconds, and a setup can record a port in that time.
        let taken = takenPorts(await stateStore.current())
        let kept = plan.ports.merging(plan.reverbPort.map { ["reverb": $0] } ?? [:]) { _, fixed in fixed }

        plan.ports = Self.numbers(for: names, keeping: kept, from: Self.firstWorkspacePort) { !taken.contains($0) && PortInspector.isFree($0) }
        mainProcessPlans[key] = plan
        return plan
    }

    // A probe can take 30 seconds before it fails, and each request and each setup wait for a sync.
    // So a failed probe does not run again for a minute. A change of the main switch or of the PHP
    // version tries at once.
    private func probedMainProcessPlan(of sites: [Site], key: String) async throws -> MainProcessPlan {
        let project = URL(filePath: ProjectFolder.projectFolder(of: sites[0]), directoryHint: .isDirectory)
        let root = LaravelProject.root(containing: project)
        let folder = RealPath.of(root ?? project)

        guard root != nil else {
            return MainProcessPlan(folder: folder, preset: [], database: nil, reverbPort: nil)
        }

        if let failure = mainProbeFailures[key], ContinuousClock.now < failure.nextProbe {
            throw RuntimeError.unsupported(failure.reason)
        }

        let configuration: LaravelConfiguration

        do {
            configuration = try await self.configuration(of: sites[0], mainFolder: folder)
            mainProbeFailures[key] = nil
        } catch {
            mainProbeFailures[key] = MainProbeFailure(nextProbe: .now + Self.mainProbeWait, reason: String(describing: error))
            throw error
        }

        return MainProcessPlan(
            folder: folder,
            preset: await presetCommands(configuration, in: folder),
            database: BackgroundPreset.databaseName(configuration),
            reverbPort: BackgroundPreset.reverbServerPort(configuration)
        )
    }

    private struct BackgroundList {
        let owner: String
        let name: String
        let host: String
        let log: String
        let folder: String
        let worktree: String?
        let node: String?
        let database: String?
        let ports: [String: Int]
    }

    // Programs of one owner share a log. A site without its PHP version can still run a command that
    // needs no PHP, as a command of a setup does. The link for npm chooses the Node line when a
    // program starts. The line goes into the environment, so a new line of the site restarts that
    // program.
    private func backgroundProcesses(of commands: [String], in list: BackgroundList) async -> [BackgroundProcess] {
        let tool = try? await toolCommand(.php, folder: list.folder)
        let added = [Self.processMarker: processMarkerValue, Self.nodeLineKey: list.node ?? ""]
        let programEnvironment = environment(of: tool).merging(added) { _, new in new }

        return commands.compactMap { command in
            guard list.database != nil || !command.contains(WorkspaceKeys.databasePlaceholder) else {
                plannedProcessProblems[list.owner, default: []].append("The background process \(command) needs a database, and \(list.name) has none.")
                return nil
            }

            let expanded = WorkspaceKeys.expanded(command, workspace: list.name, host: list.host, database: list.database.map(WorkspaceKeys.shellWord), ports: list.ports)

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

    static func processOwner(key: String, workspace: String?) -> String {
        "\(key)\n\(workspace ?? "")"
    }

    func presetCommands(_ configuration: LaravelConfiguration, in folder: String) async -> [String] {
        BackgroundPreset.commands(for: configuration, runsVite: await runsVite(in: folder))
    }

    // A build writes the output folder, and a dev server writes the hot file. A file that git sees
    // would change in the worktree (D52). A folder without git has no such file.
    private func runsVite(in folder: String) async -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []

        guard let configuration = files.first(where: { $0.hasPrefix("vite.config.") }) else {
            return false
        }

        guard let git = await GitTool.executable() else {
            return true
        }

        let source = (try? String(contentsOfFile: "\(folder)/\(configuration)", encoding: .utf8)) ?? ""

        for path in [BackgroundPreset.viteOutput(inConfiguration: source), BackgroundPreset.hotFile] {
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

        return await presetCommands(try await configuration(of: site, mainFolder: folder), in: folder)
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
    private var processMarkerValue: String {
        paths.root.path(percentEncoded: true)
    }
}
