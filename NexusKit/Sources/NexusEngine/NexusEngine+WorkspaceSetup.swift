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
    private static let firstWorkspacePort = 20000

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
                let finished = await setUp(next.workspace, key: next.key)
                runningSetupKey = nil

                // A stop of nexusd also stops the database of a running copy. That failure says
                // nothing about the workspace. So the workspace stays in Preparing for the next start.
                guard !watchingStopped, await store(finished, key: next.key) else {
                    return
                }

                publishSites()
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
            }
        }

        startWorkspaceSetups()
        return "Nexus sets up the workspace \(name) again."
    }

    private func setUp(_ workspace: Workspace, key: String) async -> Workspace {
        var workspace = workspace

        do {
            if let written = try await writeEnvFile(of: &workspace, key: key) {
                try await copyData(of: written, into: &workspace, key: key)
            }

            if workspace.state == .preparing {
                workspace.state = .ready
            }
        } catch {
            workspace.state = Self.adding(String(describing: error), to: workspace.state)
        }

        return workspace
    }

    private static func adding(_ problem: String, to state: WorkspaceState) -> WorkspaceState {
        guard case .notIsolated(let reason) = state else {
            return .notIsolated(problem)
        }

        return .notIsolated("\(reason) \(problem)")
    }

    // A database stays as it is when the workspace has its copy already, because a second setup
    // must keep the data of the workspace. A database with the name of the copy that this
    // workspace did not make is not the property of Nexus. So Nexus does not replace it.
    private func copyData(of written: WrittenEnv, into workspace: inout Workspace, key: String) async throws {
        try await updateRecord(of: workspace.name, key: key) { [plannedCopies = written.databases.count] record in
            record.plannedCopies = plannedCopies
        }

        for database in written.databases {
            try await copy(database, for: workspace, key: key)
        }

        for file in written.sqliteFiles {
            try await clone(file, in: written.folder, git: written.git, into: &workspace)
        }
    }

    private func copy(_ database: WorkspaceDatabase, for workspace: Workspace, key: String) async throws {
        var tools: DatabaseTools?

        for candidate in await databaseRuntimes() where try await port(of: candidate) == database.port {
            tools = candidate
            break
        }

        guard let tools else {
            throw RuntimeError.unsupported("Nexus has no database instance on port \(database.port).")
        }

        let copy = WorkspaceDatabaseCopy(instance: tools.id, name: database.copy)

        // A config file can name another connection that the application does not use. When its
        // instance cannot start, the main site cannot use that connection either.
        do {
            try await startForSetup(tools.id)
        } catch is PortConflict where !database.isDefault {
            return
        }

        let exists = try await databaseExists(database.copy, on: tools)

        if workspace.databases.contains(copy), exists {
            return
        }

        // A copy that started and did not end is a half database of this workspace. So it goes.
        // A copy that the record names and that is gone gets a new run.
        let isOwn = workspace.startedCopies.contains(copy)

        guard !exists || isOwn else {
            throw RuntimeError.unsupported("\(tools.id) has a database \(database.copy) already, and this workspace did not make it. Remove that database, and then retry.")
        }

        // Without its source, a half copy cannot get a new run. The workspace must not use it.
        guard try await databaseExists(database.name, on: tools) else {
            if database.isDefault || exists {
                throw RuntimeError.unsupported("\(tools.id) has no database \(database.name). Import it, and then retry.")
            }

            return
        }

        try await updateRecord(of: workspace.name, key: key) { record in
            record.databases.removeAll { $0 == copy }
            record.startedCopies = record.startedCopies.filter { $0 != copy } + [copy]
        }
        publishSites()

        let source = DatabaseServer(host: "127.0.0.1", port: try await connectionPort(of: tools), account: try await account(of: tools))

        do {
            _ = try await copyDatabase(DatabaseCopy(source: source, database: database.name, instance: tools.id, name: database.copy, replace: isOwn))
        } catch {
            // A copy that failed leaves no database. A later database with this name is then not
            // from this workspace, and a retry must not drop it. The same applies to a database
            // that another program made after the check above.
            if error is DatabaseTargetExists, !isOwn {
                try? await updateRecord(of: workspace.name, key: key) { record in
                    record.startedCopies.removeAll { $0 == copy }
                }
            } else if (try? await databaseExists(database.copy, on: tools)) == false {
                try? await updateRecord(of: workspace.name, key: key) { record in
                    record.startedCopies.removeAll { $0 == copy }
                }
            }

            throw error
        }

        try await updateRecord(of: workspace.name, key: key) { record in
            record.startedCopies.removeAll { $0 == copy }
            record.databases.append(copy)
        }
    }

    // The record goes to the state at once, and it finds the workspace by name. A stop of nexusd
    // or a moved worktree must not lose it, because the next setup then refuses this copy.
    private func updateRecord(of workspace: String, key: String, _ change: @escaping @Sendable (inout Workspace) -> Void) async throws {
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
    // then write into the file of the main site. A database copy before this step can take minutes,
    // and git can remove or move the worktree in that time. A clone would make that folder again.
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
    private static func cloneOutsideTheActor(_ source: String, to target: String) async throws {
        try await Task.detached { try FileClone.clone(source, to: target) }.value
    }

    private struct WrittenEnv {
        let databases: [WorkspaceDatabase]
        let sqliteFiles: [WorkspaceFile]
        let folder: String
        let git: URL
    }

    // Returns nil when the workspace has no .env, so nothing after this step applies to it.
    private func writeEnvFile(of workspace: inout Workspace, key: String) async throws -> WrittenEnv? {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }

        guard let site = sites.first, let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return nil
        }

        let mainFolder = RealPath.of(main)
        let folder = Self.applicationFolder(mainFolder, of: site, in: workspace)
        let plan = try await envPlan(workspace: workspace.name, site: site, mainFolder: mainFolder, workspaceFolder: folder)

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        guard try await GitTool.ignores(".env", in: folder, git: git) else {
            workspace.state = .notIsolated("git does not ignore .env, so Nexus does not write that file.")
            return nil
        }

        let ownKeys = sites.flatMap { $0.workspaceKeys ?? [] }
        let earlierRedisIndexes = workspace.redisIndexesOnInstances

        (workspace.redisIndexes, workspace.redisInstances) = try await redisIndexes(for: plan, of: workspace, state: state)
        workspace.ports = workspacePorts(for: ownKeys, of: workspace, state: state)
        try await recordAssignments(of: workspace, key: key)

        // The file is read after the waits above, because a start of Redis can take long and the
        // user can change the .env of the worktree in that time.
        let target = "\(folder)/.env"
        let source = FileManager.default.fileExists(atPath: target) ? target : "\(mainFolder)/.env"
        let text = try Self.envText(of: source)
        let host = workspace.hosts(of: sites, tld: state.tld).first ?? ""
        let own = WorkspaceKeys.expanded(ownKeys, workspace: workspace.name, host: host, database: plan.database, ports: workspace.ports)
        let pairs = Workspace.hostPairs(of: sites, workspace: workspace.name, tld: state.tld)
        let hosts = (pairs + Workspace.pairsFromOtherTLDs(pairs, tld: state.tld)).map { HostRewrite(from: $0.from, to: $0.to) }
        let isolating = plan.keys.merging(workspace.redisIndexes.mapValues(String.init)) { _, redis in redis }
        let keys = isolating.merging(own) { _, own in own }

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

        // The application does not use a copy when a key of the site replaces its name. Another key
        // can still have that name.
        let unused = Set(replaced.compactMap { isolating[$0] }).subtracting(keys.values)

        return WrittenEnv(
            databases: plan.databases.filter { !unused.contains($0.copy) },
            sqliteFiles: plan.sqliteFiles.filter { !unused.contains($0.to) },
            folder: folder,
            git: git
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

    // The .env names these values from now on, and a database copy can take minutes. A stop of
    // nexusd in that time must not lose them. A later setup would then take a new index for a
    // workspace that wrote to the first one, and no record would name that first index.
    private func recordAssignments(of workspace: Workspace, key: String) async throws {
        try await updateRecord(of: workspace.name, key: key) { record in
            record.redisIndexes = workspace.redisIndexes
            record.redisInstances = workspace.redisInstances
            record.ports = workspace.ports
        }
    }

    // The application has the same path in the worktree as in the repository. A repository in the
    // public folder holds no application, so the folder of the workspace is the nearest place.
    private static func applicationFolder(_ mainFolder: String, of site: Site, in workspace: Workspace) -> String {
        guard let root = ProjectFolder.repository(of: site)?.root, RealPath.contains(root, mainFolder) else {
            return workspace.folder
        }

        return workspace.worktree + mainFolder.dropFirst(root.count)
    }

    // A file that Nexus cannot read is no empty file. The write would replace its lines.
    private static func envText(of file: String) throws -> String {
        guard FileManager.default.fileExists(atPath: file) else {
            return ""
        }

        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw RuntimeError.unsupported("Nexus cannot read \(file) as UTF-8 text, so it does not write the .env of this workspace.")
        }

        return text
    }

    private static func permissions(of file: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? Int ?? 0o600
    }

    func envPlan(workspace: String, site: Site, mainFolder: String, workspaceFolder: String) async throws -> WorkspaceEnvPlan {
        let installed = await installer.installedRuntimes()
        let php = try await phpCommand(installedPHP(site.php, in: installed))
        let configuration = try await ConfigurationProbe(php: URL(filePath: php.executable), environment: php.environment)
            .run(root: URL(filePath: mainFolder, directoryHint: .isDirectory))
        let instances = try await databaseInstances()
        let redisPorts = Set(try await redisInstances().map(\.port))

        return WorkspaceEnvPlan(configuration: configuration, request: WorkspaceEnvRequest(
            workspace: workspace,
            mainFolder: mainFolder,
            workspaceFolder: workspaceFolder,
            mysqlPorts: Set(instances.filter(\.kind.usesMySQLProtocol).map(\.port)),
            postgresqlPorts: Set(instances.filter { !$0.kind.usesMySQLProtocol }.map(\.port)),
            redisPorts: redisPorts
        ))
    }

    // The main sites use the indexes below 16, the number that Redis has by default. An index with
    // keys is not free. A main site can use it, or a removal could not empty it. A workspace does
    // not keep an index that its main site uses now, or an index with keys on an instance that is
    // new for this workspace. A record without instances comes from before part 8f, so its keys
    // are the keys of the workspace.
    private func redisIndexes(for plan: WorkspaceEnvPlan, of workspace: Workspace, state: EngineState) async throws -> (indexes: [String: Int], instances: [String]) {
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

    private func workspacePorts(for keys: [WorkspaceEnvKey], of workspace: Workspace, state: EngineState) -> [String: Int] {
        let taken = Set(state.ports.values).union(state.worktrees.values.flatMap(\.workspaces).flatMap(\.ports.values))

        return Self.numbers(for: WorkspaceKeys.portNames(in: keys), keeping: workspace.ports, from: Self.firstWorkspacePort) {
            !taken.contains($0) && PortInspector.isFree($0)
        }
    }

    // Each name keeps its number. A new name gets the lowest free number.
    private static func numbers(for names: [String], keeping kept: [String: Int], from first: Int, isFree: (Int) -> Bool) -> [String: Int] {
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

        guard let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return []
        }

        let mainFolder = RealPath.of(main)
        let plan = try await envPlan(workspace: WorkspaceKeys.workspacePlaceholder, site: site, mainFolder: mainFolder, workspaceFolder: "{worktree}")
        let hosts = Workspace.hostPairs(of: sites, workspace: WorkspaceKeys.workspacePlaceholder, tld: state.tld).map { HostRewrite(from: $0.from, to: $0.to) }
        let text = try Self.envText(of: "\(mainFolder)/.env")
        let own = sites.flatMap { $0.workspaceKeys ?? [] }
        let ownNames = Set(own.map(\.key))
        var seen = Set(plan.keys.keys).union(plan.redisKeys)
        let changes = EnvRewrite.hostChanges(in: text, hosts: hosts)
            .filter { seen.insert($0.key).inserted }
            .map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
        let fromNexus = changes
            + plan.keys.sorted { $0.key < $1.key }.map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
            + plan.redisKeys.map { WorkspaceEnvKey(key: $0, value: "a free Redis index") }

        return fromNexus.filter { !ownNames.contains($0.key) } + own
    }
}
