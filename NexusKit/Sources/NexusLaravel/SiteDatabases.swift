import Foundation
import NexusCore

// The database connections that the Site screen shows. config/database.php of a new Laravel
// application has a connection for each driver, and they all read DB_HOST, DB_PORT and
// DB_DATABASE. So the list has the default connection. Another connection shows only when it
// reaches another database on a Nexus instance of its kind, and when it reads a key of the .env
// that the default connection does not read. A stock connection that the application does not
// use reads the same keys, or none. A SQLite file is no server.
public enum SiteDatabases {
    // socket is the socket file of the instance. PostgreSQL names it after its port.
    public struct Instance: Sendable {
        public let id: String
        public let kind: DatabaseKind
        public let port: Int
        public let socket: String?

        public init(id: String, kind: DatabaseKind, port: Int, socket: String? = nil) {
            self.id = id
            self.kind = kind
            self.port = port
            self.socket = socket
        }
    }

    public static func list(_ configuration: LaravelConfiguration, instances: [Instance]) -> [SiteDatabase] {
        let settings = configuration.settings
        let defaultConnection = settings["database.default"]?.value.description
        let names = configuration.databaseConnections
        let ordered = names.filter { $0 == defaultConnection } + names.filter { $0 != defaultConnection }
        let defaultKeys = defaultConnection.map { keys(of: $0, settings: settings) } ?? []
        var shown: [SiteDatabase] = []

        for name in ordered {
            let isDefault = name == defaultConnection

            guard let database = database(name, isDefault: isDefault, settings: settings, instances: instances) else {
                continue
            }

            if !isDefault, database.instance == nil || keys(of: name, settings: settings).subtracting(defaultKeys).isEmpty {
                continue
            }

            let isShown = shown.contains { $0.database == database.database && $0.instance == database.instance && $0.port == database.port }

            if !isShown {
                shown.append(database)
            }
        }

        return shown
    }

    private static func keys(of name: String, settings: [String: ConfigSetting]) -> Set<String> {
        let path = "database.connections.\(name)"

        return Set(["dsn", "host", "port", "database"].compactMap { WorkspaceEnvPlan.setting($0, at: path, settings: settings) }.flatMap(\.keys))
    }

    // The default connection shows also without a database name, because the application uses
    // that server. The name then is empty.
    private static func database(_ name: String, isDefault: Bool, settings: [String: ConfigSetting], instances: [Instance]) -> SiteDatabase? {
        let path = "database.connections.\(name)"

        guard let driver = settings["\(path).driver"]?.value.description, ["mysql", "mariadb", "pgsql", "mongodb"].contains(driver) else {
            return nil
        }

        if driver == "mongodb" {
            return mongoDB(name, isDefault: isDefault, settings: settings, instances: instances)
        }

        let database = WorkspaceEnvPlan.value("database", at: path, settings: settings)?.description ?? ""

        guard isDefault || !database.isEmpty else {
            return nil
        }

        let port = WorkspaceEnvPlan.port(path, settings: settings)
        let host = WorkspaceEnvPlan.value("host", at: path, settings: settings)?.description ?? WorkspaceEnvPlan.serverHost
        let address = ConnectionAddress(path: path, driver: driver, settings: settings)
        let instance = instances.first { $0.kind.laravelConnections.contains(driver) && address.reaches(port: $0.port, socket: $0.socket) }

        return SiteDatabase(connection: name, database: database, host: host, port: port, instance: instance?.id)
    }

    // The package mongodb/laravel-mongodb reads the server from dsn, or from host and port. The
    // database comes from database, else from the URL.
    private static func mongoDB(_ name: String, isDefault: Bool, settings: [String: ConfigSetting], instances: [Instance]) -> SiteDatabase? {
        guard let server = LaravelMongoDBConnection(path: "database.connections.\(name)", settings: settings) else {
            return nil
        }

        guard isDefault || !server.database.isEmpty else {
            return nil
        }

        let instance = instances.first { instance in
            instance.kind == .mongodb && server.port == instance.port && ConnectionURL.isLocal(server.host)
        }

        return SiteDatabase(connection: name, database: server.database, host: server.host, port: server.port, instance: instance?.id)
    }
}
