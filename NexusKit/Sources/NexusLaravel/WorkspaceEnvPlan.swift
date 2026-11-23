import Foundation
import NexusCore

public struct WorkspaceDatabase: Sendable, Equatable {
    public let name: String
    public let port: Int
    public let isDefault: Bool

    public init(name: String, port: Int, isDefault: Bool) {
        self.name = name
        self.port = port
        self.isDefault = isDefault
    }
}

public struct WorkspaceFile: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// What the plan of a workspace needs to know besides the configuration of the application.
public struct WorkspaceEnvRequest: Sendable {
    public let workspace: String
    public let mainFolder: String
    public let workspaceFolder: String
    public let mysqlPorts: Set<Int>
    public let postgresqlPorts: Set<Int>
    public let mongodbPorts: Set<Int>
    public let redisPorts: Set<Int>
    // The socket file of each database instance, by its port. A main checkout can reach an instance
    // through its socket.
    public let instanceSockets: [Int: String]
    // The check of a worktree sends that worktree as mainFolder, and this field then names the main
    // checkout. A file in the main checkout is not the file of the workspace.
    public let realMainFolder: String?
    // The SMTP port of the receiver of nexusd. A workspace always sends its mail there (Phase 3, 3c).
    public let smtpPort: Int?
    // The workspace keys of the site with their values (D45). With such a key the user isolates a
    // server that Nexus does not manage.
    public let ownKeys: [String: String]

    public init(workspace: String, mainFolder: String, workspaceFolder: String, mysqlPorts: Set<Int>, postgresqlPorts: Set<Int>, mongodbPorts: Set<Int> = [], redisPorts: Set<Int>, instanceSockets: [Int: String] = [:], realMainFolder: String? = nil, smtpPort: Int? = nil, ownKeys: [String: String] = [:]) {
        self.workspace = workspace
        self.mainFolder = mainFolder
        self.workspaceFolder = workspaceFolder
        self.mysqlPorts = mysqlPorts
        self.postgresqlPorts = postgresqlPorts
        self.mongodbPorts = mongodbPorts
        self.redisPorts = redisPorts
        self.instanceSockets = instanceSockets
        self.realMainFolder = realMainFolder
        self.smtpPort = smtpPort
        self.ownKeys = ownKeys
    }

    // A workspace key with the value of the main site isolates nothing. The worktree already has the
    // value of its key, so the check of a worktree does not compare.
    func isOwn(_ key: String, mainValue: String?) -> Bool {
        guard let value = ownKeys[key] else {
            return false
        }

        return realMainFolder != nil || value != mainValue
    }
}

// The env keys of a workspace that lead a connection to the server of the workspace, or that feed a
// Redis index (D66, D47). problems holds what Nexus cannot isolate (D48). keys holds a value for each
// key. A port key gets its port from nexusd, and a Redis key its index, because these depend on the
// other workspaces. serverPortKeys holds these port keys for each port of an instance. connections
// holds the port of each connection on an instance, for the check of what the application reaches.
// redisPorts holds the instances of the Redis keys. mainRedisIndexes holds the indexes of the main
// site, which a workspace must not get. database is the name for {database}. reverbPortKeys holds the
// keys that get the port of the Reverb server of the workspace (D52).
public struct WorkspaceEnvPlan: Sendable, Equatable {
    public var keys: [String: String] = [:]
    public var serverPortKeys: [Int: [String]] = [:]
    public var connections: [String: Int] = [:]
    public var redisKeys: [String] = []
    public var redisPorts: Set<Int> = []
    public var mainRedisIndexes: Set<Int> = []
    public var database: String?
    public var problems: [String] = []
    // The databases on the servers of the workspace. An isDefault database must exist. Another
    // connection can name a database that the main site does not have either.
    public var databases: [WorkspaceDatabase] = []
    public var sqliteFiles: [WorkspaceFile] = []
    public var reverbPortKeys: [String] = []
    // A Node.js app can name its server in a URL, for example DATABASE_URL (D67). Each of these keys
    // gets the URL of its file with the host and the port of the server of the workspace. urlPorts
    // holds the ports of the instances in these URLs. A Redis key with a URL is in redisKeys too,
    // and it gets the URL with the index of the workspace.
    public var serverURLKeys: Set<String> = []
    // The URL of a key in serverURLKeys as the configuration of a Laravel application has it. That
    // URL can be the default in config/database.php, and the .env then does not have the key.
    public var serverURLs: [String: String] = [:]
    public var urlPorts: Set<Int> = []
    public var redisURLKeys: Set<String> = []
    // What a workspace shares with the main site without a Not isolated state. A Node.js app gets
    // these for its servers. A Laravel app gets one for mail that cannot reach Nexus.
    public var warnings: [String] = []
    // The keys that send the mail of the workspace to the receiver of nexusd. A value can hold
    // {host}, the host of the workspace, which becomes the tag of each mail.
    public var mailKeys: [String: String] = [:]

    public var isolatingKeys: Set<String> {
        Set(keys.keys).union(redisKeys).union(serverPortKeys.values.joined()).union(serverURLKeys).union(mailKeys.keys)
    }

    public static let hostPlaceholder = "{host}"

    // A mail of a workspace that does not reach Nexus can reach a real customer. The workspace
    // still runs with its queue worker, because the app needs the queue (owner, 2026-11-06). So
    // it gets a warning and is not Not isolated.
    mutating func addMail(_ configuration: LaravelConfiguration, request: WorkspaceEnvRequest) {
        guard let port = request.smtpPort else {
            return
        }

        let mail = LaravelMail.nexusKeys(configuration, user: Self.hostPlaceholder, nexusPort: port)
        mailKeys = mail.keys

        if !mail.problems.isEmpty {
            warnings.append((mail.problems + [Self.realMailWarning]).joined(separator: " "))
        }
    }

    static let realMailWarning = "A mail of this workspace can then reach a real person."

    // The ports of the instances that the workspace gets a server for.
    public var serverPorts: [Int] {
        Set(serverPortKeys.keys).union(urlPorts).sorted()
    }

    public static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    init() {}

    // PHP and the MySQL client use a socket for localhost, and a socket ignores the port. The server
    // of a workspace listens only on this address.
    public static let serverHost = "127.0.0.1"

    public init(configuration: LaravelConfiguration, request: WorkspaceEnvRequest) {
        let defaultConnection = configuration.settings["database.default"]?.value.description

        // Connections can share one key. The default connection goes first, because the application
        // needs the value of that connection.
        let connections = configuration.databaseConnections
        let ordered = connections.filter { $0 == defaultConnection } + connections.filter { $0 != defaultConnection }

        for name in ordered {
            add(connection: name, isDefault: name == defaultConnection, configuration: configuration, request: request)
        }

        // Code can use a Redis connection without the cache, the sessions or the queue.
        mainRedisIndexes = Set(configuration.redisConnections.compactMap { name in
            configuration.settings["database.redis.\(name).database"].flatMap { Int($0.value.description) }
        })

        if Self.usesRedis(configuration) {
            for name in configuration.redisConnections {
                add(redis: name, configuration: configuration, request: request)
            }
        }

        redisKeys.sort()
        reverbPortKeys = Self.reverbPortKeys(configuration)
        addMail(configuration, request: request)
    }

    // The server listens on one key, and the application and the browser connect with another key.
    // The probe does not see VITE_REVERB_PORT, because only the JavaScript of the site reads it. A
    // fixed number on that line would send the browser to the server of the main site.
    private static func reverbPortKeys(_ configuration: LaravelConfiguration) -> [String] {
        guard BackgroundPreset.usesReverb(configuration) else {
            return []
        }

        let settings = configuration.settings
        let connection = settings["broadcasting.default"]?.value.description ?? ""
        let server = settings["reverb.default"]?.value.description ?? "reverb"
        let apps = settings.keys.filter { $0.wholeMatch(of: #/reverb\.apps\.apps\.\d+\.options\.port/#) != nil }
        let paths = ["broadcasting.connections.\(connection).options.port", "reverb.servers.\(server).port"] + apps
        let keys = paths.compactMap { settings[$0] }.filter(\.exact).flatMap(\.keys)

        return Set(keys + ["VITE_REVERB_PORT"]).sorted()
    }

    private mutating func add(connection name: String, isDefault: Bool, configuration: LaravelConfiguration, request: WorkspaceEnvRequest) {
        let settings = configuration.settings
        let path = "database.connections.\(name)"

        guard let driver = settings["\(path).driver"]?.value.description else {
            return
        }

        if driver == "mongodb" {
            add(mongoDB: name, at: path, isDefault: isDefault, settings: settings, request: request)
            return
        }

        guard let setting = settings["\(path).database"] else {
            return
        }

        if driver == "sqlite" {
            add(sqliteFile: setting, connection: name, isDefault: isDefault, request: request)
            return
        }

        let nexusPorts = ports(of: driver, request)

        if nexusPorts != nil, setting.value.isEmpty {
            return
        }

        let address = ConnectionAddress(path: path, driver: driver, settings: settings)

        guard let nexusPorts, let port = Self.nexusPort(address, path: path, ports: nexusPorts, sockets: request.instanceSockets, settings: settings) else {
            if isDefault, case .localhostSocket = address {
                problems.append("The connection \(name) has the host localhost. PHP then uses the standard socket of MySQL and no Nexus database instance. Use 127.0.0.1, for example with \"Use Nexus…\" on the Site screen.")
            } else if isDefault {
                problems.append("The connection \(name) does not use a Nexus database instance.")
            }

            return
        }

        if settings["\(path).url"]?.value.isEmpty == false {
            problems.append("The connection \(name) has its server in a URL.")
            return
        }

        guard let portSetting = Self.setting("port", at: path, settings: settings), let portKey = portSetting.keys.first, portSetting.exact else {
            problems.append("The connection \(name) has a fixed port in config/database.php.")
            return
        }

        // Connections can share one key, also with other defaults when the .env does not have that
        // key. The key can hold one port. The default connection goes first, and it keeps that port.
        guard !serverPortKeys.contains(where: { $0.key != port && $0.value.contains(portKey) }) else {
            return
        }

        addHost(of: name, at: path, settings: settings)
        addSocket(of: name, at: path, settings: settings)

        if serverPortKeys[port]?.contains(portKey) != true {
            serverPortKeys[port, default: []].append(portKey)
        }

        connections[name] = port

        let database = setting.value.description

        if isDefault {
            self.database = database
        }

        if !databases.contains(where: { $0.name == database && $0.port == port }) {
            databases.append(WorkspaceDatabase(name: database, port: port, isDefault: isDefault))
        }
    }

    // config/database.php of a new Laravel application has no MongoDB connection. So a connection
    // that is there is in use, and a server that Nexus cannot change gives Not isolated (decision 9
    // of group 6). The URL in dsn gets the port of the workspace (D67). A workspace key of the site
    // for this connection gives each workspace its own server or database.
    private mutating func add(mongoDB name: String, at path: String, isDefault: Bool, settings: [String: ConfigSetting], request: WorkspaceEnvRequest) {
        let parts = ["dsn", "host", "port", "database"].compactMap { Self.setting($0, at: path, settings: settings) }
        let isIsolatedByUser = parts.contains { part in
            part.keys.contains { request.isOwn($0, mainValue: part.value.description) }
        }

        guard !isIsolatedByUser, let connection = LaravelMongoDBConnection(path: path, settings: settings) else {
            return
        }

        guard let port = connection.port else {
            let dsn = Self.value("dsn", at: path, settings: settings)?.description ?? ""
            let namesCluster = MongoDBURL.namesServers(dsn) || dsn.lowercased().hasPrefix("mongodb+srv://")

            problems.append(namesCluster
                ? "The connection \(name) names more than one MongoDB server, or its servers come from DNS (mongodb+srv). So Nexus cannot give this workspace its own server."
                : "Nexus cannot read the MongoDB URL of the connection \(name). So Nexus cannot give this workspace its own server.")
            return
        }

        guard ConnectionURL.isLocal(connection.host), request.mongodbPorts.contains(port) else {
            problems.append("The connection \(name) uses a MongoDB server that is no Nexus instance. So this workspace would share it with the main site.")
            return
        }

        if let dsn = Self.setting("dsn", at: path, settings: settings), !dsn.value.isEmpty {
            guard let key = dsn.keys.first, dsn.exact else {
                problems.append("The connection \(name) has a fixed MongoDB URL in config/database.php.")
                return
            }

            serverURLKeys.insert(key)
            serverURLs[key] = dsn.value.description
            urlPorts.insert(port)
        } else {
            guard addMongoDBPortKey(of: name, at: path, port: port, settings: settings) else {
                return
            }
        }

        connections[name] = port

        guard !connection.database.isEmpty else {
            return
        }

        if isDefault {
            database = connection.database
        }

        if !databases.contains(where: { $0.name == connection.database && $0.port == port }) {
            databases.append(WorkspaceDatabase(name: connection.database, port: port, isDefault: isDefault))
        }
    }

    // A host with the port in one text, as in 127.0.0.1:27017, or a list of hosts gets no port of its
    // own (owner, 2026-11-23).
    private mutating func addMongoDBPortKey(of name: String, at path: String, port: Int, settings: [String: ConfigSetting]) -> Bool {
        let host = LaravelMongoDBConnection.hostSetting(path: path, settings: settings)?.value.description ?? ""
        let hasPortInHost = host.contains(":") && !Self.localHosts.contains(host)
        let usePortKey = "Put the server in MONGODB_URI, so Nexus can give this workspace its own port."

        guard settings["\(path).host.1"] == nil else {
            problems.append("The connection \(name) names more than one MongoDB server. So Nexus cannot give this workspace its own server.")
            return false
        }

        guard !hasPortInHost else {
            problems.append("The connection \(name) has the port in its host. \(usePortKey)")
            return false
        }

        guard let portSetting = Self.setting("port", at: path, settings: settings), let portKey = portSetting.keys.first, portSetting.exact else {
            problems.append("The connection \(name) has no port key that Nexus can change. \(usePortKey)")
            return false
        }

        // Connections can share one key. The default connection goes first, and it keeps that port.
        guard !serverPortKeys.contains(where: { $0.key != port && $0.value.contains(portKey) }) else {
            return false
        }

        addHost(of: name, at: path, settings: settings)

        if serverPortKeys[port]?.contains(portKey) != true {
            serverPortKeys[port, default: []].append(portKey)
        }

        return true
    }

    private mutating func addHost(of name: String, at path: String, settings: [String: ConfigSetting]) {
        guard let host = Self.setting("host", at: path, settings: settings), host.value.description != Self.serverHost else {
            return
        }

        // Only a host that keeps the port reaches an instance (nexusPort). So a fixed host is no
        // problem: the port of the workspace isolates it.
        guard let key = host.keys.first, host.exact else {
            return
        }

        keys[key] = Self.serverHost
    }

    private mutating func addSocket(of name: String, at path: String, settings: [String: ConfigSetting]) {
        guard let socket = Self.setting("unix_socket", at: path, settings: settings), !socket.value.isEmpty else {
            return
        }

        guard let key = socket.keys.first, socket.exact else {
            problems.append("The connection \(name) has a fixed socket in config/database.php, and a socket ignores the port.")
            return
        }

        keys[key] = ""
    }

    // A file in the main checkout gets the same path in the worktree, because the worktree gets a
    // clone of that file (D46). A file outside the main checkout stays shared.
    private mutating func add(sqliteFile setting: ConfigSetting, connection name: String, isDefault: Bool, request: WorkspaceEnvRequest) {
        let path = setting.value.description

        guard path.hasPrefix("/") else {
            return
        }

        let main = RealPath.trimmed(request.mainFolder)

        guard RealPath.contains(main, path) else {
            if request.realMainFolder.map({ RealPath.contains($0, path) }) == true {
                problems.append("The connection \(name) uses a SQLite file of the main checkout.")
            } else if isDefault {
                problems.append("The connection \(name) uses a SQLite file outside the project.")
            }

            return
        }

        // A fixed path comes from database_path(), and that path follows the worktree. A path that
        // the application builds from a key stays in the main checkout.
        guard setting.isFixed || setting.exact else {
            problems.append("The connection \(name) builds its SQLite path from an env key, so Nexus cannot change it.")
            return
        }

        let file = RealPath.trimmed(request.workspaceFolder) + path.dropFirst(main.count)

        if let key = setting.keys.first {
            keys[key] = keys[key] ?? file
        }

        if isDefault {
            database = file
        }

        // Connections can share one key. When another connection gave that key its value, the
        // application does not use this file.
        if setting.keys.first.map({ keys[$0] == file }) ?? true, !sqliteFiles.contains(where: { $0.to == file }) {
            sqliteFiles.append(WorkspaceFile(from: path, to: file))
        }
    }

    private mutating func add(redis name: String, configuration: LaravelConfiguration, request: WorkspaceEnvRequest) {
        let settings = configuration.settings
        let path = "database.redis.\(name)"

        guard Self.isLocal(path, settings: settings), let port = Self.port(path, settings: settings), request.redisPorts.contains(port) else {
            problems.append("The Redis connection \(name) does not use a Nexus Redis instance.")
            return
        }

        if settings["\(path).url"]?.value.isEmpty == false {
            problems.append("The Redis connection \(name) has its index in a URL.")
            return
        }

        // A connection without a database setting uses index 0, the same as the main site.
        guard let setting = settings["\(path).database"], let key = setting.keys.first, setting.exact else {
            problems.append("The Redis connection \(name) has a fixed index in config/database.php.")
            return
        }

        redisPorts.insert(port)

        if !redisKeys.contains(key) {
            redisKeys.append(key)
        }
    }

    private func ports(of driver: String, _ request: WorkspaceEnvRequest) -> Set<Int>? {
        switch driver {
        case "mysql", "mariadb":
            request.mysqlPorts
        case "pgsql":
            request.postgresqlPorts
        default:
            nil
        }
    }

    // The port of the Nexus instance that PHP reaches with this connection, the same rule as the
    // Site screen. MySQL reads localhost as the standard socket of PHP, so that host reaches no
    // instance. Else a workspace would clone data that the main checkout does not use.
    // A connection without a port gets no standard port here. It reaches an instance only through
    // a socket.
    private static func nexusPort(_ address: ConnectionAddress, path: String, ports: Set<Int>, sockets: [Int: String], settings: [String: ConfigSetting]) -> Int? {
        if case .tcp = address, port(path, settings: settings) == nil {
            return nil
        }

        return ports.first { address.reaches(port: $0, socket: sockets[$0]) }
    }

    static func isLocal(_ path: String, settings: [String: ConfigSetting]) -> Bool {
        value("host", at: path, settings: settings).map { localHosts.contains($0.description.lowercased()) } ?? true
    }

    static func port(_ path: String, settings: [String: ConfigSetting]) -> Int? {
        value("port", at: path, settings: settings).flatMap { Int($0.description) }
    }

    // For a write, Laravel puts the write settings over the settings of the connection. A write
    // host can be a list, and the configuration then has it as write.host.0.
    static func setting(_ name: String, at path: String, settings: [String: ConfigSetting]) -> ConfigSetting? {
        ["\(path).write.\(name)", "\(path).write.\(name).0", "\(path).\(name)"].compactMap { settings[$0] }.first { $0.value != .null }
    }

    static func value(_ name: String, at path: String, settings: [String: ConfigSetting]) -> ConfigValue? {
        setting(name, at: path, settings: settings)?.value
    }

    static func usesRedis(_ configuration: LaravelConfiguration) -> Bool {
        let settings = configuration.settings
        let cache = settings["cache.default"]?.value.description ?? ""
        let queue = settings["queue.default"]?.value.description ?? ""
        let drivers = [settings["session.driver"], settings["cache.stores.\(cache).driver"], settings["queue.connections.\(queue).driver"]]

        return drivers.contains { $0?.value.description == "redis" }
    }
}

private extension ConfigValue {
    var isEmpty: Bool {
        self == .null || self == .text("")
    }
}
