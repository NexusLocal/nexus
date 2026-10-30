import Foundation
import NexusCore

public struct WorkspaceDatabase: Sendable, Equatable {
    public let name: String
    public let copy: String
    public let port: Int
    public let isDefault: Bool

    public init(name: String, copy: String, port: Int, isDefault: Bool) {
        self.name = name
        self.copy = copy
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
    public let redisPorts: Set<Int>

    public init(workspace: String, mainFolder: String, workspaceFolder: String, mysqlPorts: Set<Int>, postgresqlPorts: Set<Int>, redisPorts: Set<Int>) {
        self.workspace = workspace
        self.mainFolder = mainFolder
        self.workspaceFolder = workspaceFolder
        self.mysqlPorts = mysqlPorts
        self.postgresqlPorts = postgresqlPorts
        self.redisPorts = redisPorts
    }
}

// The env keys of a workspace that feed a database name or a Redis index (D46, D47). problems holds
// what Nexus cannot isolate (D48). keys holds a value for each key. A Redis key gets its index from
// nexusd, because that depends on the other workspaces. redisPorts holds the instances of these
// keys. mainRedisIndexes holds the indexes of the main site, which a workspace must not get.
// database is the name for {database}.
public struct WorkspaceEnvPlan: Sendable, Equatable {
    public var keys: [String: String] = [:]
    public var redisKeys: [String] = []
    public var redisPorts: Set<Int> = []
    public var mainRedisIndexes: Set<Int> = []
    public var database: String?
    public var problems: [String] = []
    // What the setup copies. An isDefault database must exist. Another connection can name a
    // database that the main site does not have either.
    public var databases: [WorkspaceDatabase] = []
    public var sqliteFiles: [WorkspaceFile] = []

    private static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

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
    }

    private mutating func add(connection name: String, isDefault: Bool, configuration: LaravelConfiguration, request: WorkspaceEnvRequest) {
        let settings = configuration.settings
        let path = "database.connections.\(name)"

        guard let driver = settings["\(path).driver"]?.value.description, let setting = settings["\(path).database"] else {
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

        guard let nexusPorts, Self.isOnNexus(path, ports: nexusPorts, settings: settings) else {
            if isDefault {
                problems.append("The connection \(name) does not use a Nexus database instance.")
            }

            return
        }

        if settings["\(path).url"]?.value.isEmpty == false {
            problems.append("The connection \(name) has its database name in a URL.")
            return
        }

        guard let key = setting.keys.first, setting.exact else {
            problems.append("The connection \(name) has a fixed database name in config/database.php.")
            return
        }

        let database = Workspace.databaseName(setting.value.description, workspace: request.workspace)
        keys[key] = keys[key] ?? database

        if isDefault {
            self.database = database
        }

        if keys[key] == database, let port = Self.port(path, settings: settings), !databases.contains(where: { $0.copy == database && $0.port == port }) {
            databases.append(WorkspaceDatabase(name: setting.value.description, copy: database, port: port, isDefault: isDefault))
        }
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
            if isDefault {
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

    private static func isOnNexus(_ path: String, ports: Set<Int>, settings: [String: ConfigSetting]) -> Bool {
        isLocal(path, settings: settings) && port(path, settings: settings).map(ports.contains) ?? false
    }

    private static func isLocal(_ path: String, settings: [String: ConfigSetting]) -> Bool {
        value("host", at: path, settings: settings).map { localHosts.contains($0.description) } ?? true
    }

    private static func port(_ path: String, settings: [String: ConfigSetting]) -> Int? {
        value("port", at: path, settings: settings).flatMap { Int($0.description) }
    }

    // For a write, Laravel puts the write settings over the settings of the connection. A write
    // host can be a list, and the configuration then has it as write.host.0.
    private static func value(_ name: String, at path: String, settings: [String: ConfigSetting]) -> ConfigValue? {
        ["\(path).write.\(name)", "\(path).write.\(name).0", "\(path).\(name)"].compactMap { settings[$0]?.value }.first { $0 != .null }
    }

    private static func usesRedis(_ configuration: LaravelConfiguration) -> Bool {
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
