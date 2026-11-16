import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusLaravel
import NexusSupervisor

// The dev server of one owner, from the last sync (owner, 2026-11-15). workspace is nil for the
// main checkout. folder holds public/hot. log is the name of the log of the owner. outsidePort is
// the port of a dev server outside Nexus.
struct DevServerPlan: Sendable, Equatable {
    let command: String
    let workspace: String?
    let folder: String
    let port: Int?
    let log: String
    var outsidePort: Int?

    var displayName: String {
        DevServer.displayName(of: command)
    }
}

// command is the command of the plan, with {port:vite}. reason is nil after an end of the dev
// server. Its log then has the reason.
struct DevServerFailure: Sendable, Equatable {
    let command: String
    let reason: String?
    let time: Date
}

// What runs on demand for one owner: the ports that an open tab holds, and the logs of the
// programs for the line of an idle stop.
struct OnDemandPrograms: Sendable, Equatable {
    var ports: Set<Int> = []
    var logs: Set<String> = []
}

// The dev servers and the Node.js apps start with the first page of their owner (owner,
// 2026-11-15). They stop when no page loads for the time of the setting and no tab is open.
extension NexusEngine {
    static let devServerCheckInterval: Duration = .seconds(30)
    static let devServerRetryWait: TimeInterval = 10
    static let firstOutgoingPort = 49_152

    // The owner of the access log of each host. A workspace has one log, with its first host. A
    // workspace that does not run has no server block, so it has no log. sitesOfRecord and conflicts
    // come from workspaceSites, as in the configuration of nginx.
    func accessLogOwners(_ state: EngineState, sitesOfRecord: [String: [Site]], conflicts: [Workspace: String]) -> [String: String] {
        var owners: [String: String] = [:]

        for (key, sites) in sitesOfRecord {
            for site in sites {
                owners[site.host] = Self.processOwner(key: key, workspace: nil)
            }
        }

        for (key, sites) in sitesOfRecord {
            for workspace in state.worktrees[key]?.workspaces ?? [] where conflicts[workspace] == nil {
                if let host = workspace.hosts(of: sites, tld: state.tld).first {
                    owners[host] = Self.processOwner(key: key, workspace: workspace.name)
                }
            }
        }

        return owners
    }

    // The wait page of a Laravel site with a vite.config file. site.folder is the folder in the
    // worktree for a workspace.
    func devServerFiles(of site: Site, layout: SiteLayout) -> DevServerFiles? {
        guard site.kind == .php, layout.projectType == .laravel, let root = LaravelProject.root(containing: site.folder), let files = BackgroundPreset.viteFiles(inRoot: root) else {
            return nil
        }

        return DevServerFiles(page: paths.devServerPage(site.host), nodeModules: files.nodeModules, hotFile: files.hotFile, manifest: files.manifest)
    }

    // writeWebConfig calls this after it wrote nginx. The watch then follows the new sites.
    func watchAccessLogs(_ state: EngineState, sitesOfRecord: [String: [Site]], conflicts: [Workspace: String]) {
        guard !watchingStopped else {
            return
        }

        accessLogHosts = accessLogOwners(state, sitesOfRecord: sitesOfRecord, conflicts: conflicts)

        let watch = accessLogWatch ?? AccessLogWatch { [weak self] owner in
            Task { await self?.pageRequested(by: owner) }
        }

        accessLogWatch = watch
        watch.watch(Dictionary(accessLogHosts.map { (paths.siteLog($0.key).path(percentEncoded: false), $0.value) }) { first, _ in first })
        writeDevServerPages()
    }

    // A request in an access log (owner, 2026-11-15). Each step after the mark has its own guard. So
    // a new step for a page does not wait for the guard of another step. A page of a stopped
    // workspace starts it.
    func pageRequested(by owner: String, now: Date = .now) async {
        guard !watchingStopped else {
            return
        }

        let startsOwner = markPage(of: owner, now: now)

        startOnDemandPrograms(of: owner, startsOwner: startsOwner, now: now)
        await startAfterPage(of: owner)
    }

    // A page and a restart of a Node.js app mark their owner here. The programs of an owner that does
    // not run on demand yet start at the next sync. Returns true for such an owner.
    @discardableResult
    func markPage(of owner: String, now: Date) -> Bool {
        lastPageRequest[owner] = now
        return startedOnDemand.insert(owner).inserted
    }

    // A site or a workspace that goes away takes its state along (owner, 2026-11-15). So a new
    // workspace with the same name waits for its own first page and gets no time of the idle stop
    // of the old one. owners holds each main checkout and each workspace of the sync.
    func forgetGoneOwners(keeping owners: Set<String>) {
        startedOnDemand.formIntersection(owners)
        lastPageRequest = lastPageRequest.filter { owners.contains($0.key) }
        lastOpenTab = lastOpenTab.filter { owners.contains($0.key) }
        devServerFailures = devServerFailures.filter { owners.contains($0.key) }
        activityTimes = activityTimes.filter { owners.contains($0.key) }
        lastStarts = lastStarts.filter { owners.contains($0.key) }
    }

    // nginx shows the page of the failure only after this record. Without it the wait page loads
    // again each second (owner, 2026-11-15). The first failure stays until a page tries again.
    func recordDevServerFailure(of owner: String, command: String, reason: String? = nil) {
        guard devServerFailures[owner] == nil else {
            return
        }

        devServerFailures[owner] = DevServerFailure(command: command, reason: reason, time: .now)
        writeDevServerPages()
        publishSites()
    }

    // The first page after a quiet time starts the dev server and the Node.js app of its owner. A page
    // at least 10 seconds after a failed start tries again. Before the first sync nexusd does not know
    // the owner yet. That sync then starts it. A sync that runs now can have read the owner before
    // this page, so it runs once more.
    private func startOnDemandPrograms(of owner: String, startsOwner: Bool, now: Date) {
        var changed = startsOwner

        if let failure = devServerFailures[owner], now.timeIntervalSince(failure.time) >= Self.devServerRetryWait {
            devServerFailures[owner] = nil
            changed = true
        }

        guard changed, onDemandPrograms[owner] != nil || processSync != nil else {
            return
        }

        writeDevServerPages()
        publishSites()
        _ = syncBackgroundProcesses()
    }

    func startDevServerChecks() {
        guard devServerCheck == nil else {
            return
        }

        devServerCheck = Task { [weak self] in
            while (try? await Task.sleep(for: Self.devServerCheckInterval)) != nil, let engine = self {
                await engine.checkIdleDevServers()
            }
        }
    }

    // An owner without a page and without an open connection to its ports for the time of the setting
    // stops its dev server and its Node.js app. lsof runs only when an owner is idle. An open tab
    // counts from the check that found it. So lsof does not run each 30 seconds while a tab is open.
    // When lsof fails, each program keeps its run. A page during the run of lsof keeps its owner.
    // The check also gives a source again to an access log that went away. So a page after a
    // delete of its log still reaches pageRequested (owner, 2026-11-15).
    func checkIdleDevServers(now: Date = .now) async {
        accessLogWatch?.refresh()

        let stop = await stateStore.current().devServerStop

        guard let limit = stop.duration else {
            return
        }

        let isIdle = { (owner: String) in
            let lastUse = max(self.lastPageRequest[owner] ?? .distantPast, self.lastOpenTab[owner] ?? .distantPast)
            return self.startedOnDemand.contains(owner) && now.timeIntervalSince(lastUse) >= limit
        }

        let programs = onDemandPrograms
        let idle = startedOnDemand.filter(isIdle)

        guard !idle.isEmpty else {
            return
        }

        guard let open = await openConnectionPorts(Set(idle.flatMap { programs[$0]?.ports ?? [] })) else {
            return
        }

        for owner in idle where !(programs[owner]?.ports ?? []).isDisjoint(with: open) {
            lastOpenTab[owner] = now
        }

        let stopped = idle.filter(isIdle)

        for owner in stopped {
            startedOnDemand.remove(owner)
            devServerFailures[owner] = nil
            lastOpenTab[owner] = nil

            let stops = runningProcesses.values.filter { $0.owner == owner && ($0.isDevServer || $0.definition.id == Self.appProcessID(owner: owner)) }

            for log in programs[owner]?.logs ?? [] where stops.contains(where: { $0.log == log }) {
                writeToLog(of: log, "Nexus stops this program, because no page loaded for \(stop.title) and no tab is open.\n")
            }
        }

        guard stopped.contains(where: { programs[$0] != nil }) else {
            return
        }

        writeDevServerPages()
        publishSites()
        await syncBackgroundProcesses().value
    }

    // A program that starts with the first page of its owner (owner, 2026-11-15). The idle check
    // needs its port and its log also while it does not run. Returns true when a page started the
    // owner.
    func planOnDemand(_ owner: String, port: Int?, log: String) -> Bool {
        plannedOnDemandPrograms[owner, default: OnDemandPrograms()].ports.formUnion(port.map { [$0] } ?? [])
        plannedOnDemandPrograms[owner, default: OnDemandPrograms()].logs.insert(log)
        return startedOnDemand.contains(owner)
    }

    // The dev server of an owner runs only after a page (owner, 2026-11-15). Its plan stays known while
    // it does not run, for the page file of nginx and for the Site screen. A failure of an old command
    // does not hold back a new command.
    func devServerProcesses(of commands: [String], in list: BackgroundList) async -> [BackgroundProcess] {
        guard let command = commands.first else {
            return []
        }

        let port = list.ports[DevServer.portName]
        var plan = DevServerPlan(command: command, workspace: list.workspace, folder: list.folder, port: port, log: list.log)

        if let failure = devServerFailures[list.owner], failure.command != command {
            devServerFailures[list.owner] = nil
        }

        let started = planOnDemand(list.owner, port: port, log: list.log)
        let runs = runningProcesses.values.contains { $0.owner == list.owner && $0.isDevServer }

        if !runs {
            plan.outsidePort = checkHotFile(in: list.folder, log: list.log)
        }

        plannedDevServers[list.owner] = plan

        guard plan.outsidePort == nil, started, devServerFailures[list.owner] == nil else {
            return []
        }

        guard list.database != nil || !command.contains(WorkspaceKeys.databasePlaceholder) else {
            let reason = "It needs a database, and \(list.name) has none."

            writeToLog(of: list.log, "Nexus does not start \(command). \(reason)\n")
            recordDevServerFailure(of: list.owner, command: command, reason: reason)
            return []
        }

        return await backgroundProcesses(of: commands, in: list).map { process in
            var devServer = process
            devServer.devServerCommand = command
            return devServer
        }
    }

    // The dev server of the main checkout needs no probe (research 1, part C). runsVite reads only the
    // files and git. The result stays in mainDevServerPlans until a change of the site or of a file
    // that runsVite reads. The port stays the same when "Run for the main checkout" changes.
    func mainDevServerProcesses(of sites: [Site], key: String) async -> [BackgroundProcess] {
        let phpSites = sites.filter { $0.kind == .php }

        guard let site = phpSites.first, FileManager.default.fileExists(atPath: ProjectFolder.projectFolder(of: site)) else {
            return []
        }

        var plan: MainProcessPlan
        let known = mainDevServerPlans[key]

        if let known, known.viteFileDates == Self.viteFileDates(in: known.folder) {
            plan = known
        } else {
            let project = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)
            let root = LaravelProject.root(containing: project)
            let folder = RealPath.of(root ?? project)
            let dates = Self.viteFileDates(in: folder)
            var runs = false

            if root != nil {
                runs = await runsVite(in: folder)
            }

            plan = MainProcessPlan(folder: folder, preset: runs ? [BackgroundPreset.viteCommand] : [], database: nil, reverbPort: nil, ports: known?.ports ?? [:], viteFileDates: dates)
        }

        let commands = Self.backgroundCommandGroups(of: phpSites, preset: plan.preset).devServers

        plan.ports = freePorts(for: WorkspaceKeys.portNames(in: commands), keeping: plan.ports, in: await stateStore.current())
        mainDevServerPlans[key] = plan

        let list = BackgroundList(owner: Self.processOwner(key: key, workspace: nil), workspace: nil, host: site.host, log: "main-\(site.host)", folder: plan.folder, worktree: ProjectFolder.worktree(holding: plan.folder)?.root, node: site.node, database: nil, ports: plan.ports)

        return await devServerProcesses(of: commands, in: list)
    }

    // The modification date of each file in the root that runsVite reads: each vite.config file and
    // the .gitignore files of the root and of public (owner, 2026-11-15). A file that comes or goes
    // changes the keys. The check costs one list of the root and a few stat calls.
    static func viteFileDates(in folder: String) -> [String: Date] {
        let manager = FileManager.default
        let configurations = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("vite.config.") }
        var dates: [String: Date] = [:]

        for name in configurations + [".gitignore", "public/.gitignore"] {
            dates[name] = (try? manager.attributesOfItem(atPath: "\(folder)/\(name)"))?[.modificationDate] as? Date
        }

        return dates
    }

    // A public/hot that names a port of Nexus without a listener comes from a Vite that got SIGKILL
    // (owner, 2026-11-15). nexusd removes it. Nexus gives its ports from the first workspace port up.
    // It stays below 49152, where macOS gives ports to outgoing connections. The caller uses the
    // result only while Nexus runs no dev server for the owner. So a port that answers is a dev
    // server that Nexus does not run. It can come from a terminal, also with a port in the range of
    // Nexus. Returns the port of such a dev server. Nexus then starts no second one.
    @discardableResult
    func checkHotFile(in folder: String, log: String) -> Int? {
        let file = "\(folder)/\(BackgroundPreset.hotFile)"

        guard let text = try? String(contentsOfFile: file, encoding: .utf8), let port = DevServer.port(inHotFile: text) else {
            return nil
        }

        if hotFilePortAnswers(port) {
            return port
        }

        if (Self.firstWorkspacePort..<Self.firstOutgoingPort).contains(port) {
            try? FileManager.default.removeItem(atPath: file)
            writeToLog(of: log, "Nexus removed \(BackgroundPreset.hotFile), because it named port \(port) and nothing listens there.\n")
        }

        return nil
    }

    // One page for each host of an owner with a dev server (owner, 2026-11-15). nginx shows it only
    // under the conditions of DevServerFiles. A file of a host without a dev server goes. The first
    // write after the start of nexusd also removes the pages of an earlier run.
    func writeDevServerPages() {
        var pages: [String: String] = [:]

        for (host, owner) in accessLogHosts {
            guard let plan = devServerPlans[owner] else {
                continue
            }

            pages[host] = devServerFailures[owner] == nil
                ? ErrorPages.devServerWaits(host: host, command: plan.displayName)
                : ErrorPages.devServerFails(host: host, command: plan.displayName, buildCommand: DevServer.buildCommand(for: plan.command))
        }

        guard pages != writtenDevServerPages else {
            return
        }

        let folder = paths.nginxPages
        let kept = Set(pages.keys.map { paths.devServerPage($0).lastPathComponent })

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (host, page) in pages {
            _ = try? Self.writeIfChanged(page, to: paths.devServerPage(host))
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []

        for name in names where name.hasPrefix(NexusPaths.devServerPagePrefix) && !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }

        writtenDevServerPages = pages
    }

    func devServerInfo(owner: String) -> DevServerInfo? {
        guard let plan = devServerPlans[owner] else {
            return nil
        }

        let log = paths.log(plan.log).path(percentEncoded: false)

        if let outside = plan.outsidePort {
            return DevServerInfo(command: plan.displayName, port: outside, state: .outsideNexus, log: log)
        }

        if devServerFailures[owner] != nil {
            return DevServerInfo(command: plan.displayName, port: plan.port, state: .doesNotStart, log: log)
        }

        return DevServerInfo(command: plan.displayName, port: plan.port, state: runningDevServers.contains(owner) ? .runs : .waitsForPage, log: log)
    }

    // The failures of the dev servers of a project. They show under Background processes, also for
    // a workspace (owner, 2026-11-15).
    func devServerProblems(ofKey key: String) -> [String] {
        devServerFailures.filter { Self.isOwner($0.key, ofProject: key) }.sorted { $0.key < $1.key }.compactMap { owner, failure in
            guard let plan = devServerPlans[owner] else {
                return nil
            }

            let name = plan.workspace.map { " of \($0)" } ?? ""
            let reason = failure.reason.map { $0.hasSuffix(".") ? "\($0) " : "\($0). " } ?? ""

            return "The dev server \(plan.displayName)\(name) does not start. \(reason)Its log is \(paths.log(plan.log).path(percentEncoded: false))."
        }
    }

    // The setting applies to each dev server at once (owner, 2026-11-15).
    func setDevServerStop(_ stop: DevServerStop) async throws -> String {
        try await stateStore.update { $0.devServerStop = stop }
        await checkIdleDevServers()

        guard stop != .never else {
            return "Nexus does not stop a dev server. A dev server starts with the first page of its site."
        }

        return "Nexus stops a dev server after \(stop.title) without a page and without an open tab."
    }
}
