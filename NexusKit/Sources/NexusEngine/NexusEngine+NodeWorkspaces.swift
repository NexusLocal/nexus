import Foundation
import NexusCore
import NexusLaravel
import NexusRuntime
import NexusWorkspaces

// The env files of a workspace of a Node.js app (D67). The plan comes from the files of the main
// checkout. Each file that git ignores gets the hosts of the workspace and the keys of the plan in
// the worktree. git puts a file that it does not ignore in the worktree itself, so Nexus does not
// change it, and a key of the plan in that file gives Not isolated (D48, D50).
extension NexusEngine {
    func writeNodeEnvFiles(of workspace: inout Workspace, site: Site, sites: [Site], key: String, state: EngineState) async throws -> WrittenEnv? {
        guard let folders = fileFolders(of: workspace, key: key, sites: sites) else {
            return nil
        }

        let mainFolder = folders.application
        let folder = folders.worktree
        let project = NodeProject.read(in: URL(filePath: mainFolder, directoryHint: .isDirectory))
        let plan = try await nodeEnvPlan(workspace: workspace.name, files: try Self.nodeEnvFiles(in: mainFolder), usesDatabaseClient: project?.usesDatabaseClient ?? false, mainFolder: mainFolder, workspaceFolder: folder)

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        let ownKeys = sites.flatMap { $0.workspaceKeys ?? [] }
        let earlierRedisIndexes = workspace.redisIndexesOnInstances
        let instances = try await serverInstances(of: plan)

        (workspace.redisIndexes, workspace.redisInstances) = try await redisIndexes(for: plan, of: workspace, state: state)
        workspace.backgroundPreset = []
        workspace.database = plan.database
        workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites, preset: []), servers: instances.map(\.tools.id), of: workspace, state: state)

        if let mainPort = plan.databases.first(where: \.isDefault)?.port, let instance = instances.first(where: { $0.mainPort == mainPort }) {
            workspace.ports[Self.databasePortName] = workspace.ports[instance.tools.id]
        }

        try await recordAssignments(of: workspace, key: key)

        let servers = instances.compactMap { instance in
            workspace.ports[instance.tools.id].map { (tools: instance.tools, mainPort: instance.mainPort, port: $0) }
        }
        let host = workspace.hosts(of: sites, tld: state.tld).first ?? ""
        let pairs = Workspace.hostPairs(of: sites, workspace: workspace.name, tld: state.tld)
        let isolating = NodeEnvValues(
            plan: plan,
            serverPorts: Dictionary(uniqueKeysWithValues: servers.map { ($0.mainPort, $0.port) }),
            redisIndexes: workspace.redisIndexes
        )
        let writeProblems = try await writeNodeEnvFiles(
            from: mainFolder,
            to: folder,
            git: git,
            isolating: isolating,
            own: WorkspaceKeys.expanded(ownKeys, workspace: workspace.name, host: host, database: plan.database, ports: workspace.ports),
            hosts: (pairs + Workspace.pairsFromOtherTLDs(pairs, tld: state.tld)).map { HostRewrite(from: $0.from, to: $0.to) }
        )

        await emptyRedisIndexes(earlierRedisIndexes.subtracting(workspace.redisIndexesOnInstances).filter { !plan.mainRedisIndexes.contains($0.index) })

        let problems = plan.problems + writeProblems

        if !problems.isEmpty {
            workspace.state = .notIsolated(problems.joined(separator: " "))
        }

        return WrittenEnv(
            servers: servers,
            databases: plan.databases,
            sqliteFiles: [],
            folder: folder,
            git: git,
            database: plan.database,
            site: site,
            isolatingKeys: plan.isolatingKeys,
            mainFolder: mainFolder,
            repositoryHoldsApplication: false,
            warnings: plan.warnings
        )
    }

    // The worktree keeps a file that it has, as for a Laravel application. An own key goes into each
    // file that has it, because the frameworks read these files in different orders. .env comes
    // last. It also gets each own key that no other file got, as a new line.
    private func writeNodeEnvFiles(from mainFolder: String, to folder: String, git: URL, isolating: NodeEnvValues, own: [String: String], hosts: [HostRewrite]) async throws -> [String] {
        let manager = FileManager.default
        var problems: [String] = []
        var writtenOwnKeys: Set<String> = []

        for name in NodeEnvFile.names.filter({ $0 != ".env" }) + [".env"] {
            let target = "\(folder)/\(name)"
            let source = manager.fileExists(atPath: target) ? target : "\(mainFolder)/\(name)"
            let hasSource = manager.fileExists(atPath: source)
            let text = hasSource ? try Self.envText(of: source) : ""
            let present = Set(EnvFile.values(in: text).keys)
            let values = isolating.values(in: text)
            let ownHere = own.filter { present.contains($0.key) || (name == ".env" && !writtenOwnKeys.contains($0.key)) }
            let keys = values.merging(ownHere) { _, own in own }

            guard hasSource || !keys.isEmpty else {
                continue
            }

            guard try await GitTool.ignores(name, in: folder, git: git) else {
                if !keys.isEmpty {
                    problems.append("git does not ignore \(name), so Nexus does not change \(keys.keys.sorted().joined(separator: ", ")) in it.")
                }

                continue
            }

            writtenOwnKeys.formUnion(ownHere.keys)

            problems += values.keys.filter { keys[$0] != values[$0] }.sorted().map { "The key \($0) of the site replaces the value that isolates this workspace." }

            try Data(EnvRewrite.apply(to: text, hosts: hosts, keys: keys).utf8).write(to: URL(filePath: target), options: .atomic)
            try manager.setAttributes([.posixPermissions: hasSource ? Self.permissions(of: source) : 0o600], ofItemAtPath: target)
        }

        return problems
    }

    // After the install, the worktree can have its own env files, for example a tracked
    // .env.development of its branch. A key there that still leads to a server of the main site
    // gives Not isolated. The servers of the workspace count as Nexus instances here.
    func checkNodeEnvFiles(of written: WrittenEnv, in workspace: inout Workspace) async throws {
        let ownPorts = Set(written.servers.map(\.port))
        let project = NodeProject.read(in: URL(filePath: written.folder, directoryHint: .isDirectory))
        let plan = try await nodeEnvPlan(workspace: workspace.name, files: try Self.nodeEnvFiles(in: written.folder), usesDatabaseClient: project?.usesDatabaseClient ?? false, mainFolder: written.folder, workspaceFolder: written.folder, servers: written.servers)
        let wrongPorts = plan.serverPorts.filter { !ownPorts.contains($0) }
        let newKeys = plan.serverURLKeys.union(plan.serverPortKeys.values.joined()).subtracting(written.isolatingKeys).sorted()
        var problems = plan.problems
        problems += newKeys.map { "The key \($0) is not in the env files of the main checkout. So Nexus does not change it." }
        problems += wrongPorts.map { "An env file of the worktree names the server on port \($0), and that is not the database server of this workspace." }

        if !problems.isEmpty {
            workspace.state = .notIsolated((["The env files of this worktree are different from the main checkout."] + problems).joined(separator: " "))
        }
    }

    // servers holds the servers of the workspace, for the check of a worktree, as for a Laravel
    // application.
    func nodeEnvPlan(workspace: String, files: [NodeEnvFile], usesDatabaseClient: Bool, mainFolder: String, workspaceFolder: String, servers: [(tools: DatabaseTools, mainPort: Int, port: Int)] = []) async throws -> WorkspaceEnvPlan {
        WorkspaceEnvPlan(nodeFiles: files, usesDatabaseClient: usesDatabaseClient, request: try await workspaceEnvRequest(
            workspace: workspace,
            mainFolder: mainFolder,
            workspaceFolder: workspaceFolder,
            servers: servers
        ))
    }

    // What the env files of each workspace of this Node.js app get, with {workspace} in the values.
    func nodeEnvPreview(of site: Site, sites: [Site], tld: String) async throws -> [WorkspaceEnvKey] {
        let mainFolder = RealPath.of(URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory))
        let files = try Self.nodeEnvFiles(in: mainFolder)
        let project = NodeProject.read(in: URL(filePath: mainFolder, directoryHint: .isDirectory))
        let plan = try await nodeEnvPlan(workspace: WorkspaceKeys.workspacePlaceholder, files: files, usesDatabaseClient: project?.usesDatabaseClient ?? false, mainFolder: mainFolder, workspaceFolder: "{worktree}")
        let hosts = Workspace.hostPairs(of: sites, workspace: WorkspaceKeys.workspacePlaceholder, tld: tld).map { HostRewrite(from: $0.from, to: $0.to) }
        let own = sites.flatMap { $0.workspaceKeys ?? [] }
        let ownNames = Set(own.map(\.key))
        var seen = plan.isolatingKeys
        let changes = files.flatMap { EnvRewrite.hostChanges(in: $0.text, hosts: hosts) }
            .filter { seen.insert($0.key).inserted }
            .map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
        let fromNexus = changes
            + plan.keys.sorted { $0.key < $1.key }.map { WorkspaceEnvKey(key: $0.key, value: $0.value) }
            + plan.serverPortKeys.values.joined().sorted().map { WorkspaceEnvKey(key: $0, value: "the port of the database server of the workspace") }
            + plan.serverURLKeys.sorted().map { WorkspaceEnvKey(key: $0, value: "the URL with the database server of the workspace") }
            + plan.redisKeys.map { WorkspaceEnvKey(key: $0, value: plan.redisURLKeys.contains($0) ? "the URL with a free Redis index" : "a free Redis index") }

        return fromNexus.filter { !ownNames.contains($0.key) } + own
    }

    static func nodeEnvFiles(in folder: String) throws -> [NodeEnvFile] {
        try NodeEnvFile.names.compactMap { name in
            let path = "\(folder)/\(name)"

            guard FileManager.default.fileExists(atPath: path) else {
                return nil
            }

            return NodeEnvFile(name: name, text: try envText(of: path))
        }
    }
}

// The values that isolate a workspace, for the keys of one env file. A URL keeps its user, its
// password and its database. A URL that already names a server of the workspace stays, because a
// workspace keeps its ports. The same key can name a server on another computer in another file,
// and that URL stays too.
struct NodeEnvValues {
    let plan: WorkspaceEnvPlan
    let serverPorts: [Int: Int]
    let redisIndexes: [String: Int]

    func values(in text: String) -> [String: String] {
        let fixed = plan.keys.merging(serverPorts.flatMap { mainPort, port in (plan.serverPortKeys[mainPort] ?? []).map { ($0, String(port)) } }) { _, port in port }
        var values: [String: String] = [:]

        for (key, value) in EnvFile.values(in: text) {
            let localURL = ConnectionURL(value).flatMap { $0.isLocal ? $0 : nil }

            if let fixedValue = fixed[key] {
                values[key] = fixedValue
            } else if plan.serverURLKeys.contains(key), let url = localURL, let port = serverPorts[url.port] {
                values[key] = ConnectionURL.pointing(value, toPort: port)
            } else if plan.redisURLKeys.contains(key), localURL != nil, let index = redisIndexes[key] {
                values[key] = ConnectionURL.withRedisIndex(value, index)
            } else if !plan.redisURLKeys.contains(key), let index = redisIndexes[key] {
                values[key] = String(index)
            }
        }

        return values
    }
}
