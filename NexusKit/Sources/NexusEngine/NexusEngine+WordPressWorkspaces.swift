import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// The workspaces of a WordPress site (Phase 4, 3e). Each workspace gets a clone of the instance of
// its database (D66) and its own domain in WordPress. A classic site reads these values from
// wp-config.php. Bedrock reads them from its .env. The check loads WordPress only after these values
// are in place. So no code of the site runs on the main database. After the check, the links in the
// posts of the clone go to the workspace.
extension NexusEngine {
    // What the check and the change of the links need after the write. copy is the copy of an
    // ignored wp-config.php. It is written after the clone of the files, because a folder that git
    // ignores as a whole gets no clone when the worktree has that folder already.
    struct WordPressWrite {
        let core: URL
        let php: String
        let tools: DatabaseTools
        let serverPort: Int
        let mainPort: Int
        let url: String
        let siteURL: String
        let mainURL: String
        var network: (from: String, to: String)?
        let database: String?
        let tablePrefix: String?
        let redisIndex: Int?
        let isBedrock: Bool
        let configName: String
        var copy: ConfigCopy?
        // The live URLs of a dump file, for a network that changes its links after the load.
        var dumpURLs: [String] = []
    }

    struct ConfigCopy {
        let relative: String
        let project: String
        let values: [(name: String, value: String)]
    }

    // How the values of the workspace reach WordPress. A relative path is the place of the file in
    // the project folder.
    private enum ConfigWrite {
        case bedrock
        case copy(String)
        case include(String)
    }

    static let trackedConfigProblem = "git tracks wp-config.php, and the file does not load wp-config-nexus.php. So WordPress in this workspace would use the database of the main site, and Nexus runs no PHP here."

    // A WordPress workspace that leaves Ready must lose PHP at once. The web queue can hold the
    // caller of this function. So it does not wait.
    func applySitesSoon() {
        Task {
            if await applyWorkspaceSites() {
                publishSites()
            }
        }
    }

    // Returns nil when the workspace is not isolated. Nexus then makes no server for it.
    func writeWordPressConfig(of workspace: inout Workspace, site: Site, sites: [Site], key: String, state: EngineState) async throws -> WrittenEnv? {
        workspace.backgroundPreset = []
        workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites, preset: []), of: workspace, state: state)

        guard let folders = fileFolders(of: workspace, key: key, sites: sites) else {
            return nil
        }

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        let target = try await wordPressTarget(site.host)
        let project = folders.application
        let folder = folders.worktree

        // A workspace that is not isolated gets a new setup when its files change (D48).
        workspace.configurationDigest = Self.configurationDigest(of: folder, in: workspace.worktree)

        guard let config = target.config else {
            workspace.state = .notIsolated("The main checkout has no \(target.configName). So WordPress there has no database yet.")
            try await recordAssignments(of: workspace, key: key)
            return nil
        }

        let cache = try await objectCachePlan(of: target, config: config)
        let mode = try await configWrite(of: target, project: project, folder: folder, git: git, workspace: workspace)
        let problems = Self.dbHostProblems(config, file: target.configName, mysqlPorts: Set(await mysqlInstances().map(\.port))) + cache.problems + mode.problems

        guard problems.isEmpty, let kind = mode.kind, let mainPort = config.address?.localPort, let core = Self.worktreeCore(of: target, project: project, folder: folder) else {
            workspace.state = .notIsolated(problems.isEmpty ? "Nexus does not find the files of WordPress in the main checkout." : problems.joined(separator: " "))
            try await recordAssignments(of: workspace, key: key)
            return nil
        }

        // The check needs WP-CLI. Without it, the clone of the database would be of no use.
        _ = try await wpCLITool(php: site.php)

        let plan = WorkspaceEnvPlan(wordPressDatabase: config.database, port: mainPort, redisPort: cache.port, mainRedisIndex: config.redisDatabase ?? 0)
        let earlierRedisIndexes = workspace.redisIndexesOnInstances
        let instances = try await serverInstances(of: plan)

        (workspace.redisIndexes, workspace.redisInstances) = try await redisIndexes(for: plan, of: workspace, state: state)
        workspace.database = plan.database
        workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites, preset: []), servers: instances.map(\.tools.id), of: workspace, state: state)

        guard let instance = instances.first, let serverPort = workspace.ports[instance.tools.id] else {
            throw RuntimeError.unsupported("Nexus has no database instance on port \(mainPort).")
        }

        workspace.ports[Self.databasePortName] = serverPort
        try await recordAssignments(of: workspace, key: key)

        let host = workspace.hosts(of: sites, tld: state.tld).first ?? site.host
        let url = Self.url(for: host, in: state)
        let mainURL = Self.url(for: site.host, in: state)
        let network = Self.networkDomains(of: config, type: target.type, mainURL: mainURL, url: url)
        let redisIndex = workspace.redisIndexes[WorkspaceEnvPlan.wordPressRedisKey]
        let siteURL = url + Self.corePath(of: target)
        let values = Self.workspaceValues(config: config, databaseHost: "\(WorkspaceEnvPlan.serverHost):\(serverPort)", url: url, siteURL: siteURL, network: network, redisIndex: redisIndex)
        var copy: ConfigCopy?
        var writeProblems: [String] = []

        switch kind {
        case .bedrock:
            let pairs = Workspace.hostPairs(of: sites, workspace: workspace.name, tld: state.tld)
            let hosts = (pairs + Workspace.pairsFromOtherTLDs(pairs, tld: state.tld)).map { HostRewrite(from: $0.from, to: $0.to) }
            let account: Set<String> = ["DB_NAME", "DB_USER", "DB_PASSWORD", "WP_SITEURL"]
            let keys = Dictionary(values.filter { !account.contains($0.name) } + [("WP_HOME", url)], uniquingKeysWith: { _, last in last })
            writeProblems = try await writeBedrockEnvFiles(from: project, to: folder, git: git, keys: keys, serverPort: serverPort, hosts: hosts)
        case .copy(let relative):
            copy = ConfigCopy(relative: relative, project: project, values: values)
        case .include(let relative):
            try Data(WordPressWorkspaceConfig.includeFileText(values, workspace: workspace.name).utf8).write(to: URL(filePath: "\(folder)/\(relative)"), options: .atomic)
        }

        await emptyRedisIndexes(earlierRedisIndexes.subtracting(workspace.redisIndexesOnInstances).filter { !plan.mainRedisIndexes.contains($0.index) })

        guard writeProblems.isEmpty else {
            workspace.state = .notIsolated(writeProblems.joined(separator: " "))
            workspace.configurationDigest = Self.configurationDigest(of: folder, in: workspace.worktree)
            return nil
        }

        return WrittenEnv(
            servers: [(tools: instance.tools, mainPort: instance.mainPort, port: serverPort)],
            databases: plan.databases,
            sqliteFiles: [],
            folder: folder,
            git: git,
            database: plan.database,
            site: site,
            isolatingKeys: [],
            mainFolder: project,
            repositoryHoldsApplication: false,
            wordPress: WordPressWrite(
                core: core,
                php: site.php,
                tools: instance.tools,
                serverPort: serverPort,
                mainPort: mainPort,
                url: url,
                siteURL: siteURL,
                mainURL: mainURL,
                network: network,
                database: config.database,
                tablePrefix: config.safeTablePrefix,
                redisIndex: redisIndex,
                isBedrock: target.type == .bedrock,
                configName: target.configName,
                copy: copy
            )
        )
    }

    // The account of the main site goes with DB_HOST. The committed wp-config.php of a branch can
    // have another account than the file of the main checkout. The clone has the accounts of the
    // instance. So the account of the main site works there. A network keeps its URLs in the
    // database. So it gets no WP_HOME.
    static func workspaceValues(config: WordPressConfig, databaseHost: String, url: String, siteURL: String, network: (from: String, to: String)?, redisIndex: Int?) -> [(name: String, value: String)] {
        var values: [(name: String, value: String)] = [("DB_NAME", config.database), ("DB_USER", config.user), ("DB_PASSWORD", config.password)].compactMap { name, value in
            value.map { (name, $0) }
        }

        values.append(("DB_HOST", databaseHost))

        if let network {
            values.append(("DOMAIN_CURRENT_SITE", network.to))
        } else {
            values += [("WP_HOME", url), ("WP_SITEURL", siteURL)]
        }

        if let redisIndex {
            values.append((WorkspaceEnvPlan.wordPressRedisKey, String(redisIndex)))
        }

        return values
    }

    // DB_HOST must name a Nexus instance with its port. localhost makes PHP use a socket. A socket
    // ignores the port of the server of the workspace (A.0).
    static func dbHostProblems(_ config: WordPressConfig, file: String, mysqlPorts: Set<Int>) -> [String] {
        guard let host = config.host, let address = config.address else {
            return ["\(file) has no DB_HOST with a plain value. So Nexus cannot give this workspace its own server."]
        }

        if case .socket = address {
            return ["DB_HOST of the main site is \(host). PHP then uses a socket, and a socket ignores the port of the server of the workspace. Use \"Set DB_HOST…\" in the section WordPress."]
        }

        guard let port = address.localPort, mysqlPorts.contains(port) else {
            return ["DB_HOST names \(host). Nexus did not make that server, so it cannot give this workspace its own copy."]
        }

        return []
    }

    // A network keeps its domain in the database (3d). Bedrock names the domain in its .env.
    static func networkDomains(of config: WordPressConfig, type: PHPProjectType, mainURL: String, url: String) -> (from: String, to: String)? {
        let isNetwork = config.multisite == true || (type == .bedrock && config.domainCurrentSite?.isEmpty == false)

        guard isNetwork, let to = WordPressURL.domain(of: url), let from = config.domainCurrentSite ?? WordPressURL.domain(of: mainURL) else {
            return nil
        }

        return (from, to)
    }

    // The folder of WordPress below the document root, as in /wp. WP_SITEURL of the workspace needs
    // it. The option siteurl in the clone still names the main site until the links change.
    static func corePath(of target: WordPressTarget) -> String {
        guard let core = target.core else {
            return ""
        }

        let root = RealPath.of(target.site.documentRoot)
        let folder = RealPath.of(core)

        return folder.hasPrefix("\(root)/") ? String(folder.dropFirst(root.count)) : ""
    }

    // The core is in the worktree after the clone of the files. So its place comes from the main
    // checkout.
    private static func worktreeCore(of target: WordPressTarget, project: String, folder: String) -> URL? {
        guard let core = target.core, let relative = relativePath(core, in: project) else {
            return nil
        }

        return URL(filePath: relative.isEmpty ? folder : "\(folder)/\(relative)", directoryHint: .isDirectory)
    }

    private static func relativePath(_ file: URL, in folder: String) -> String? {
        let path = RealPath.of(file)

        if path == folder {
            return ""
        }

        return path.hasPrefix("\(folder)/") ? String(path.dropFirst(folder.count + 1)) : nil
    }

    // The plugin Redis Object Cache reads its index from WP_REDIS_DATABASE. Its drop-in makes that
    // name from parts. So its header tells. Another object cache with Redis keeps its index in a
    // setting that Nexus does not know. A Redis server that Nexus cannot name gives Not isolated. A
    // Redis that does not run gives no cache. So it needs nothing.
    static let redisObjectCacheDropIn = "Plugin Name: Redis Object Cache Drop-In"

    // The constants of Redis Object Cache for a server that is no single host and port.
    private static let otherRedisServers = ["WP_REDIS_SERVERS", "WP_REDIS_CLUSTER", "WP_REDIS_SENTINEL", "WP_REDIS_PATH"]

    private func objectCachePlan(of target: WordPressTarget, config: WordPressConfig) async throws -> (port: Int?, problems: [String]) {
        let names = target.type == .bedrock ? ["web/app/object-cache.php", "public/content/object-cache.php"] : ["wp-content/object-cache.php"]
        let base = target.type == .bedrock ? target.project : target.core
        let found = names.lazy.compactMap { name in
            base.flatMap { try? String(contentsOf: $0.appending(path: name), encoding: .utf8) }.map { (name, $0) }
        }.first

        guard let (name, text) = found, text.localizedCaseInsensitiveContains("redis") else {
            return (nil, [])
        }

        guard text.contains(Self.redisObjectCacheDropIn) || text.contains(WorkspaceEnvPlan.wordPressRedisKey) else {
            return (nil, ["\(name) keeps its Redis database in a setting that Nexus cannot change. So the workspace would use the cache of the main site."])
        }

        let configText = target.configFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let unreadable = (configText.contains("WP_REDIS_HOST") && config.redisHost == nil) || (configText.contains("WP_REDIS_PORT") && config.redisPort == nil)

        if unreadable || Self.otherRedisServers.contains(where: configText.contains) {
            return (nil, ["Nexus cannot read the Redis server of \(name) in \(target.configName) as plain values. So it cannot give this workspace its own Redis database."])
        }

        let host = config.redisHost ?? WorkspaceEnvPlan.serverHost
        let port = config.redisPort ?? 6379
        let isLocal = [WorkspaceEnvPlan.serverHost, "localhost", "::1"].contains(host.lowercased())

        if isLocal, try await redisInstances().contains(where: { $0.port == port }) {
            return (port, [])
        }

        if isLocal, PortInspector.isFree(port) {
            return (nil, [])
        }

        return (nil, ["\(name) uses Redis on \(host):\(port). Nexus did not make that server, so it cannot give this workspace its own Redis database."])
    }

    // An ignored wp-config.php gets the values in its copy (owner, 2026-11-07). A tracked file must
    // load wp-config-nexus.php before its define of DB_HOST. Git must ignore that file (D50).
    private func configWrite(of target: WordPressTarget, project: String, folder: String, git: URL, workspace: Workspace) async throws -> (kind: ConfigWrite?, problems: [String]) {
        guard target.type != .bedrock else {
            return (.bedrock, [])
        }

        guard let file = target.configFile, let relative = Self.relativePath(file, in: project) else {
            return (nil, ["wp-config.php is outside the project folder. So a worktree has no copy of it."])
        }

        if try await GitTool.ignores(relative, in: folder, git: git) {
            return (.copy(relative), [])
        }

        guard let text = try? String(contentsOfFile: "\(folder)/\(relative)", encoding: .utf8) else {
            return (nil, ["The branch of this worktree has no \(relative)."])
        }

        guard WordPressWorkspaceConfig.loadsIncludeFile(text) else {
            let mainText = try? String(contentsOf: file, encoding: .utf8)

            guard mainText.map(WordPressWorkspaceConfig.loadsIncludeFile) == true else {
                return (nil, [Self.trackedConfigProblem])
            }

            return (nil, ["wp-config.php in this worktree does not load wp-config-nexus.php yet. Commit the lines in the main checkout. Then bring the commit into the branch \(workspace.branch ?? workspace.name), and click Retry."])
        }

        let include = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(WordPressWorkspaceConfig.includeFile)

        guard try await GitTool.ignores(include, in: folder, git: git) else {
            return (nil, ["git does not ignore \(include), so Nexus does not write that file. Add the line \(WordPressWorkspaceConfig.includeFile) to .gitignore, and commit it."])
        }

        return (.include(include), [])
    }

    // The worktree keeps a copy that it has, as for the .env of a Laravel application.
    private static func writeConfigCopy(_ copy: ConfigCopy, to folder: String, workspace: String) throws -> [String] {
        let target = "\(folder)/\(copy.relative)"
        let source = FileManager.default.fileExists(atPath: target) ? target : "\(copy.project)/\(copy.relative)"

        guard let text = WordPressWorkspaceConfig.settingValues(copy.values, workspace: workspace, in: try envText(of: source)) else {
            return ["\(copy.relative) does not start with a line <?php. So Nexus cannot add the values of the workspace to it."]
        }

        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(filePath: target), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions(of: source)], ofItemAtPath: target)
        return []
    }

    // Bedrock reads .env and then .env.local. A key goes into each file that has it. .env gets each
    // key. DATABASE_URL wins over the DB_ keys in Bedrock. So it gets the port too.
    private func writeBedrockEnvFiles(from project: String, to folder: String, git: URL, keys: [String: String], serverPort: Int, hosts: [HostRewrite]) async throws -> [String] {
        var problems: [String] = []

        for name in [".env", ".env.local"] {
            let target = "\(folder)/\(name)"
            let source = FileManager.default.fileExists(atPath: target) ? target : "\(project)/\(name)"

            guard FileManager.default.fileExists(atPath: source) else {
                continue
            }

            let text = try Self.envText(of: source)
            let present = EnvFile.values(in: text)
            var fileKeys = name == ".env" ? keys : keys.filter { present[$0.key] != nil }

            if let databaseURL = present["DATABASE_URL"], !databaseURL.isEmpty {
                fileKeys["DATABASE_URL"] = ConnectionURL.pointing(databaseURL, toPort: serverPort)
            }

            guard try await GitTool.ignores(name, in: folder, git: git) else {
                problems.append("git does not ignore \(name), so Nexus does not change \(fileKeys.keys.sorted().joined(separator: ", ")) in it.")
                continue
            }

            try Data(EnvRewrite.apply(to: text, hosts: hosts, keys: fileKeys).utf8).write(to: URL(filePath: target), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.permissions(of: source)], ofItemAtPath: target)
        }

        return problems
    }

    // The check, in this order: the files of the worktree, then the domain of a network in the
    // clone, then WordPress itself with WP-CLI. WordPress then says which server and which URL it
    // uses. Plugins and themes do not load. WP-Cron and mail do not run.
    func checkWordPressWorkspace(_ write: WordPressWrite, folder: String, in workspace: inout Workspace, key: String) async throws {
        if let copy = write.copy {
            let problems = try Self.writeConfigCopy(copy, to: folder, workspace: workspace.name)
            workspace.configurationDigest = Self.configurationDigest(of: folder, in: workspace.worktree)

            guard problems.isEmpty else {
                workspace.state = .notIsolated(problems.joined(separator: " "))
                return
            }
        }

        if write.isBedrock, WordPressFiles.bedrockConfig(project: URL(filePath: folder, directoryHint: .isDirectory)).address?.localPort != write.serverPort {
            workspace.state = .notIsolated("The .env files of this worktree do not name the server of the workspace in DB_HOST.")
            return
        }

        var subsites: [WorkspaceLinks.Move] = []

        if let network = write.network {
            guard let database = write.database, let prefix = write.tablePrefix else {
                workspace.state = .notIsolated("Nexus cannot read the database or the table prefix of the network as plain text. So it cannot move the network to the domain of the workspace.")
                return
            }

            subsites = try await moveNetwork(network, database: database, prefix: prefix, tools: write.tools, of: workspace.name, key: key)
        }

        let wpCLI = try await wpCLICommand(in: write.core, failure: "WP-CLI did not load WordPress in this workspace.", php: write.php)
        let answer = try await workspaceCheck(wpCLI, url: write.network == nil ? nil : write.url)
        let problems = Self.workspaceCheckProblems(answer, write: write)

        guard problems.isEmpty else {
            workspace.state = .notIsolated(problems.joined(separator: " "))
            return
        }

        // A new clone has the URLs of the main site again. So only the home option of the clone
        // shows that the links changed.
        let earlier = workspace.links
        let changed = answer.storedHome.map { WordPressURL.same($0, write.url) } ?? false

        if changed, let earlier, earlier.done, earlier.to == write.url {
            return
        }

        // The filter changed the links of a dump during the load. WP-CLI changes only the tables
        // that it did not change.
        if workspace.databaseKind == .dump, write.network == nil, let earlier, earlier.to == write.url, earlier.tables != nil {
            return
        }

        let from = Self.distinctURLs(([answer.storedHome, write.mainURL, earlier?.to].compactMap { $0 } + (earlier?.from ?? []) + write.dumpURLs).filter { !WordPressURL.same($0, write.url) })
        var links = WorkspaceLinks(from: from, to: write.url, network: write.network != nil, done: from.isEmpty && subsites.isEmpty, subsites: subsites)
        workspace.links = links

        guard links.network, !links.done else {
            return
        }

        // A network does not load without the new domain in its content. So it waits here.
        try await updateRecord(of: workspace.name, key: key) { [links] record in
            record.links = links
        }

        try await changeWorkspaceLinks(links, core: write.core, php: write.php, owner: Self.processOwner(key: key, workspace: workspace.name))
        links.done = true
        workspace.links = links
    }

    // The domain of the network and of each site of a subdomain network moves in the clone. Each
    // site of a subdomain network keeps its own URL in its options. So it needs its own change of
    // the links.
    private func moveNetwork(_ network: (from: String, to: String), database: String, prefix: String, tools: DatabaseTools, of workspace: String, key: String) async throws -> [WorkspaceLinks.Move] {
        let record = await stateStore.current().worktrees[key]?.workspaces.first { $0.name == workspace }

        guard let server = record?.servers.first(where: { $0.instance == tools.id }) else {
            throw RuntimeError.unsupported("The workspace \(workspace) has no database server of \(tools.id).")
        }

        let (client, work) = try serverClient(tools, server)
        defer { try? FileManager.default.removeItem(at: work) }

        // A second setup finds a clone that moved already. Its domains then go back to the domains
        // of the main site for the moves.
        let domains = try await Self.networkDomains(in: database, prefix: prefix, with: client)
        let moved = domains.contains(network.to) && !domains.contains(network.from)
        let before = moved ? domains.map { $0.hasSuffix(".\(network.to)") ? "\($0.dropLast(network.to.count))\(network.from)" : $0 } : domains

        try await changeNetworkDomain(from: network.from, to: network.to, database: database, prefix: prefix, with: client)
        return Self.subsiteMoves(of: before, from: network.from, to: network.to)
    }

    struct WorkspaceCheck: Decodable, Equatable {
        let host: String?
        let home: String?
        let network: String?
        let redis: Int?
        let storedHome: String?
    }

    static let workspaceCheckSeparator = "@@nexus-workspace-check@@"

    static let workspaceCheckSource = #"""
    global $wpdb;

    echo '@@nexus-workspace-check@@' . json_encode([
        'host' => defined('DB_HOST') ? DB_HOST : null,
        'home' => home_url(),
        'network' => is_multisite() ? get_network()->domain : null,
        'redis' => defined('WP_REDIS_DATABASE') ? (int) WP_REDIS_DATABASE : null,
        'storedHome' => $wpdb->get_var("SELECT option_value FROM {$wpdb->options} WHERE option_name = 'home'"),
    ]) . '@@nexus-workspace-check@@';
    """#

    private func workspaceCheck(_ wpCLI: @escaping WPCLI, url: String?) async throws -> WorkspaceCheck {
        let arguments = ["--exec=\(Self.mailCheckSetup)", "eval", Self.workspaceCheckSource, "--skip-plugins", "--skip-themes"] + (url.map { ["--url=\($0)"] } ?? [])
        let answer = try await Self.evalAnswer(wpCLI, arguments: arguments, separator: Self.workspaceCheckSeparator, failure: "WP-CLI did not load WordPress in this workspace")

        guard let check = try? JSONDecoder().decode(WorkspaceCheck.self, from: Data(answer.utf8)) else {
            throw RuntimeError.unsupported("Nexus cannot read the answer of WP-CLI about this workspace.")
        }

        return check
    }

    // The text between the last two separators in the output of wp eval, within the time limit of
    // the mail check. The mail check of 3h and the check of a workspace use it.
    static func evalAnswer(_ wpCLI: @escaping WPCLI, arguments: [String], separator: String, failure: String) async throws -> Substring {
        let output = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await wpCLI(arguments) }
            group.addTask {
                try await Task.sleep(for: Self.mailCheckTimeout)
                return nil
            }

            defer { group.cancelAll() }

            guard let finished = try await group.next(), let output = finished else {
                throw RuntimeError.unsupported("\(failure) in \(Int(Self.mailCheckTimeout.components.seconds)) seconds.")
            }

            return output
        }

        guard let close = output.range(of: separator, options: .backwards),
              let open = output.range(of: separator, options: .backwards, range: output.startIndex..<close.lowerBound) else {
            throw RuntimeError.unsupported("Nexus cannot read the answer of WP-CLI.")
        }

        return output[open.upperBound..<close.lowerBound]
    }

    static func workspaceCheckProblems(_ answer: WorkspaceCheck, write: WordPressWrite) -> [String] {
        var problems: [String] = []
        let reached = answer.host.flatMap { DatabaseAddress(dbHost: $0).localPort }

        if reached != write.serverPort {
            let named = answer.host ?? "a server without DB_HOST"
            problems.append(reached == write.mainPort
                ? "WordPress in this workspace connects to \(named). That is the server of the main site, not the server of the workspace."
                : "WordPress in this workspace connects to \(named), not to the server of the workspace.")
        }

        if let network = write.network {
            if answer.network != network.to {
                problems.append("The network in this workspace has the domain \(answer.network ?? "of no network"), not the domain \(network.to) of the workspace.")
            }
        } else if let network = answer.network {
            problems.append("This site is a network, but Nexus cannot read MULTISITE in \(write.configName) as plain text. So the network keeps the domain \(network) in this workspace.")
        } else if !WordPressURL.same(answer.home ?? "", write.url) {
            problems.append("WordPress in this workspace uses the URL \(answer.home ?? "of no site"), not the URL \(write.url) of the workspace.")
        }

        if let index = write.redisIndex, answer.redis != index {
            problems.append("WordPress in this workspace uses the Redis database \(answer.redis ?? 0), not the database \(index) of the workspace.")
        }

        return problems
    }

    private static func distinctURLs(_ urls: [String]) -> [String] {
        urls.reduce(into: []) { result, url in
            if !result.contains(where: { WordPressURL.same($0, url) }) {
                result.append(url)
            }
        }
    }

    // The six forms of each URL of the main site, as in 3d. Each site of a subdomain network gets
    // its own URL. WP-CLI loads no plugin and no theme.
    func changeWorkspaceLinks(_ links: WorkspaceLinks, core: URL, php: String, owner: String) async throws {
        let wpCLI = try await wpCLICommand(in: core, failure: "WP-CLI did not change the links in the posts.", php: php)
        let passes = links.from.flatMap { WordPressURL.replacements(from: $0, to: links.to) }
            + links.subsites.flatMap { WordPressURL.replacements(from: $0.from, to: $0.to) }

        defer {
            linkProgress[owner] = nil
            publishSites()
        }

        linkProgress[owner] = 0
        publishSites()

        let tables: [String]?

        if let known = links.tables {
            tables = known
        } else {
            tables = await tablesWithLinks(to: links.from + links.subsites.map(\.from), network: links.network ? links.to : nil, with: wpCLI)
        }

        if let tables, tables.isEmpty {
            return
        }

        // WP-CLI keeps only the tables of its list that it knows. Without --all-tables-with-prefix
        // it knows only the tables of WordPress itself, because no plugin loads.
        let options = (tables ?? []) + ["--all-tables-with-prefix", "--skip-columns=guid"] + (links.network ? ["--network", "--url=\(links.to)"] : [])

        for (index, pass) in passes.enumerated() {
            guard !watchingStopped else {
                throw CancellationError()
            }

            linkProgress[owner] = Double(index) / Double(passes.count)
            publishSites()
            _ = try await searchReplace(pass, options: options, with: wpCLI)
        }
    }

    // A site that is no network is Ready before its links change (open decision 2). A stop of
    // nexusd keeps the change in the record. So the next start runs it again. After "Stop all
    // services" the change waits for the next start of the services.
    func startLinkChanges() async {
        guard !stoppingAllServices else {
            return
        }

        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)

        for (key, list) in state.worktrees {
            for workspace in list.workspaces where workspace.state == .ready {
                let owner = Self.processOwner(key: key, workspace: workspace.name)

                guard !watchingStopped,
                      linkChanges[owner] == nil,
                      let links = workspace.links,
                      !links.done,
                      let site = sites.first(where: { ProjectFolder.workspaceKey(of: $0) == key }),
                      let folder = fileFolders(of: workspace, key: key, sites: sites)?.worktree,
                      let core = PHPProject.wordPressFolder(in: URL(filePath: folder, directoryHint: .isDirectory)) else {
                    continue
                }

                linkChanges[owner] = Task { await self.finishLinks(links, of: workspace, key: key, core: core, php: site.php, owner: owner) }
            }
        }
    }

    // A failed change gives a warning. A setup of this workspace that waits for the change starts
    // after it.
    private func finishLinks(_ links: WorkspaceLinks, of workspace: Workspace, key: String, core: URL, php: String, owner: String) async {
        if await serversRun(of: workspace) {
            do {
                try await changeWorkspaceLinks(links, core: core, php: php, owner: owner)
                try? await updateRecord(of: workspace.name, key: key) { record in
                    if record.links?.to == links.to {
                        record.links?.done = true
                    }
                }
            } catch {
                let warning = "Nexus did not change the links in the posts to \(links.to). \(ErrorText.plain(error))"

                if !watchingStopped {
                    try? await updateRecord(of: workspace.name, key: key) { record in
                        record.links = nil
                        record.warnings.append(warning)
                    }
                }
            }
        }

        linkChanges[owner] = nil
        publishSites()

        if await stateStore.current().worktrees[key]?.workspaces.contains(where: { $0.name == workspace.name && $0.state == .preparing }) == true {
            startWorkspaceSetups()
        }
    }

    // The server of a workspace starts with the sync. It needs a moment. A server that does not
    // start leaves the change for a later run.
    private func serversRun(of workspace: Workspace) async -> Bool {
        await syncBackgroundProcesses().value
        let runtimes = await databaseRuntimes()

        for server in workspace.servers {
            guard let tools = runtimes.first(where: { $0.id == server.instance }), (try? await waitForServer(tools, port: server.port)) != nil else {
                return false
            }
        }

        return true
    }

    // The lines for workspaces in a tracked wp-config.php (open decision 3). A worktree gets only
    // the files that git tracks. An ignored wp-config.php gets the values in its copy. So it needs
    // no lines. The lines count as committed when the last commit has them.
    func workspaceLines(of target: WordPressTarget) async -> WordPressWorkspaceLines? {
        guard target.type == .wordpress,
              let file = target.configFile,
              let root = ProjectFolder.repository(of: target.site)?.root,
              let relative = Self.relativePath(file, in: RealPath.of(URL(filePath: root, directoryHint: .isDirectory))),
              let text = try? String(contentsOf: file, encoding: .utf8),
              let git = await GitTool.executable(),
              (try? await GitTool.tracks(relative, in: root, git: git)) == true else {
            return nil
        }

        let include = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(WordPressWorkspaceConfig.includeFile)
        let ignoreFile = (try? await GitTool.ignores(include, in: root, git: git)) == true ? nil : ".gitignore"

        guard WordPressWorkspaceConfig.loadsIncludeFile(text) else {
            return WordPressWorkspaceConfig.addingIncludeLines(to: text).map { change in
                WordPressWorkspaceLines(state: .missing, configFile: relative, changes: change.lines, ignoreFile: ignoreFile)
            }
        }

        if ignoreFile != nil {
            return WordPressWorkspaceLines(state: .missing, configFile: relative, ignoreFile: ignoreFile)
        }

        let committedConfig = await GitTool.committedText(relative, in: root, git: git)
        let ignoreChanged = (try? await GitTool.hasChanges([".gitignore"], in: root, git: git)) ?? false
        let committedIgnore = await GitTool.committedText(".gitignore", in: root, git: git) ?? ""
        let committed = committedConfig.map(WordPressWorkspaceConfig.loadsIncludeFile) == true && (!ignoreChanged || committedIgnore.contains(WordPressWorkspaceConfig.includeFile))

        return committed ? nil : WordPressWorkspaceLines(state: .uncommitted, configFile: relative)
    }

    // The file of the main checkout changes only after a click of the user. The user commits it.
    func addWordPressWorkspaceLines(host: String, lines: WordPressWorkspaceLines) async throws -> String {
        let target = try await wordPressTarget(host)

        guard lines.state == .missing,
              await workspaceLines(of: target) == lines,
              let file = target.configFile,
              let root = ProjectFolder.repository(of: target.site)?.root else {
            throw RuntimeError.unsupported("wp-config.php of \(host) is not the same as at the check. Nexus changed nothing. Check the site again.")
        }

        var texts: [URL: String] = [:]

        if let change = WordPressWorkspaceConfig.addingIncludeLines(to: try String(contentsOf: file, encoding: .utf8)) {
            texts[file] = change.text
        }

        if let ignoreFile = lines.ignoreFile {
            let url = URL(filePath: root, directoryHint: .isDirectory).appending(path: ignoreFile)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            texts[url] = old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + "\(WordPressWorkspaceConfig.includeFile)\n"
        }

        try Self.writeAll(texts)

        let files = [lines.configFile] + (lines.ignoreFile.map { [$0] } ?? [])
        return "Nexus changed \(EnglishList.joined(files)). Commit the change. A worktree of a branch with this commit gets its own database."
    }
}
