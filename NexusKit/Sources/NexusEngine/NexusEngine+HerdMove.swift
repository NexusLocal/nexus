import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusSupervisor

// The move from Herd or Valet (group 9, docs/group9-herd.md). nexusd reads the files of the app and
// of the projects, and it changes nothing in the app. The move copies while the app still runs. Then
// it waits until the user stops the app, and it takes over the ports, the domain and the .env files.
extension NexusEngine {
    static let herdMoveTaskID = "move-from-herd"
    static let herdDatabaseKinds: Set<String> = ["mysql", "mariadb", "postgresql", "mongodb"]

    func herdMovePlan() async -> HerdMovePlan? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        guard let found = Self.moveSetup(home: home) else {
            return nil
        }

        return HerdMovePlanner.plan(setup: found.setup, facts: await herdMoveFacts(setup: found.setup, source: found.source, home: home))
    }

    // Herd comes first when both apps have sites. Herd copies the sites of Valet at its first start.
    static func moveSetup(home: URL) -> (source: MoveSource, setup: HerdSetup)? {
        let found = [(MoveSource.herd, HerdReader.read(herd: HerdReader.folder(home: home))), (.valet, ValetReader.read(home: home))]
            .compactMap { source, setup in setup.map { (source: source, setup: $0) } }

        return found.first { $0.setup.hasSites } ?? found.first
    }

    func herdMoveFacts(setup: HerdSetup, source: MoveSource, home: URL) async -> HerdMoveFacts {
        let manifest = try? await manifest()
        let names = Self.herdDatabaseKinds.union(["php", "redis"])
        var offered: [String: [String]] = [:]
        var bytes: [String: Int64] = [:]

        for package in manifest?.packages ?? [] where names.contains(package.name) {
            offered[package.name, default: []].append(package.line)
            bytes["\(package.name)-\(package.line)"] = package.size.map(Int64.init)
        }

        let installed = await installer.installedRuntimes()

        for runtime in installed where names.contains(runtime.name) && !(offered[runtime.name] ?? []).contains(runtime.line) {
            offered[runtime.name, default: []].append(runtime.line)
        }

        offered = offered.mapValues { lines in Array(Set(lines)).sorted { VersionLine.isOlder($0, than: $1) } }

        let folders = HerdMovePlanner.siteFolders(of: setup)
        var projects: [String: HerdMoveFacts.Project] = [:]

        for folder in folders {
            projects[HerdMovePlanner.folderPath(folder)] = Self.herdProject(at: folder, home: home)
        }

        let ports = Set(projects.values.flatMap(Self.localPorts))
        let servers = await onOwnThread { Self.listeningServers(ports) }
        var redisKeys: [Int: Int] = [:]

        for (port, server) in servers where ["redis", "valkey"].contains(server.kind) {
            let password = projects.values.compactMap { $0.env?["REDIS_PORT"].flatMap(Int.init) == port ? $0.env?["REDIS_PASSWORD"] : nil }.first { $0 != "null" && !$0.isEmpty }
            redisKeys[port] = await onOwnThread { try? RedisWire(port: port, password: password, timeout: 3).keyspace().values.reduce(0, +) }
        }

        var shellFiles: [String: String] = [:]

        for name in [".zshrc", ".zprofile", ".bashrc", ".bash_profile"] {
            let file = home.appending(path: name)

            if let text = try? String(contentsOf: file, encoding: .utf8) {
                shellFiles[file.path(percentEncoded: false)] = text
            }
        }

        let state = await stateStore.current()

        return HerdMoveFacts(
            source: source,
            home: home,
            herdRuns: Self.isRunning(source),
            offered: offered,
            installed: Set(installed.map { "\($0.name)-\($0.line)" }),
            packageBytes: bytes,
            servers: servers,
            redisKeys: redisKeys,
            projects: projects,
            shellFiles: shellFiles,
            nexusHosts: Set(resolvedSites(state).flatMap(\.site.hosts)),
            nexusParked: Set(state.parked.map { HerdMovePlanner.folderPath($0.folder.standardizedFileURL) })
        )
    }

    // The ports of this Mac that the .env or wp-config.php of a project names.
    static func localPorts(of project: HerdMoveFacts.Project) -> [Int] {
        var ports: [Int] = []

        if let env = project.env {
            if let kind = HerdMovePlanner.databaseKinds[env["DB_CONNECTION"] ?? ""] {
                ports.append(env["DB_PORT"].flatMap(Int.init) ?? (kind == "postgresql" ? 5432 : kind == "mongodb" ? 27017 : 3306))
            }

            ports.append(env["REDIS_PORT"].flatMap(Int.init) ?? 6379)
        }

        if let host = project.wordPress?["DB_HOST"] {
            ports.append(DatabaseAddress(dbHost: host).localPort ?? DatabaseAddress.standardPort)
        }

        return ports
    }

    static func herdProject(at folder: URL, home: URL) -> HerdMoveFacts.Project {
        let type = PHPProject.type(of: folder)
        let env = FileManager.default.fileExists(atPath: folder.appending(path: ".env").path(percentEncoded: false)) ? EnvFile.values(of: folder.appending(path: ".env")) : nil
        var wordPress: [String: String]?

        if type.isWordPress, let core = PHPProject.wordPressFolder(in: folder), let config = WordPressFiles.configFile(core: core), let text = try? String(contentsOf: config, encoding: .utf8) {
            wordPress = wordPressConstants(in: text)
        }

        var projectFiles: [String: [String]] = [:]

        for name in HerdMovePlanner.projectFileNames {
            let file = folder.appending(path: name)

            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            let lines = text.components(separatedBy: "\n").filter { $0.contains("/Application Support/Herd/") }

            if !lines.isEmpty {
                projectFiles[file.path(percentEncoded: false)] = lines
            }
        }

        return HerdMoveFacts.Project(type: type, env: env, wordPress: wordPress, projectFiles: projectFiles)
    }

    // define('DB_NAME', 'news'); with single or double quotes. A value with a PHP expression is
    // not a plain value, so the move skips it.
    static func wordPressConstants(in text: String) -> [String: String] {
        var values: [String: String] = [:]

        for match in text.matches(of: #/define\(\s*['"](DB_NAME|DB_USER|DB_PASSWORD|DB_HOST)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/#) {
            values[String(match.1)] = String(match.2)
        }

        return values
    }

    // The program that listens on each port, with its version from --version.
    static func listeningServers(_ ports: Set<Int>) -> [Int: HerdMoveFacts.Server] {
        var servers: [Int: HerdMoveFacts.Server] = [:]

        for port in ports {
            guard let executable = PortInspector.owner(of: port)?.executable else {
                continue
            }

            let output = programOutput(executable, ["--version"]) ?? ""

            if let kind = serverKind(executable: executable, versionOutput: output) {
                servers[port] = HerdMoveFacts.Server(kind: kind, version: serverVersion(in: output))
            }
        }

        return servers
    }

    static func serverKind(executable: String, versionOutput: String) -> String? {
        let name = (executable as NSString).lastPathComponent

        switch name {
        case "mysqld": return versionOutput.contains("MariaDB") ? "mariadb" : "mysql"
        case "mariadbd": return "mariadb"
        case "postgres", "postmaster": return "postgresql"
        case "redis-server": return "redis"
        case "valkey-server": return "valkey"
        case "mongod": return "mongodb"
        default: return nil
        }
    }

    // mysqld prints "Ver 8.4.7", postgres "(PostgreSQL) 17.7", redis-server "v=8.4.0" and mongod
    // "db version v8.0.4". The path of the program can hold other numbers, so the label comes first.
    static func serverVersion(in output: String) -> String? {
        let labeled = [#/Ver (\d+\.\d+\.\d+)/#, #/\(PostgreSQL\) (\d+\.\d+)/#, #/v=(\d+\.\d+\.\d+)/#, #/version v(\d+\.\d+\.\d+)/#]

        for pattern in labeled {
            if let match = output.firstMatch(of: pattern) {
                return String(match.1)
            }
        }

        return output.firstMatch(of: #/\b(\d+\.\d+(\.\d+)?)\b/#).map { String($0.1) }
    }

    static func programOutput(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date.now.addingTimeInterval(5)

        while process.isRunning, Date.now < deadline {
            usleep(50_000)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // Valet runs the nginx of Homebrew as root.
    static func isRunning(_ source: MoveSource) -> Bool {
        switch source {
        case .herd:
            runningExecutables().contains { $0.hasSuffix("/Herd.app/Contents/MacOS/Herd") }
        case .valet:
            runningExecutables().contains { $0.contains("/Cellar/nginx/") && $0.hasSuffix("/bin/nginx") }
        }
    }

    static func runningExecutables() -> [String] {
        let count = proc_listallpids(nil, 0)

        guard count > 0 else {
            return []
        }

        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        return pids.prefix(Int(max(filled, 0))).compactMap { $0 > 0 ? PortInspector.executablePath(of: $0) : nil }
    }

    func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: work())
            }
        }
    }
}

extension HerdMovePlanner {
    // The folder of each site that the move reads: the subfolders of each parked folder and each
    // linked folder.
    static func siteFolders(of setup: HerdSetup) -> [URL] {
        setup.parkedFolders.flatMap(subfolders(of:)) + setup.links.map(\.folder)
    }

    // The plan with the choices of the user. The packages follow the items that stay on.
    static func applying(_ request: HerdMoveRequest, to plan: HerdMovePlan, facts: HerdMoveFacts) -> HerdMovePlan {
        let skipped = Set(request.skipped)
        let skipsOwnLines = skipped.contains(HerdMovePlan.ownLinesID)
        var result = plan

        result.parked = plan.parked.filter { !skipped.contains($0.id) }
        result.sites = plan.sites.filter { !skipped.contains($0.id) && ($0.parkedIn == nil || !skipped.contains("park:\($0.parkedIn ?? "")")) }.map { site in
            let chosen = request.php[site.id].flatMap { site.phpChoices.contains($0) ? $0 : nil }

            guard chosen != nil || skipsOwnLines else {
                return site
            }

            return HerdMovePlan.SiteItem(hosts: site.hosts, folder: site.folder, kind: site.kind, herdPHP: site.herdPHP, php: chosen ?? site.php, phpChoices: site.phpChoices, address: site.address, parkedIn: site.parkedIn, projectType: site.projectType, ownLines: skipsOwnLines ? [] : site.ownLines)
        }
        result.databases = plan.databases.filter { !skipped.contains($0.id) }.map { database in
            guard let line = request.databaseLines[database.id], database.lineChoices.contains(line) else {
                return database
            }

            return HerdMovePlan.DatabaseItem(name: database.name, kind: database.kind, version: database.version, port: database.port, socket: database.socket, account: database.account, line: line, lineChoices: database.lineChoices, bytes: database.bytes, sites: database.sites)
        }
        // A parked folder brings each of its subfolders. So a folder with a site that is off is not
        // parked. Its other sites come one by one.
        let partial = Set(plan.sites.filter { skipped.contains($0.id) }.compactMap(\.parkedIn))
        result.parked = result.parked.filter { !partial.contains($0.folder) }
        result.sites = result.sites.map { site in
            guard let folder = site.parkedIn, partial.contains(folder) else {
                return site
            }

            return HerdMovePlan.SiteItem(hosts: site.hosts, folder: site.folder, kind: site.kind, herdPHP: site.herdPHP, php: site.php, phpChoices: site.phpChoices, address: site.address, parkedIn: nil, projectType: site.projectType, ownLines: site.ownLines)
        }
        result.redis = plan.redis.filter { !skipped.contains($0.id) }
        result.ini = plan.ini.filter { !skipped.contains($0.id) }
        result.envFiles = plan.envFiles.filter { item in !skipped.contains(item.id) && result.sites.contains { $0.hosts.first == item.host } }
        result.files = plan.files.filter { !skipped.contains($0.id) }
        result.packages = packages(sites: result.sites, databases: result.databases, redis: result.redis, facts: facts)

        return result
    }
}
