import Foundation
import NexusCore

// A URL of a database or Redis server in an env value, as Node.js apps use it: DATABASE_URL for
// Prisma and Drizzle, REDIS_URL for ioredis, MONGODB_URI for mongoose (D67). A URL without a port
// uses the standard port of its kind. A MongoDB URL can name more than one server.
public struct ConnectionURL: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case mysql
        case postgresql
        case redis
        case mongodb
    }

    public let kind: Kind
    public let host: String
    public let port: Int
    // The database name, or the Redis index, from the path.
    public let path: String
    // A host or socket in the query goes past the host and the port.
    public let namesSocket: Bool
    public let usesVariables: Bool
    public let namesServers: Bool

    private static let kinds: [String: Kind] = [
        "mysql": .mysql,
        "mysql2": .mysql,
        "mariadb": .mysql,
        "postgres": .postgresql,
        "postgresql": .postgresql,
        "redis": .redis,
        "mongodb": .mongodb,
    ]

    // Returns nil for a value that is no URL of one of these kinds. mongodb+srv asks DNS for its
    // servers, so it is no URL of one server.
    public init?(_ value: String) {
        guard let colon = value.firstIndex(of: ":"), let kind = Self.kinds[value[..<colon].lowercased()], value[colon...].hasPrefix("://") else {
            return nil
        }

        self.kind = kind
        usesVariables = value.contains("$")
        namesServers = kind == .mongodb && MongoDBURL.namesServers(value)

        guard !usesVariables, !namesServers, let components = URLComponents(string: value), let host = components.host, !host.isEmpty else {
            host = ""
            port = 0
            path = ""
            namesSocket = false
            return
        }

        self.host = host
        port = components.port ?? kind.standardPort
        path = String(components.path.drop { $0 == "/" })
        namesSocket = components.queryItems?.contains { ["host", "socket", "socketpath"].contains($0.name.lowercased()) } ?? false
    }

    // A URL of MongoDB Atlas starts with mongodb+srv.
    public static func isMongoDB(_ value: String) -> Bool {
        ["mongodb://", "mongodb+srv://"].contains { value.lowercased().hasPrefix($0) }
    }

    public var isReadable: Bool {
        !usesVariables && !namesServers && !host.isEmpty
    }

    public var isLocal: Bool {
        Self.isLocal(host)
    }

    static func isLocal(_ host: String) -> Bool {
        WorkspaceEnvPlan.localHosts.contains(host.lowercased()) || host == "[::1]"
    }

    public var redisIndex: Int {
        Int(path) ?? 0
    }

    // The same URL with the host and the port of the server of a workspace. The user, the
    // password, the database and the query stay.
    public static func pointing(_ value: String, toPort port: Int) -> String {
        guard var components = URLComponents(string: value) else {
            return value
        }

        components.host = WorkspaceEnvPlan.serverHost
        components.port = port
        return components.string ?? value
    }

    public static func withRedisIndex(_ value: String, _ index: Int) -> String {
        guard var components = URLComponents(string: value) else {
            return value
        }

        components.path = "/\(index)"
        return components.string ?? value
    }
}

extension ConnectionURL.Kind {
    var standardPort: Int {
        switch self {
        case .mysql: 3306
        case .postgresql: 5432
        case .redis: 6379
        case .mongodb: 27017
        }
    }
}
