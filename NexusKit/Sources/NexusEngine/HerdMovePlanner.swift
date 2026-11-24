import Foundation
import NexusCore
import NexusIPC

// What nexusd knows about this Mac when it plans the move from Herd. The planner itself reads no
// file and starts no program, so the tests give it these facts.
struct HerdMoveFacts: Sendable {
    // A server that listens on a port of this Mac. kind is mysql, mariadb, postgresql, mongodb,
    // redis or valkey.
    struct Server: Sendable, Equatable {
        let kind: String
        let version: String?
    }

    // The files of one project that the plan needs.
    struct Project: Sendable, Equatable {
        let type: PHPProjectType
        let env: [String: String]?
        let wordPress: [String: String]?
        let projectFiles: [String: [String]]
    }

    var home: URL
    var herdRuns: Bool
    // The lines of the manifest, by package name, for example "php": ["8.2", "8.3", "8.4", "8.5"].
    var offered: [String: [String]]
    // Installed packages as "<name>-<line>", for example "php-8.5" and "mysql-8.4".
    var installed: Set<String>
    var packageBytes: [String: Int64]
    var servers: [Int: Server]
    var redisKeys: [Int: Int]
    var projects: [String: Project]
    // The text of each shell file of the user that exists, by path.
    var shellFiles: [String: String]
    // The hosts and the parked folders that Nexus has already, for example after a move.
    var nexusHosts: Set<String> = []
    var nexusParked: Set<String> = []
}

enum HerdMovePlanner {
    static let databaseKinds = ["mysql": "mysql", "mariadb": "mariadb", "pgsql": "postgresql", "mongodb": "mongodb"]
    static let redisDrivers: Set<String> = ["CACHE_STORE", "CACHE_DRIVER", "QUEUE_CONNECTION", "SESSION_DRIVER", "BROADCAST_CONNECTION"]
    static let projectFileNames = [".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json", ".junie/mcp/mcp.json", ".ai/mcp/mcp.json", ".gemini/settings.json", "opencode.json"]

    static func plan(setup: HerdSetup, facts: HerdMoveFacts) -> HerdMovePlan {
        var notes: [String] = []
        let phpLines = facts.offered["php"] ?? []
        let defaultPHP = setup.defaultPHP
        let worktrees = Set(setup.workspaces.filter { $0.kind == "worktree" }.map { folderPath($0.folder.standardizedFileURL) })

        func php(for host: String) -> (herd: String?, line: String?) {
            let herd = setup.siteFile(of: host)?.php ?? defaultPHP
            return (herd, herd.flatMap { phpLine(for: $0, offered: phpLines) } ?? phpLines.last)
        }

        var sites: [HerdMovePlan.SiteItem] = []
        var parked: [HerdMovePlan.ParkedFolder] = []

        for folder in setup.parkedFolders {
            let parkedPHP = defaultPHP.flatMap { phpLine(for: $0, offered: phpLines) } ?? phpLines.last ?? "8.4"
            parked.append(HerdMovePlan.ParkedFolder(folder: folderPath(folder), php: parkedPHP))

            for child in subfolders(of: folder) where !worktrees.contains(folderPath(child)) {
                let host = "\(HostName.label(from: child.lastPathComponent)).\(setup.tld)"
                sites.append(siteItem(hosts: [host], folder: child, parkedIn: folder, setup: setup, facts: facts, php: php(for: host)))
            }
        }

        for link in setup.links where !worktrees.contains(folderPath(link.folder)) {
            let hosts = link.names.map { "\($0).\(setup.tld)" }
            sites.removeAll { $0.hosts.first.map(hosts.contains) == true }
            sites.append(siteItem(hosts: hosts, folder: link.folder, parkedIn: nil, setup: setup, facts: facts, php: php(for: hosts[0])))
        }

        for file in setup.siteFiles {
            guard let address = file.proxy, !sites.contains(where: { $0.hosts.contains(file.host) }) else {
                continue
            }

            sites.append(HerdMovePlan.SiteItem(hosts: [file.host], folder: "", kind: .proxy, herdPHP: nil, php: nil, phpChoices: [], address: address))
        }

        let inNexus = sites.filter { site in site.hosts.contains(where: facts.nexusHosts.contains) }.map { $0.hosts[0] }
        sites.removeAll { site in inNexus.contains(site.hosts[0]) }
        parked.removeAll { facts.nexusParked.contains($0.folder) }

        if !inNexus.isEmpty {
            notes.append("\(EnglishList.joined(inNexus)) \(inNexus.count == 1 ? "is" : "are") in Nexus already, so the move leaves \(inNexus.count == 1 ? "it" : "them") out.")
        }

        for site in sites {
            guard let herd = site.herdPHP, let line = site.php, herd != line else {
                continue
            }

            notes.append(VersionLine.isOlder(herd, than: line)
                ? "\(site.hosts[0]) uses PHP \(herd). Nexus has PHP \(phpLines.first ?? line) and newer, so the site gets PHP \(line)."
                : "\(site.hosts[0]) uses PHP \(herd). Nexus has no PHP \(herd) yet, so the site gets PHP \(line) until then.")
        }

        let found = databaseItems(sites: sites, facts: facts)
        let stopped = found.filter { $0.socket == nil && $0.port.map { facts.servers[$0] == nil } == true }
        let databases = found.filter { item in !stopped.contains { $0.id == item.id } }
        notes += stopped.map { "The server of the database \($0.name) on port \($0.port ?? 0) does not run, so Nexus cannot copy it. Start that server, then open this sheet again." }
        let redis = redisItems(sites: sites, facts: facts)
        let ini = iniItems(setup: setup, phpLines: phpLines)
        let envFiles = sites.compactMap { site -> HerdMovePlan.EnvItem? in
            guard site.projectType == .laravel, facts.projects[site.folder]?.env != nil else {
                return nil
            }

            return HerdMovePlan.EnvItem(host: site.hosts[0], file: URL(filePath: site.folder).appending(path: ".env").path(percentEncoded: false))
        }

        if setup.tld != "test" {
            notes.append("Herd uses the domain .\(setup.tld). Nexus uses .test, so each site gets a .test address.")
        }

        return HerdMovePlan(
            herdRuns: facts.herdRuns,
            tld: setup.tld,
            packages: packages(sites: sites, databases: databases, redis: redis, facts: facts),
            parked: parked,
            sites: sites,
            databases: databases,
            redis: redis,
            ini: ini,
            envFiles: envFiles,
            files: shellItems(facts: facts) + projectItems(sites: sites, facts: facts),
            notes: notes,
            inNexus: inNexus
        )
    }

    // The same line when Nexus has it. An older version gets the oldest line of Nexus, and a newer
    // version gets the newest line until Nexus has it (owner, 2026-11-24).
    static func phpLine(for version: String, offered: [String]) -> String? {
        let line = majorMinor(version)

        if offered.contains(line) {
            return line
        }

        if let first = offered.first, VersionLine.isOlder(line, than: first) {
            return first
        }

        return offered.last
    }

    // A database goes to the same line or the nearest newer line. A dump of a newer server does
    // not always load into an older one. So only newer lines are choices.
    static func databaseLine(for version: String?, offered: [String]) -> (line: String?, choices: [String]) {
        guard let version else {
            return (offered.last, offered)
        }

        let line = majorMinor(version)
        let newer = offered.filter { $0 == line || $0 == major(version) || VersionLine.isOlder(line, than: $0) }
        let exact = offered.first { $0 == line || $0 == major(version) }

        return (exact ?? newer.first ?? offered.last, newer.isEmpty ? offered : newer)
    }

    // The path of a folder without the / at the end, the key of the facts of its project.
    static func folderPath(_ folder: URL) -> String {
        let path = folder.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func major(_ version: String) -> String {
        String(version.split(separator: ".").first ?? "")
    }

    static func subfolders(of folder: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        return children
            .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func siteItem(hosts: [String], folder: URL, parkedIn: URL?, setup: HerdSetup, facts: HerdMoveFacts, php: (herd: String?, line: String?)) -> HerdMovePlan.SiteItem {
        let path = folderPath(folder)
        let ownLines = hosts.flatMap { setup.siteFile(of: $0)?.ownLines ?? [] }

        return HerdMovePlan.SiteItem(
            hosts: hosts,
            folder: path,
            kind: .php,
            herdPHP: php.herd,
            php: php.line,
            phpChoices: facts.offered["php"] ?? [],
            parkedIn: parkedIn.map(folderPath),
            projectType: facts.projects[path]?.type ?? .other,
            ownLines: ownLines
        )
    }

    struct Endpoint: Hashable {
        let kind: String
        let port: Int?
        let socket: String?
        let name: String
        let account: DatabaseAccount
    }

    static func databaseItems(sites: [HerdMovePlan.SiteItem], facts: HerdMoveFacts) -> [HerdMovePlan.DatabaseItem] {
        var endpoints: [Endpoint] = []
        var sitesOf: [Endpoint: [String]] = [:]

        for site in sites {
            guard let endpoint = databaseEndpoint(of: facts.projects[site.folder], servers: facts.servers) else {
                continue
            }

            if sitesOf[endpoint] == nil {
                endpoints.append(endpoint)
            }

            sitesOf[endpoint, default: []].append(site.hosts[0])
        }

        return endpoints.map { endpoint in
            let version = endpoint.port.flatMap { facts.servers[$0]?.version }
            let target = databaseLine(for: version, offered: facts.offered[endpoint.kind] ?? [])

            return HerdMovePlan.DatabaseItem(name: endpoint.name, kind: endpoint.kind, version: version, port: endpoint.port, socket: endpoint.socket, account: endpoint.account, line: target.line, lineChoices: target.choices, sites: sitesOf[endpoint] ?? [])
        }
    }

    static func databaseEndpoint(of project: HerdMoveFacts.Project?, servers: [Int: HerdMoveFacts.Server]) -> Endpoint? {
        if let env = project?.env, let connection = env["DB_CONNECTION"], var kind = databaseKinds[connection], let name = env["DB_DATABASE"], !name.isEmpty {
            let host = env["DB_HOST"] ?? "127.0.0.1"

            guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
                return nil
            }

            let standard = kind == "postgresql" ? 5432 : kind == "mongodb" ? 27017 : 3306
            let port = env["DB_PORT"].flatMap(Int.init) ?? standard

            if kind == "mysql", servers[port]?.kind == "mariadb" {
                kind = "mariadb"
            }

            return Endpoint(kind: kind, port: port, socket: env["DB_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }, name: name, account: DatabaseAccount(user: env["DB_USERNAME"] ?? "root", password: env["DB_PASSWORD"] ?? ""))
        }

        if let config = project?.wordPress, let name = config["DB_NAME"], let host = config["DB_HOST"] {
            let address = DatabaseAddress(dbHost: host)
            let port = address.localPort ?? (host.lowercased().hasPrefix("localhost") ? DatabaseAddress.standardPort : nil)

            guard let port else {
                return nil
            }

            let kind = servers[port]?.kind == "mariadb" ? "mariadb" : "mysql"
            return Endpoint(kind: kind, port: port, socket: nil, name: name, account: DatabaseAccount(user: config["DB_USER"] ?? "root", password: config["DB_PASSWORD"] ?? ""))
        }

        return nil
    }

    static func redisItems(sites: [HerdMovePlan.SiteItem], facts: HerdMoveFacts) -> [HerdMovePlan.RedisItem] {
        var ports: [Int] = []
        var passwords: [Int: String] = [:]
        var sitesOf: [Int: [String]] = [:]

        for site in sites {
            guard let env = facts.projects[site.folder]?.env, redisDrivers.contains(where: { env[$0] == "redis" }) else {
                continue
            }

            let host = env["REDIS_HOST"] ?? "127.0.0.1"
            let port = env["REDIS_PORT"].flatMap(Int.init) ?? 6379

            guard ["127.0.0.1", "localhost"].contains(host), let server = facts.servers[port], ["redis", "valkey"].contains(server.kind) else {
                continue
            }

            if !ports.contains(port) {
                ports.append(port)
            }

            if let password = env["REDIS_PASSWORD"], !password.isEmpty, password != "null" {
                passwords[port] = password
            }

            sitesOf[port, default: []].append(site.hosts[0])
        }

        let lines = facts.offered["redis"] ?? []

        return ports.map { port in
            let server = facts.servers[port]
            let valkey = server?.kind == "valkey"
            let line = valkey ? lines.last : databaseLine(for: server?.version, offered: lines).line

            return HerdMovePlan.RedisItem(port: port, password: passwords[port], valkey: valkey, version: server?.version, keys: facts.redisKeys[port], line: line ?? "8", sites: sitesOf[port] ?? [])
        }
    }

    static func iniItems(setup: HerdSetup, phpLines: [String]) -> [HerdMovePlan.IniItem] {
        var items: [HerdMovePlan.IniItem] = []

        for (herd, lines) in setup.phpIniLines.sorted(by: { VersionLine.isOlder($0.key, than: $1.key) }) {
            guard let line = phpLine(for: herd, offered: phpLines) else {
                continue
            }

            if let index = items.firstIndex(where: { $0.line == line }) {
                if herd == line {
                    items[index] = HerdMovePlan.IniItem(herdPHP: herd, line: line, lines: lines)
                }
                continue
            }

            items.append(HerdMovePlan.IniItem(herdPHP: herd, line: line, lines: lines))
        }

        return items
    }

    static func packages(sites: [HerdMovePlan.SiteItem], databases: [HerdMovePlan.DatabaseItem], redis: [HerdMovePlan.RedisItem], facts: HerdMoveFacts) -> [HerdMovePlan.Package] {
        var needed: [(name: String, line: String, reason: String)] = []

        func need(_ name: String, _ line: String?, for reason: String) {
            guard let line, !facts.installed.contains("\(name)-\(line)") else {
                return
            }

            if let index = needed.firstIndex(where: { $0.name == name && $0.line == line }) {
                needed[index].reason += ", \(reason)"
                return
            }

            needed.append((name, line, reason))
        }

        for site in sites where site.kind == .php {
            need("php", site.php, for: site.hosts[0])
        }

        for database in databases {
            need(database.kind, database.line, for: database.name)
        }

        for server in redis {
            need("redis", server.line, for: "the Redis keys")
        }

        return needed.map { HerdMovePlan.Package(name: $0.name, line: $0.line, reason: "for \($0.reason)", bytes: facts.packageBytes["\($0.name)-\($0.line)"]) }
    }

    // The lines that Herd wrote to a shell file: its comments, its exports and the line that loads
    // its shell script.
    static func shellItems(facts: HerdMoveFacts) -> [HerdMovePlan.FileItem] {
        facts.shellFiles.sorted { $0.key < $1.key }.compactMap { path, text in
            let lines = herdShellLines(in: text)
            return lines.isEmpty ? nil : HerdMovePlan.FileItem(path: path, kind: .shell, lines: lines)
        }
    }

    // The line that loads nvm is the same in the own setup of nvm. So it counts only right after
    // the NVM_DIR of Herd.
    static func herdShellLines(in text: String) -> [String] {
        var lines: [String] = []
        var afterHerdNVM = false

        for line in text.components(separatedBy: "\n") {
            if afterHerdNVM, line.hasPrefix("[ -s \"$NVM_DIR/nvm.sh\" ]") {
                lines.append(line)
            } else if isHerdShellLine(line) {
                lines.append(line)
            }

            afterHerdNVM = line.hasPrefix("export NVM_DIR=") && line.contains("/Application Support/Herd/")
        }

        return lines
    }

    static func isHerdShellLine(_ line: String) -> Bool {
        line.hasPrefix("# Herd injected")
            || line.contains("/Application Support/Herd/")
            || line.contains("/Applications/Herd.app/")
    }

    static func projectItems(sites: [HerdMovePlan.SiteItem], facts: HerdMoveFacts) -> [HerdMovePlan.FileItem] {
        sites.flatMap { site in
            (facts.projects[site.folder]?.projectFiles ?? [:]).sorted { $0.key < $1.key }.map { path, lines in
                HerdMovePlan.FileItem(path: path, kind: .project, lines: lines)
            }
        }
    }
}
