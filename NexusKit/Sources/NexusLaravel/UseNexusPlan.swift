import Foundation
import NexusCore

// What "Use Nexus…" changes in the .env of the main checkout of a Laravel site (owner,
// 2026-11-14). Each part holds only the keys that do not use Nexus now. A part that needs a change
// of a key that the configuration fixes is not in the plan, because Nexus cannot make it work.
public struct UseNexusPlan: Sendable, Equatable {
    // A database instance of Nexus. name is the name in the sheet, for example MySQL 8.4. socket is
    // the socket file of MySQL and MariaDB, and run/.s.PGSQL.<port> for PostgreSQL.
    public struct Server: Sendable, Equatable {
        public let id: String
        public let name: String
        public let kind: DatabaseKind
        public let version: String
        public let port: Int
        public let socket: String
        public let account: DatabaseAccount

        public init(id: String, name: String, kind: DatabaseKind, version: String, port: Int, socket: String, account: DatabaseAccount) {
            self.id = id
            self.name = name
            self.kind = kind
            self.version = version
            self.port = port
            self.socket = socket
            self.account = account
        }
    }

    public struct RedisServer: Sendable, Equatable {
        public let id: String
        public let port: Int
        public let running: Bool

        public init(id: String, port: Int, running: Bool) {
            self.id = id
            self.port = port
            self.running = running
        }
    }

    // envText is the .env of the main checkout. hosts holds the host of the site, then its
    // aliases. url is the URL of the site in Nexus.
    public struct Input: Sendable {
        public let envText: String
        public let hosts: [String]
        public let url: String
        public let httpsPort: Int
        public let databaseServers: [Server]
        public let redisServers: [RedisServer]

        public init(envText: String, hosts: [String], url: String, httpsPort: Int, databaseServers: [Server], redisServers: [RedisServer]) {
            self.envText = envText
            self.hosts = hosts
            self.url = url
            self.httpsPort = httpsPort
            self.databaseServers = databaseServers
            self.redisServers = redisServers
        }
    }

    // The old server, as the copy and the check reach it. host is for the client. For a socket of
    // PostgreSQL, host is the folder of the socket. socket is the socket file.
    public struct Source: Sendable, Equatable {
        public let kind: DatabaseKind
        public let host: String
        public let port: Int
        public let socket: String?
        public let account: DatabaseAccount

        public init(kind: DatabaseKind, host: String, port: Int, socket: String?, account: DatabaseAccount) {
            self.kind = kind
            self.host = host
            self.port = port
            self.socket = socket
            self.account = account
        }
    }

    public struct Choice: Sendable, Equatable {
        public let server: Server
        public let changes: [EnvValueChange]

        public init(server: Server, changes: [EnvValueChange]) {
            self.server = server
            self.changes = changes
        }
    }

    // name is nil when the connection names no database, or a name that Nexus cannot use. Nexus
    // then does not copy or make a database.
    public struct Database: Sendable, Equatable {
        public let connection: String
        public let name: String?
        public let source: Source
        public let choices: [Choice]

        public init(connection: String, name: String?, source: Source, choices: [Choice]) {
            self.connection = connection
            self.name = name
            self.source = source
            self.choices = choices
        }
    }

    // appURLValue is the value that Laravel reads now.
    public var appURL: EnvValueChange?
    public var appURLValue: String?
    public var database: Database?
    public var redis: [EnvValueChange] = []
    // The Redis server of Nexus that the Redis changes point to. "Use Nexus" starts it.
    public var redisServer: String?

    public var isEmpty: Bool {
        appURL == nil && database == nil && redis.isEmpty
    }

    // The same order as UseNexusInfo.changes(choosing:). The sheet sends those changes.
    public func changes(choosing instance: String?) -> [EnvValueChange] {
        let choice = database?.choices.first { $0.server.id == instance }

        return (appURL.map { [$0] } ?? []) + (choice?.changes ?? []) + redis
    }

    private typealias NeededChange = (setting: ConfigSetting?, value: String?)

    public init(configuration: LaravelConfiguration, input: Input) {
        let values = EnvFile.values(in: input.envText)

        addAppURL(configuration.settings, input: input, values: values)
        addDatabase(configuration.settings, input: input, values: values)
        addRedis(configuration, input: input, values: values)
    }

    // Without the version of the old server, the rule of a new database applies (owner,
    // 2026-11-06): the same kind first, and for MySQL first mysql-8.4. With a version, the server
    // of the same kind with the closest version comes first, because the data then needs the
    // fewest changes. The other kind of the protocol follows, the newest first.
    public static func ordered(_ choices: [Choice], kind: DatabaseKind, oldVersion: String?) -> [Choice] {
        let newestFirst = choices.sorted { isNewer($0.server, than: $1.server) }

        guard let oldVersion, let old = versionNumber(oldVersion) else {
            let sameKind = newestFirst.filter { $0.server.kind == kind }
            let preferred = kind == .mysql ? sameKind.filter { $0.server.id == "mysql-8.4" } : []

            return preferred + sameKind.filter { !preferred.contains($0) } + newestFirst.filter { $0.server.kind != kind }
        }

        let oldKind = oldKind(kind, version: oldVersion)
        let closestFirst = newestFirst.filter { $0.server.kind == oldKind }.sorted { first, second in
            let firstDistance = abs((versionNumber(first.server.version) ?? 0) - old)
            let secondDistance = abs((versionNumber(second.server.version) ?? 0) - old)

            guard firstDistance != secondDistance else {
                return isNewer(first.server, than: second.server)
            }

            return firstDistance < secondDistance
        }

        return closestFirst + newestFirst.filter { $0.server.kind != oldKind }
    }

    // The driver mysql can reach a MariaDB, and the driver mariadb a MySQL. The version of the
    // server tells them apart.
    public static func oldKind(_ kind: DatabaseKind, version: String?) -> DatabaseKind {
        guard kind.usesMySQLProtocol, let version else {
            return kind
        }

        return version.contains("MariaDB") ? .mariadb : .mysql
    }

    private mutating func addAppURL(_ settings: [String: ConfigSetting], input: Input, values: [String: String]) {
        guard let setting = settings["app.url"] else {
            return
        }

        let value = Self.text(setting.value)

        guard !Self.usesNexus(url: value, input: input), let change = Self.change(setting, to: input.url, values: values) else {
            return
        }

        appURL = change
        appURLValue = value
    }

    private static func usesNexus(url: String, input: Input) -> Bool {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", let host = components.host?.lowercased() else {
            return false
        }

        let hosts = Set(input.hosts.map { $0.lowercased() })

        return hosts.contains(host) && (components.port ?? 443) == input.httpsPort && ["", "/"].contains(components.path)
    }

    private mutating func addDatabase(_ settings: [String: ConfigSetting], input: Input, values: [String: String]) {
        let connection = Self.text(settings["database.default"]?.value)
        let path = "database.connections.\(connection)"
        let driver = Self.text(settings["\(path).driver"]?.value)

        guard !connection.isEmpty, let kind = Self.kind(ofDriver: driver), Self.text(settings["\(path).url"]?.value).isEmpty else {
            return
        }

        let address = ConnectionAddress(path: path, driver: driver, settings: settings)
        let servers = input.databaseServers.filter { $0.kind.usesMySQLProtocol == kind.usesMySQLProtocol }

        guard address.isOnThisMac, !servers.isEmpty, !servers.contains(where: { address.reaches(port: $0.port, socket: $0.socket) }) else {
            return
        }

        let choices = servers.compactMap { Self.choice(of: $0, path: path, settings: settings, values: values) }

        guard !choices.isEmpty else {
            return
        }

        let name = Self.text(WorkspaceEnvPlan.value("database", at: path, settings: settings))

        database = Database(
            connection: connection,
            name: try? DatabaseName.validated(name),
            source: Self.source(address, kind: kind, path: path, settings: settings),
            choices: Self.ordered(choices, kind: kind, oldVersion: nil)
        )
    }

    // A server that needs a change of a key that the configuration fixes is no choice.
    private static func choice(of server: Server, path: String, settings: [String: ConfigSetting], values: [String: String]) -> Choice? {
        func setting(_ name: String) -> ConfigSetting? {
            WorkspaceEnvPlan.setting(name, at: path, settings: settings)
        }

        let host = setting("host").map { text($0.value) } ?? WorkspaceEnvPlan.serverHost
        let port = WorkspaceEnvPlan.port(path, settings: settings) ?? server.kind.standardPort
        var needed: [NeededChange] = []

        if host != WorkspaceEnvPlan.serverHost {
            needed.append((setting("host"), WorkspaceEnvPlan.serverHost))
        }

        if port != server.port {
            needed.append((setting("port"), String(server.port)))
        }

        // A socket line goes out. A socket from a default of config/database.php gets an empty
        // line, because the key then has no line to remove.
        if let socket = setting("unix_socket"), !text(socket.value).isEmpty {
            let hasLine = socket.keys.first.map { values[$0] != nil } ?? false
            needed.append((socket, hasLine ? nil : ""))
        }

        if text(setting("username")?.value) != server.account.user {
            needed.append((setting("username"), server.account.user))
        }

        if text(setting("password")?.value) != server.account.password {
            needed.append((setting("password"), server.account.password))
        }

        return changes(needed, values: values).map { Choice(server: server, changes: $0) }
    }

    private static func source(_ address: ConnectionAddress, kind: DatabaseKind, path: String, settings: [String: ConfigSetting]) -> Source {
        let port = WorkspaceEnvPlan.port(path, settings: settings) ?? kind.standardPort
        let account = DatabaseAccount(
            user: text(WorkspaceEnvPlan.value("username", at: path, settings: settings)),
            password: text(WorkspaceEnvPlan.value("password", at: path, settings: settings))
        )

        switch address {
        case .socket(let file):
            let host = kind.usesMySQLProtocol ? "localhost" : (file as NSString).deletingLastPathComponent
            return Source(kind: kind, host: host, port: port, socket: file, account: account)
        case .localhostSocket(let tcpPort):
            return Source(kind: kind, host: WorkspaceEnvPlan.serverHost, port: tcpPort, socket: nil, account: account)
        case .tcp(let host, let tcpPort):
            let clientHost = host.lowercased() == "localhost" ? WorkspaceEnvPlan.serverHost : host
            return Source(kind: kind, host: clientHost, port: tcpPort, socket: nil, account: account)
        }
    }

    // The newest running server, else the newest one. Each key changes one time, also when more
    // connections read it.
    private mutating func addRedis(_ configuration: LaravelConfiguration, input: Input, values: [String: String]) {
        let newestFirst = input.redisServers.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }

        guard WorkspaceEnvPlan.usesRedis(configuration), let server = newestFirst.first(where: \.running) ?? newestFirst.first else {
            return
        }

        let settings = configuration.settings
        let nexusPorts = Set(input.redisServers.map(\.port))
        var changes: [EnvValueChange] = []

        for name in configuration.redisConnections {
            let path = "database.redis.\(name)"
            let host = WorkspaceEnvPlan.value("host", at: path, settings: settings)?.description ?? WorkspaceEnvPlan.serverHost
            let port = WorkspaceEnvPlan.port(path, settings: settings) ?? ConnectionURL.Kind.redis.standardPort
            let isSocket = host.hasPrefix("/")

            guard Self.text(settings["\(path).url"]?.value).isEmpty, isSocket || WorkspaceEnvPlan.localHosts.contains(host.lowercased()) else {
                continue
            }

            if !isSocket, nexusPorts.contains(port) {
                continue
            }

            var needed: [NeededChange] = []

            if host != WorkspaceEnvPlan.serverHost {
                needed.append((WorkspaceEnvPlan.setting("host", at: path, settings: settings), WorkspaceEnvPlan.serverHost))
            }

            if port != server.port {
                needed.append((WorkspaceEnvPlan.setting("port", at: path, settings: settings), String(server.port)))
            }

            let password = WorkspaceEnvPlan.setting("password", at: path, settings: settings)

            if !Self.text(password?.value).isEmpty {
                needed.append((password, ""))
            }

            guard let connectionChanges = Self.changes(needed, values: values) else {
                continue
            }

            for change in connectionChanges where !changes.contains(where: { $0.key == change.key }) {
                changes.append(change)
            }
        }

        redis = changes
        redisServer = changes.isEmpty ? nil : server.id
    }

    // nil when Nexus cannot change one of the settings.
    private static func changes(_ needed: [NeededChange], values: [String: String]) -> [EnvValueChange]? {
        var changes: [EnvValueChange] = []

        for item in needed {
            guard let change = change(item.setting, to: item.value, values: values) else {
                return nil
            }

            changes.append(change)
        }

        return changes
    }

    // nil when Nexus cannot change the setting: the configuration fixes it, or the key is only a
    // part of the value.
    private static func change(_ setting: ConfigSetting?, to newValue: String?, values: [String: String]) -> EnvValueChange? {
        guard let setting, setting.exact, let key = setting.keys.first else {
            return nil
        }

        return EnvValueChange(key: key, oldValue: values[key], newValue: newValue)
    }

    // A null value counts as an empty text.
    private static func text(_ value: ConfigValue?) -> String {
        guard let value, value != .null else {
            return ""
        }

        return value.description
    }

    private static func kind(ofDriver driver: String) -> DatabaseKind? {
        switch driver {
        case "mysql": .mysql
        case "mariadb": .mariadb
        case "pgsql": .postgresql
        default: nil
        }
    }

    private static func isNewer(_ first: Server, than second: Server) -> Bool {
        let order = first.version.compare(second.version, options: .numeric)

        guard order != .orderedSame else {
            return first.id.compare(second.id, options: .numeric) == .orderedDescending
        }

        return order == .orderedDescending
    }

    // major * 1000 + minor, from the start of a version text such as 8.0.35 or 10.11.6-MariaDB.
    private static func versionNumber(_ version: String) -> Int? {
        guard let match = version.firstMatch(of: #/(\d+)(?:\.(\d+))?/#), let major = Int(match.1) else {
            return nil
        }

        return major * 1000 + (match.2.flatMap { Int($0) } ?? 0)
    }
}
