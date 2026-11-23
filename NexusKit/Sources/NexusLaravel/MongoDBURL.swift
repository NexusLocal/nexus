import Foundation
import NexusCore

// A mongodb:// URL with one server. A URL with a list of servers or with mongodb+srv names no one
// server that Nexus can find. The database is empty when the URL has none.
public struct MongoDBURL: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let database: String

    public init?(_ value: String) {
        guard value.lowercased().hasPrefix("mongodb://") else {
            return nil
        }

        guard !Self.namesServers(value), let components = URLComponents(string: value), let host = components.host, !host.isEmpty else {
            return nil
        }

        self.host = host
        port = components.port ?? DatabaseKind.mongodb.standardPort
        database = String(components.path.drop { $0 == "/" })
    }

    public var isLocal: Bool {
        ConnectionURL.isLocal(host)
    }

    // The first server of a URL, without the user and the password. So a screen can show it.
    static func firstServer(_ value: String) -> String {
        String(servers(in: value).split(separator: ",").first ?? "")
    }

    // A list of servers, as in mongodb://127.0.0.1:27017,127.0.0.1:27018/app.
    static func namesServers(_ value: String) -> Bool {
        servers(in: value).contains(",")
    }

    // The host of each server, without its port.
    static func hosts(in value: String) -> [String] {
        servers(in: value).split(separator: ",").map { WorkspaceEnvPlan.split(host: String($0)).host }
    }

    private static func servers(in value: String) -> Substring {
        let afterScheme = value.split(separator: "://", maxSplits: 1).last ?? ""
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" }
        return authority.split(separator: "@").last ?? ""
    }
}

// The server and the database of a Laravel connection with the driver mongodb (the package
// mongodb/laravel-mongodb). It reads the server from dsn, or else from host and port. host can
// hold the port too. The database comes from database, else from the URL. The port is nil when
// the connection has no single server that Nexus can find, for example with mongodb+srv.
public struct LaravelMongoDBConnection: Equatable, Sendable {
    public let host: String
    public let port: Int?
    public let database: String

    public init?(path: String, settings: [String: ConfigSetting]) {
        guard settings["\(path).driver"]?.value.description == "mongodb" else {
            return nil
        }

        let dsn = WorkspaceEnvPlan.value("dsn", at: path, settings: settings)?.description ?? ""
        let named = WorkspaceEnvPlan.value("database", at: path, settings: settings)?.description ?? ""

        guard dsn.isEmpty else {
            let url = MongoDBURL(dsn)

            host = url?.host ?? MongoDBURL.firstServer(dsn)
            port = url?.port
            database = named.isEmpty ? url?.database ?? "" : named
            return
        }

        let hostValue = Self.hostSetting(path: path, settings: settings)?.value.description ?? WorkspaceEnvPlan.serverHost
        let parts = hostValue.split(separator: ":", maxSplits: 1).map(String.init)

        host = parts.first ?? WorkspaceEnvPlan.serverHost
        port = parts.count == 2 ? Int(parts[1]) : WorkspaceEnvPlan.port(path, settings: settings) ?? DatabaseKind.mongodb.standardPort
        database = named
    }

    // The host can be a list of hosts. The first one counts.
    static func hostSetting(path: String, settings: [String: ConfigSetting]) -> ConfigSetting? {
        settings["\(path).host.0"] ?? WorkspaceEnvPlan.setting("host", at: path, settings: settings)
    }
}
