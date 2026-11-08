import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// The setup of a new workspace, one at a time, after git adds its worktree. A workspace that Nexus
// cannot isolate keeps its domain, and it shows the reason (D48). A site that is no Laravel
// application gets no .env (D54).
extension NexusEngine {
    private static let firstRedisIndex = 16
    static let firstWorkspacePort = 20000
    static let databasePortName = "database"

    // A setup can take long, so it runs next to the watch of the worktrees.
    func startWorkspaceSetups() {
        guard !settingUpWorkspaces else {
            setupAgain = true
            return
        }

        settingUpWorkspaces = true
        Task { await runWorkspaceSetups() }
    }

    // A state that nexusd cannot store ends the run. The workspace stays in Preparing, and the
    // next trigger tries again. Without this end, the same workspace would run again and again.
    private func runWorkspaceSetups() async {
        defer { settingUpWorkspaces = false }

        repeat {
            setupAgain = false

            while !watchingStopped, let next = await nextPreparingWorkspace() {
                runningSetupKey = next.key

                // A worker reads the .env one time. So a worker that runs during a setup keeps the old
                // values. The workspace is in Preparing now, so the sync stops its programs.
                await syncBackgroundProcesses().value

                // A sync can wait for a stop or a probe, and git can move or remove the worktree in
                // that time. A clone for a record that is gone would stay for ever.
                guard !watchingStopped, let workspace = await preparingRecord(like: next.workspace, key: next.key) else {
                    runningSetupKey = nil
                    continue
                }

                let finished = await setUp(workspace, key: next.key)
                runningSetupKey = nil

                // A stop of nexusd also stops the database servers of a running setup. That failure
                // says nothing about the workspace. So the workspace stays in Preparing for the next
                // start.
                guard !watchingStopped, await store(finished, key: next.key) else {
                    return
                }

                await applyWorkspaceSites()
                publishSites()

                // A change during the setup must stop this workspace before its programs start.
                await checkConfigurations()
                await syncBackgroundProcesses().value
            }
        } while setupAgain
    }

    // A record without a site or without its folders waits, for example while its disk is not
    // connected. A folder that is not there says nothing about the application in it.
    private func nextPreparingWorkspace() async -> (key: String, workspace: Workspace)? {
        let state = await stateStore.current()
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let sites = resolvedSites(state).map(\.site).filter { exists(ProjectFolder.projectFolder(of: $0)) }
        let keys = Set(sites.map(ProjectFolder.workspaceKey(of:)))

        for key in keys.sorted() {
            if let workspace = state.worktrees[key]?.workspaces.first(where: { $0.state == .preparing && exists($0.worktree) }) {
                return (key, workspace)
            }
        }

        return nil
    }

    private func preparingRecord(like workspace: Workspace, key: String) async -> Workspace? {
        await stateStore.current().worktrees[key]?.workspaces.first { record in
            record.name == workspace.name && record.worktree == workspace.worktree && record.state == .preparing
        }
    }

    // A setup can take long, and git can change the branch or move the worktree in that time. So
    // only the results of the setup go into the record. A moved worktree needs a new setup. The
    // worktree can be gone by now. The record then stays gone.
    private func store(_ finished: Workspace, key: String) async -> Bool {
        let needsNewRun = setupIsOutdated
        setupIsOutdated = false

        do {
            try await stateStore.update { state in
                let records = state.worktrees[key]?.workspaces ?? []

                guard let index = records.firstIndex(where: { $0.name == finished.name && $0.worktree == finished.worktree }) else {
                    return
                }

                state.worktrees[key]?.workspaces[index].state = needsNewRun ? .preparing : finished.state
                state.worktrees[key]?.workspaces[index].redisIndexes = finished.redisIndexes
                state.worktrees[key]?.workspaces[index].redisInstances = finished.redisInstances
                state.worktrees[key]?.workspaces[index].ports = finished.ports
                state.worktrees[key]?.workspaces[index].warnings = finished.warnings
                state.worktrees[key]?.workspaces[index].finishedCommands = finished.finishedCommands
                state.worktrees[key]?.workspaces[index].commandsEnded = finished.commandsEnded
                state.worktrees[key]?.workspaces[index].backgroundPreset = finished.backgroundPreset
                state.worktrees[key]?.workspaces[index].database = finished.database
                state.worktrees[key]?.workspaces[index].configurationDigest = finished.configurationDigest
                state.worktrees[key]?.workspaces[index].mainConfigurationDigest = finished.mainConfigurationDigest
            }
            return true
        } catch {
            return false
        }
    }

    // New keys and new hosts of a site must also reach the workspaces that exist. A second setup
    // keeps the Redis indexes and the ports of a workspace. A setup that runs now started with the
    // old values, so it gets a new run.
    func setUpWorkspacesAgain(keys: Set<String>) async throws {
        setupIsOutdated = setupIsOutdated || runningSetupKey.map(keys.contains) == true

        try await stateStore.update { state in
            for key in keys {
                for index in state.worktrees[key]?.workspaces.indices ?? 0..<0 {
                    state.worktrees[key]?.workspaces[index].state = .preparing
                }
            }
        }

        startWorkspaceSetups()
    }

    // D40: this also works when the setting of the site is off and for a worktree from before the
    // site. A second call changes nothing. So a script can always run it before nexus workspace wait.
    func createWorkspace(folder: String) async throws -> String {
        let state = await stateStore.current()
        let path = RealPath.of(URL(filePath: folder, directoryHint: .isDirectory))

        guard let worktree = ProjectFolder.worktree(holding: path)?.root else {
            throw RuntimeError.unsupported("\(path) is in no git worktree. Make one with git worktree add.")
        }

        guard let site = ProjectFolder.locate(URL(filePath: path, directoryHint: .isDirectory), in: resolvedSites(state).map(\.site))?.site,
              let repository = ProjectFolder.repository(of: site) else {
            throw RuntimeError.unsupported("No site of Nexus holds \(worktree). Add the main checkout with nexus site add.")
        }

        guard site.kind != .proxy else {
            throw RuntimeError.unsupported("\(site.host) is a proxy site. A proxy site gets no workspaces, because each workspace would go to the same server.")
        }

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        let listed = try await WorktreeList.read(repository: repository.root, git: git)

        // A folder of a site can hold a worktree of another repository. Only the list of git says
        // which worktrees this site has. So a record for that worktree would go at the next check.
        guard let listedWorktree = listed.first(where: { $0.path == worktree }) else {
            throw RuntimeError.unsupported("\(worktree) is no worktree of \(repository.root).")
        }

        guard !listedWorktree.adding else {
            throw RuntimeError.unsupported("git still adds \(worktree). Try again when git worktree add is complete.")
        }

        let key = ProjectFolder.workspaceKey(of: site)

        // The check and the change are one step, because a check of the worktrees can add the same
        // worktree in between. A new site gets the list that a first check gives it. Without that
        // list, each worktree that it has already would get a workspace. The check of the worktrees
        // gives a moved worktree its workspace back. A new record here would make that check drop the
        // databases of the moved workspace. The check runs after each request.
        return try await stateStore.update { state in
            var record = state.worktrees[key] ?? SiteWorktrees(listed: Set(listed.filter { !$0.adding }.map(\.path)))
            let folderName = (worktree as NSString).lastPathComponent

            if let known = record.workspaces.first(where: { $0.worktree == worktree }) {
                return "The workspace \(known.name) exists already."
            }

            let isMoved = { (workspace: Workspace) in
                !listed.contains { $0.path == workspace.worktree } && (workspace.worktree as NSString).lastPathComponent == folderName
            }

            if !record.listed.contains(worktree), let moved = record.workspaces.first(where: isMoved) {
                return "The workspace \(moved.name) moves to \(worktree)."
            }

            let name = Workspace.name(forFolder: folderName, taken: Set(record.workspaces.map(\.name)))

            record.workspaces.append(Workspace(name: name, worktree: worktree, folder: worktree + repository.subfolder))
            record.listed.insert(worktree)
            state.worktrees[key] = record

            return "Nexus makes the workspace \(name)."
        }
    }

    // The way out of Not isolated, after the user fixes the cause or after a temporary failure.
    func retryWorkspace(host: String, name: String) async throws -> String {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).first(where: { $0.site.host == host })?.site else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let key = ProjectFolder.workspaceKey(of: site)

        guard state.worktrees[key]?.workspaces.contains(where: { $0.name == name }) == true else {
            throw RuntimeError.unsupported("\(host) has no workspace \(name).")
        }

        try await stateStore.update { state in
            if let index = state.worktrees[key]?.workspaces.firstIndex(where: { $0.name == name }) {
                state.worktrees[key]?.workspaces[index].state = .preparing
                state.worktrees[key]?.workspaces[index].configurationDigest = nil
            }
        }

        startWorkspaceSetups()
        return "Nexus sets up the workspace \(name) again."
    }

    private func setUp(_ workspace: Workspace, key: String) async -> Workspace {
        var workspace = workspace
        workspace.warnings = []

        // The setup reads the main checkout after this line. So a fix there during the setup counts.
        if let folders = await fileFolders(of: workspace, key: key) {
            workspace.mainConfigurationDigest = Self.configurationDigest(of: folders.application, in: folders.applicationRoot)
        }

        do {
            let written = try await writeEnvAndCopyData(of: &workspace, key: key)

            // A script of an install can use the database of the main site. The branch can need the
            // packages of that install to load its configuration, so a failed probe here says
            // nothing. The check after the install decides then.
            await cloneFiles(into: &workspace, key: key) { workspace in
                if let written {
                    try? await checkConfiguration(of: written, in: &workspace)
                }
            }

            if let written {
                try await checkConfiguration(of: written, in: &workspace)
            }

            await runCommands(of: &workspace, database: written?.database, key: key)

            // A command or an install that failed gives a warning, and it runs again in the next setup.
            // So a change that it makes must not start that setup, because the setups would then not
            // end. The .env must still get the values of the workspace back.
            if let written,
               !workspace.warnings.isEmpty,
               workspace.state == .preparing,
               Self.configurationDigest(of: written.folder, in: workspace.worktree) != workspace.configurationDigest,
               let rewritten = try await writeEnvAndCopyData(of: &workspace, key: key) {
                try await checkConfiguration(of: rewritten, in: &workspace)
            }

            workspace.warnings += (written?.warnings ?? []).filter { !workspace.warnings.contains($0) }

            // A worktree that is gone got no check of its configuration. Its disk can come back, so
            // the record waits in Preparing.
            if workspace.state == .preparing, FileManager.default.fileExists(atPath: workspace.worktree) {
                workspace.state = .ready
            }
        } catch {
            // A failure in a worktree that went away says nothing about the workspace.
            if FileManager.default.fileExists(atPath: workspace.worktree) {
                workspace.state = Self.adding(String(describing: error), to: workspace.state)
            }

            // An old digest would give a new setup after each setup that fails.
            if let folder = await fileFolders(of: workspace, key: key)?.worktree {
                workspace.configurationDigest = Self.configurationDigest(of: folder, in: workspace.worktree)
            }
        }

        return workspace
    }

    // The steps after this one can take minutes. A change in that time gives a new setup. So an edit
    // of the .env does not stay in a workspace that is Ready.
    private func writeEnvAndCopyData(of workspace: inout Workspace, key: String) async throws -> WrittenEnv? {
        guard let written = try await writeEnvFile(of: &workspace, key: key) else {
            return nil
        }

        workspace.configurationDigest = Self.configurationDigest(of: written.folder, in: workspace.worktree)

        for server in written.servers {
            try await prepareServer(of: server.tools, port: server.port, databases: written.databases.filter { $0.port == server.mainPort }, workspace: workspace.name, key: key)
        }

        for file in written.sqliteFiles {
            try await clone(file, in: written.folder, git: written.git, into: &workspace)
        }

        return written
    }

    // The plan comes from the main checkout, because a new worktree has no vendor folder at that
    // moment. The application in the worktree reads the configuration of its branch. That branch can
    // have a fixed name, or a key that the plan does not know (D48). A repository in the public
    // folder holds no application, so its worktree has no configuration to check.
    private func checkConfiguration(of written: WrittenEnv, in workspace: inout Workspace) async throws {
        guard !watchingStopped, workspace.state == .preparing else {
            return
        }

        if written.site.kind == .node {
            try await checkNodeEnvFiles(of: written, in: &workspace)
            return
        }

        guard written.repositoryHoldsApplication else {
            return
        }

        let probed = try await configuration(of: written.site, folder: written.folder)
        let ownPorts = Set(written.servers.map(\.port))
        let plan = try await envPlan(workspace: workspace.name, configuration: probed, mainFolder: written.folder, workspaceFolder: written.folder, realMainFolder: written.mainFolder, servers: written.servers)
        let newKeys = plan.isolatingKeys.subtracting(written.isolatingKeys).sorted()
        var problems = plan.problems + newKeys.map { "The key \($0) is not in the configuration of the main checkout. So Nexus does not change it." }

        if problems.isEmpty {
            let defaultConnection = probed.settings["database.default"]?.value.description

            problems = try await checkServers(plan, of: (written.site, written.folder, defaultConnection), ownPorts: ownPorts)
        }

        if !problems.isEmpty {
            workspace.state = .notIsolated((["The configuration of this worktree is different from the main checkout."] + problems).joined(separator: " "))
        }
    }

    private static func adding(_ problem: String, to state: WorkspaceState) -> WorkspaceState {
        guard case .notIsolated(let reason) = state else {
            return .notIsolated(problem)
        }

        return .notIsolated("\(reason) \(problem)")
    }

    // The record goes to the state at once, and it finds the workspace by name. A stop of nexusd
    // or a moved worktree must not lose it.
    func updateRecord(of workspace: String, key: String, _ change: @escaping @Sendable (inout Workspace) -> Void) async throws {
        try await stateStore.update { state in
            if let index = state.worktrees[key]?.workspaces.firstIndex(where: { $0.name == workspace }) {
                change(&state.worktrees[key]!.workspaces[index])
            }
        }
    }

    // A SQLite file in write-ahead mode has its last changes in a second file. The backup puts them
    // in one file. A rollback journal shows a write that runs now or that a crash ended. A clone
    // then holds a part of that write. The application in the worktree makes its own write-ahead
    // file later, so git must ignore that name too. A write-ahead file that stays there does not
    // belong to the new file. copyfile copies a symbolic link as a link, and the workspace would
    // then write into the file of the main site. A step before this one can take a moment, and git
    // can remove or move the worktree in that time. A clone would make that folder again.
    func clone(_ file: WorkspaceFile, in folder: String, git: URL, into workspace: inout Workspace) async throws {
        let manager = FileManager.default

        guard manager.fileExists(atPath: folder), manager.fileExists(atPath: file.from), !manager.fileExists(atPath: file.to) else {
            return
        }

        let source = RealPath.of(URL(filePath: file.from))
        let hasWriteAheadFile = manager.fileExists(atPath: "\(source)-wal")
        let hasJournal = manager.fileExists(atPath: "\(source)-journal")
        let targets = hasWriteAheadFile ? [file.to, "\(file.to)-wal"] : [file.to]

        for target in targets {
            let path = String(target.dropFirst(folder.count + 1))

            guard try await GitTool.ignores(path, in: folder, git: git) else {
                workspace.state = Self.adding("git does not ignore \(path), so Nexus does not clone that file.", to: workspace.state)
                return
            }
        }

        try? manager.removeItem(atPath: "\(file.to)-wal")
        try? manager.removeItem(atPath: "\(file.to)-shm")

        guard hasWriteAheadFile || hasJournal else {
            try await Self.cloneOutsideTheActor(source, to: file.to)
            return
        }

        try await FileClone.backUpSQLiteFile(source, to: file.to, readOnly: hasWriteAheadFile)
    }

    // Between two disks or on a disk without APFS, a clone is a normal copy that can take long.
    static func cloneOutsideTheActor(_ source: String, to target: String, preparing prepare: @escaping @Sendable (String) throws -> Void = { _ in }) async throws {
        try await Task.detached { try FileClone.clone(source, to: target, preparing: prepare) }.value
    }

    struct WrittenEnv {
        let servers: [(tools: DatabaseTools, mainPort: Int, port: Int)]
        let databases: [WorkspaceDatabase]
        let sqliteFiles: [WorkspaceFile]
        let folder: String
        let git: URL
        let database: String?
        let site: Site
        let isolatingKeys: Set<String>
        let mainFolder: String
        let repositoryHoldsApplication: Bool
        // What the workspace shares with the main site without a Not isolated state. The setup
        // adds it after the commands, because a warning before them means a failed command.
        var warnings: [String] = []
    }

    // Returns nil when the workspace has no .env, so nothing after this step applies to it.
    private func writeEnvFile(of workspace: inout Workspace, key: String) async throws -> WrittenEnv? {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }

        guard let site = sites.first else {
            return nil
        }

        if site.kind == .node {
            return try await writeNodeEnvFiles(of: &workspace, site: site, sites: sites, key: key, state: state)
        }

        // A site that is no Laravel application gets no .env, but its commands can use a port.
        let application = site.kind == .php ? LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) : nil

        guard let main = application else {
            // A checkout in the main checkout can remove these files for a moment. A workspace with a
            // check of its configuration must not lose that check then. Only a Retry accepts this.
            if site.kind == .php, workspace.configurationDigest != nil {
                throw RuntimeError.unsupported("The main checkout holds no Laravel application now. Restore it. When this site is no Laravel application any more, use Retry.")
            }

            workspace.backgroundPreset = []
            workspace.database = nil
            workspace.configurationDigest = nil
            workspace.mainConfigurationDigest = nil
            workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites, preset: []), of: workspace, state: state)

            if Self.isWordPress(sites) {
                workspace.state = Self.wordPressWorkspaceState
            }

            try await recordAssignments(of: workspace, key: key)
            return nil
        }

        let mainFolder = RealPath.of(main)
        let folder = Self.applicationFolder(mainFolder, of: site, in: workspace)
        let probed = try await configuration(of: site, folder: mainFolder)
        let plan = try await envPlan(workspace: workspace.name, configuration: probed, mainFolder: mainFolder, workspaceFolder: folder)

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        guard try await GitTool.ignores(".env", in: folder, git: git) else {
            workspace.state = .notIsolated("git does not ignore .env, so Nexus does not write that file.")
            workspace.configurationDigest = Self.configurationDigest(of: folder, in: workspace.worktree)
            return nil
        }

        let ownKeys = sites.flatMap { $0.workspaceKeys ?? [] }
        let earlierRedisIndexes = workspace.redisIndexesOnInstances
        let instances = try await serverInstances(of: plan)

        (workspace.redisIndexes, workspace.redisInstances) = try await redisIndexes(for: plan, of: workspace, state: state)
        workspace.backgroundPreset = await presetCommands(probed, in: folder)
        workspace.database = plan.database
        workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites, preset: workspace.backgroundPreset ?? []), servers: instances.map(\.tools.id), of: workspace, state: state)

        // The names of a workspace and of the main site are the same (D66). So a command needs this
        // port to reach the database of the workspace.
        if let mainPort = plan.databases.first(where: \.isDefault)?.port, let instance = instances.first(where: { $0.mainPort == mainPort }) {
            workspace.ports[Self.databasePortName] = workspace.ports[instance.tools.id]
        }

        try await recordAssignments(of: workspace, key: key)

        let servers = instances.compactMap { instance in
            workspace.ports[instance.tools.id].map { (tools: instance.tools, mainPort: instance.mainPort, port: $0) }
        }

        // The file is read after the waits above, because a start of Redis can take long and the
        // user can change the .env of the worktree in that time.
        let target = "\(folder)/.env"
        let source = FileManager.default.fileExists(atPath: target) ? target : "\(mainFolder)/.env"
        let text = try Self.envText(of: source)
        let host = workspace.hosts(of: sites, tld: state.tld).first ?? ""
        let own = WorkspaceKeys.expanded(ownKeys, workspace: workspace.name, host: host, database: plan.database, ports: workspace.ports)
        let pairs = Workspace.hostPairs(of: sites, workspace: workspace.name, tld: state.tld)
        let hosts = (pairs + Workspace.pairsFromOtherTLDs(pairs, tld: state.tld)).map { HostRewrite(from: $0.from, to: $0.to) }
        let serverKeys = servers.flatMap { server in (plan.serverPortKeys[server.mainPort] ?? []).map { ($0, String(server.port)) } }
        let mail = plan.mailKeys.mapValues { $0.replacing(WorkspaceEnvPlan.hostPlaceholder, with: host) }
        let isolating = plan.keys
            .merging(serverKeys) { _, port in port }
            .merging(workspace.redisIndexes.mapValues(String.init)) { _, redis in redis }
            .merging(mail) { database, _ in database }
        let reverb = workspace.ports["reverb"].map { port in Dictionary(uniqueKeysWithValues: plan.reverbPortKeys.map { ($0, String(port)) }) } ?? [:]
        let keys = isolating.merging(reverb) { isolating, _ in isolating }.merging(own) { _, own in own }

        try Data(EnvRewrite.apply(to: text, hosts: hosts, keys: keys).utf8).write(to: URL(filePath: target), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: Self.permissions(of: source)], ofItemAtPath: target)

        await emptyRedisIndexes(earlierRedisIndexes.subtracting(workspace.redisIndexesOnInstances).filter { !plan.mainRedisIndexes.contains($0.index) })

        let replaced = isolating.keys.filter { keys[$0] != isolating[$0] }.sorted()
        let problems = plan.problems
            + replaced.map { "The key \($0) of the site replaces the value that isolates this workspace." }
            + Self.cachedConfigurationProblem(in: folder)

        if !problems.isEmpty {
            workspace.state = .notIsolated(problems.joined(separator: " "))
        }

        // The application does not use a clone of a file when a key of the site replaces its path.
        // Another key can still have that path.
        let unused = Set(replaced.compactMap { isolating[$0] }).subtracting(keys.values)

        return WrittenEnv(
            servers: servers,
            databases: plan.databases,
            sqliteFiles: plan.sqliteFiles.filter { !unused.contains($0.to) },
            folder: folder,
            git: git,
            database: plan.database,
            site: site,
            isolatingKeys: plan.isolatingKeys,
            mainFolder: mainFolder,
            repositoryHoldsApplication: ProjectFolder.repository(of: site).map { RealPath.contains($0.root, mainFolder) } ?? false,
            warnings: plan.warnings
        )
    }

    // The probe checks the main checkout. A worktree can have its own cached configuration, and the
    // application then does not read the .env that Nexus writes.
    private static func cachedConfigurationProblem(in folder: String) -> [String] {
        guard FileManager.default.fileExists(atPath: "\(folder)/bootstrap/cache/config.php") else {
            return []
        }

        return ["The worktree has bootstrap/cache/config.php, so the application ignores the .env of the workspace. Run php artisan config:clear in the worktree."]
    }

    // The .env names these values from now on, and a stop of nexusd must not lose them. A later
    // setup would then take a new index for a workspace that wrote to the first one, and no record
    // would name that first index.
    func recordAssignments(of workspace: Workspace, key: String) async throws {
        try await updateRecord(of: workspace.name, key: key) { record in
            record.redisIndexes = workspace.redisIndexes
            record.redisInstances = workspace.redisInstances
            record.ports = workspace.ports
            record.backgroundPreset = workspace.backgroundPreset
            record.database = workspace.database
        }
    }

    // The application has the same path in the worktree as in the repository. A repository in the
    // public folder holds no application, so the folder of the workspace is the nearest place.
    static func applicationFolder(_ mainFolder: String, of site: Site, in workspace: Workspace) -> String {
        guard let root = ProjectFolder.repository(of: site)?.root, RealPath.contains(root, mainFolder) else {
            return workspace.folder
        }

        return workspace.worktree + mainFolder.dropFirst(root.count)
    }

    // A file that Nexus cannot read is no empty file. The write would replace its lines.
    static func envText(of file: String) throws -> String {
        guard FileManager.default.fileExists(atPath: file) else {
            return ""
        }

        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw RuntimeError.unsupported("Nexus cannot read \(file) as UTF-8 text. So Nexus does not use its lines and does not change it.")
        }

        return text
    }

    // attributesOfItem reads a symbolic link itself, which has 0755. The file behind the link has the
    // permissions that count.
    static func permissions(of file: String) -> Int {
        let target = URL(filePath: file).resolvingSymlinksInPath().path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: target))?[.posixPermissions] as? Int ?? 0o600
    }

    func configuration(of site: Site, folder: String) async throws -> LaravelConfiguration {
        let installed = await installer.installedRuntimes()
        let php = try await phpCommand(installedPHP(site.php, in: installed))

        return try await ConfigurationProbe(php: URL(filePath: php.executable), environment: php.environment)
            .run(root: URL(filePath: folder, directoryHint: .isDirectory))
    }

    func envPlan(workspace: String, site: Site, mainFolder: String, workspaceFolder: String) async throws -> WorkspaceEnvPlan {
        let probed = try await configuration(of: site, folder: mainFolder)

        return try await envPlan(workspace: workspace, configuration: probed, mainFolder: mainFolder, workspaceFolder: workspaceFolder)
    }

    // servers holds the servers of the workspace, for the check of a worktree. Its .env names these
    // ports, and a connection on such a port is on a Nexus instance too. A port counts only for the
    // kind of its server. All connections of a default Laravel application read DB_PORT, and a MySQL
    // client that connects to PostgreSQL waits until the probe stops.
    private func envPlan(workspace: String, configuration: LaravelConfiguration, mainFolder: String, workspaceFolder: String, realMainFolder: String? = nil, servers: [(tools: DatabaseTools, mainPort: Int, port: Int)] = []) async throws -> WorkspaceEnvPlan {
        WorkspaceEnvPlan(configuration: configuration, request: try await workspaceEnvRequest(
            workspace: workspace,
            mainFolder: mainFolder,
            workspaceFolder: workspaceFolder,
            realMainFolder: realMainFolder,
            servers: servers
        ))
    }

    // The ports of the Nexus instances of each kind, and of the servers of the workspace.
    func workspaceEnvRequest(workspace: String, mainFolder: String, workspaceFolder: String, realMainFolder: String? = nil, servers: [(tools: DatabaseTools, mainPort: Int, port: Int)]) async throws -> WorkspaceEnvRequest {
        let instances = try await databaseInstances()
        let redisPorts = Set(try await redisInstances().map(\.port))
        let mysqlServers = servers.filter(\.tools.kind.usesMySQLProtocol).map(\.port)
        let postgresqlServers = servers.filter { !$0.tools.kind.usesMySQLProtocol }.map(\.port)

        return WorkspaceEnvRequest(
            workspace: workspace,
            mainFolder: mainFolder,
            workspaceFolder: workspaceFolder,
            mysqlPorts: Set(instances.filter(\.kind.usesMySQLProtocol).map(\.port)).union(mysqlServers),
            postgresqlPorts: Set(instances.filter { !$0.kind.usesMySQLProtocol }.map(\.port)).union(postgresqlServers),
            redisPorts: redisPorts,
            realMainFolder: realMainFolder,
            smtpPort: try await smtpPort(in: await stateStore.current())
        )
    }

    // The main sites use the indexes below 16, the number that Redis has by default. An index with
    // keys is not free. A main site can use it, or a removal could not empty it. A workspace does
    // not keep an index that its main site uses now, or an index with keys on an instance that is
    // new for this workspace. A record without instances comes from before part 8f, so its keys
    // are the keys of the workspace.
    func redisIndexes(for plan: WorkspaceEnvPlan, of workspace: Workspace, state: EngineState) async throws -> (indexes: [String: Int], instances: [String]) {
        let instances = try await redisInstances().filter { plan.redisPorts.contains($0.port) }
        let mainIndexes = await redisIndexesOfMainSites().union(plan.mainRedisIndexes)
        var taken = Set(state.worktrees.values.flatMap(\.workspaces).flatMap(\.redisIndexes.values)).union(mainIndexes)
        var kept = workspace.redisIndexes.filter { !mainIndexes.contains($0.value) }

        for instance in instances {
            try await startForSetup(instance.id)
            let withKeys = try await indexesWithKeys(on: instance)
            taken.formUnion(withKeys)

            if !workspace.redisInstances.isEmpty, !workspace.redisInstances.contains(instance.id) {
                kept = kept.filter { !withKeys.contains($0.value) }
            }
        }

        taken.formUnion(emptyingRedisIndexes.map(\.index))

        let indexes = Self.numbers(for: plan.redisKeys, keeping: kept, from: Self.firstRedisIndex) { !taken.contains($0) }

        guard indexes.values.allSatisfy({ $0 < ServiceCatalog.redisDatabaseCount }) else {
            throw RuntimeError.unsupported("Redis has no free index for this workspace. Remove a workspace, and then retry.")
        }

        return (indexes, instances.map(\.id).sorted())
    }

    // A Node.js app needs a port in each workspace (D67).
    static func textsWithPorts(of sites: [Site], preset: [String]) -> [String] {
        let app = sites.contains { $0.kind == .node } ? ["{port:\(NodeAppLaunch.portName)}"] : []
        return sites.flatMap { $0.workspaceKeys ?? [] }.map(\.value) + commands(of: sites) + backgroundCommands(of: sites, preset: preset) + app
    }

    // A workspace keeps a port that its list lost, because its .env can still name that port. Another
    // workspace with that port would then get the connections of this workspace.
    func workspacePorts(for texts: [String], servers: [String] = [], of workspace: Workspace, state: EngineState) -> [String: Int] {
        let taken = takenPorts(state)
        let names = WorkspaceKeys.portNames(in: texts) + servers + workspace.ports.keys.sorted()

        return Self.numbers(for: names, keeping: workspace.ports, from: Self.firstWorkspacePort) {
            !taken.contains($0) && PortInspector.isFree($0)
        }
    }

    func takenPorts(_ state: EngineState) -> Set<Int> {
        Set(state.ports.values)
            .union(state.appPorts.values)
            .union(state.worktrees.values.flatMap(\.workspaces).flatMap(\.ports.values))
            .union(mainProcessPlans.values.flatMap(\.ports.values))
            .union(state.databaseRemovals.map(\.server.port))
    }

    // Each name keeps its number. A new name gets the lowest free number.
    static func numbers(for names: [String], keeping kept: [String: Int], from first: Int, isFree: (Int) -> Bool) -> [String: Int] {
        var numbers = kept.filter { names.contains($0.key) }
        var number = first

        for name in names where numbers[name] == nil {
            while !isFree(number) {
                number += 1
            }

            numbers[name] = number
            number += 1
        }

        return numbers
    }

    // What the .env of each workspace of this site gets, with {workspace} in the values.
    func workspaceEnvPreview(host: String) async throws -> [WorkspaceEnvKey] {
        let state = await stateStore.current()
        let resolved = resolvedSites(state).map(\.site)

        guard let site = resolved.first(where: { $0.host == host }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let key = ProjectFolder.workspaceKey(of: site)
        let sites = resolved.filter { ProjectFolder.workspaceKey(of: $0) == key }

        if site.kind == .node {
            return try await nodeEnvPreview(of: site, sites: sites, tld: state.tld)
        }

        guard site.kind == .php, let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return []
        }

        let mainFolder = RealPath.of(main)
        let probed = try await configuration(of: site, folder: mainFolder)
        let plan = try await envPlan(workspace: WorkspaceKeys.workspacePlaceholder, configuration: probed, mainFolder: mainFolder, workspaceFolder: "{worktree}")
        let hosts = Workspace.hostPairs(of: sites, workspace: WorkspaceKeys.workspacePlaceholder, tld: state.tld).map { HostRewrite(from: $0.from, to: $0.to) }
        let text = try Self.envText(of: "\(mainFolder)/.env")
        let own = sites.flatMap { $0.workspaceKeys ?? [] }
        let ownNames = Set(own.map(\.key))
        let preset = await presetCommands(probed, in: mainFolder)
        let hasReverbPort = WorkspaceKeys.portNames(in: Self.textsWithPorts(of: sites, preset: preset)).contains("reverb")
        let reverbKeys = hasReverbPort ? plan.reverbPortKeys : []
        var seen = plan.isolatingKeys.union(reverbKeys)
        let changes = EnvRewrite.hostChanges(in: text, hosts: hosts)
            .filter { seen.insert($0.key).inserted }
            .map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
        let fromNexus = changes
            + plan.keys.sorted { $0.key < $1.key }.map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
            + plan.mailKeys.sorted { $0.key < $1.key }.map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
            + plan.serverPortKeys.values.joined().sorted().map { WorkspaceEnvKey(key: $0, value: "the port of the database server of the workspace") }
            + plan.redisKeys.map { WorkspaceEnvKey(key: $0, value: "a free Redis index") }
            + reverbKeys.map { WorkspaceEnvKey(key: $0, value: "{port:reverb}") }

        return fromNexus.filter { !ownNames.contains($0.key) } + own
    }
}
