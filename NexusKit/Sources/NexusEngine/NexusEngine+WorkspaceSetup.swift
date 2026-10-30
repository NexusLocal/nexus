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

                guard await store(finished, key: next.key) else {
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
            try await writeEnvFile(of: &workspace, key: key)

            if workspace.state == .preparing {
                workspace.state = .ready
            }
        } catch {
            workspace.state = .notIsolated(String(describing: error))
        }

        return workspace
    }

    private func writeEnvFile(of workspace: inout Workspace, key: String) async throws {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }

        guard let site = sites.first, let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return
        }

        let mainFolder = RealPath.of(main)
        let folder = Self.applicationFolder(mainFolder, of: site, in: workspace)
        let plan = try await envPlan(workspace: workspace.name, site: site, mainFolder: mainFolder, workspaceFolder: folder)

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        guard try await GitTool.ignores(".env", in: folder, git: git) else {
            workspace.state = .notIsolated("git does not ignore .env, so Nexus does not write that file.")
            return
        }

        let target = "\(folder)/.env"
        let source = FileManager.default.fileExists(atPath: target) ? target : "\(mainFolder)/.env"
        let text = try Self.envText(of: source)
        let ownKeys = sites.flatMap { $0.workspaceKeys ?? [] }

        workspace.redisIndexes = redisIndexes(for: plan.redisKeys, of: workspace, state: state)
        workspace.ports = workspacePorts(for: ownKeys, of: workspace, state: state)

        let host = workspace.hosts(of: sites, tld: state.tld).first ?? ""
        let own = WorkspaceKeys.expanded(ownKeys, workspace: workspace.name, host: host, database: plan.database, ports: workspace.ports)
        let pairs = Workspace.hostPairs(of: sites, workspace: workspace.name, tld: state.tld)
        let hosts = (pairs + Workspace.pairsFromOtherTLDs(pairs, tld: state.tld)).map { HostRewrite(from: $0.from, to: $0.to) }
        let isolating =plan.keys.merging(workspace.redisIndexes.mapValues(String.init)) { _, redis in redis }
        let keys = isolating.merging(own) { _, own in own }

        try Data(EnvRewrite.apply(to: text, hosts: hosts, keys: keys).utf8).write(to: URL(filePath: target), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: Self.permissions(of: source)], ofItemAtPath: target)

        let replaced = isolating.keys.filter { keys[$0] != isolating[$0] }.sorted()
        let problems = plan.problems
            + replaced.map { "The key \($0) of the site replaces the value that isolates this workspace." }
            + Self.cachedConfigurationProblem(in: folder)

        if !problems.isEmpty {
            workspace.state = .notIsolated(problems.joined(separator: " "))
        }
    }

    // The probe checks the main checkout. A worktree can have its own cached configuration, and the
    // application then does not read the .env that Nexus writes.
    private static func cachedConfigurationProblem(in folder: String) -> [String] {
        guard FileManager.default.fileExists(atPath: "\(folder)/bootstrap/cache/config.php") else {
            return []
        }

        return ["The worktree has bootstrap/cache/config.php, so the application ignores the .env of the workspace. Run php artisan config:clear in the worktree."]
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

    private func envPlan(workspace: String, site: Site, mainFolder: String, workspaceFolder: String) async throws -> WorkspaceEnvPlan {
        let installed = await installer.installedRuntimes()
        let php = try await phpCommand(installedPHP(site.php, in: installed))
        let configuration = try await ConfigurationProbe(php: URL(filePath: php.executable), environment: php.environment)
            .run(root: URL(filePath: mainFolder, directoryHint: .isDirectory))
        let instances = try await databaseInstances()
        let ports = await stateStore.current().ports

        return WorkspaceEnvPlan(configuration: configuration, request: WorkspaceEnvRequest(
            workspace: workspace,
            mainFolder: mainFolder,
            workspaceFolder: workspaceFolder,
            mysqlPorts: Set(instances.filter(\.kind.usesMySQLProtocol).map(\.port)),
            postgresqlPorts: Set(instances.filter { !$0.kind.usesMySQLProtocol }.map(\.port)),
            redisPorts: Set(ports.filter { $0.key.hasPrefix("redis-") }.values)
        ))
    }

    // The main sites use the indexes below 16, the number that Redis has by default.
    private func redisIndexes(for keys: [String], of workspace: Workspace, state: EngineState) -> [String: Int] {
        let taken = Set(state.worktrees.values.flatMap(\.workspaces).flatMap(\.redisIndexes.values))

        return Self.numbers(for: keys, keeping: workspace.redisIndexes, from: Self.firstRedisIndex) { !taken.contains($0) }
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
