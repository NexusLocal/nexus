import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

public enum NexusServiceID {
    public static let dns = "dns"
}

public struct SiteInfo: Codable, Sendable, Equatable {
    public let hosts: [String]
    public let folder: String
    public let documentRoot: String
    public let php: String
    public let server: WebServer
    public let parked: Bool
    public let url: String

    public init(hosts: [String], folder: String, documentRoot: String, php: String, server: WebServer, parked: Bool, url: String) {
        self.hosts = hosts
        self.folder = folder
        self.documentRoot = documentRoot
        self.php = php
        self.server = server
        self.parked = parked
        self.url = url
    }
}

public struct Toggle: Codable, Sendable, Equatable {
    public let name: String
    public let enabled: Bool
    public let required: Bool

    public init(name: String, enabled: Bool, required: Bool) {
        self.name = name
        self.enabled = enabled
        self.required = required
    }
}

public struct SiteChange: Codable, Sendable, Equatable {
    public var php: String?
    public var server: WebServer?
    public var aliases: [String]?

    public init(php: String? = nil, server: WebServer? = nil, aliases: [String]? = nil) {
        self.php = php
        self.server = server
        self.aliases = aliases
    }
}

public struct DatabaseInstance: Codable, Sendable, Equatable {
    public let id: String
    public let kind: DatabaseKind
    public let version: String
    public let port: Int
    public let account: DatabaseAccount
    public let running: Bool
    public let dataFolder: String

    public init(id: String, kind: DatabaseKind, version: String, port: Int, account: DatabaseAccount, running: Bool, dataFolder: String) {
        self.id = id
        self.kind = kind
        self.version = version
        self.port = port
        self.account = account
        self.running = running
        self.dataFolder = dataFolder
    }

    // Without a database, a PostgreSQL client opens the database with the name of the user,
    // and initdb makes no database root. So PostgreSQL opens the database postgres.
    public func url(database: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = kind.urlScheme
        components.user = account.user
        components.password = account.password
        components.host = "127.0.0.1"
        components.port = port
        components.path = (database ?? (kind == .postgresql ? "postgres" : nil)).map { "/\($0)" } ?? ""
        return components.url
    }
}

// The apps that open a database (D36), in the order that Nexus tries them.
public enum DatabaseApp: String, Codable, Sendable, CaseIterable {
    case tablePlus = "table_plus"
    case sequelAce = "sequel_ace"

    public var name: String {
        switch self {
        case .tablePlus: "TablePlus"
        case .sequelAce: "Sequel Ace"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .tablePlus: "com.tinyapp.TablePlus"
        case .sequelAce: "com.sequel-ace.sequel-ace"
        }
    }

    public func opens(_ kind: DatabaseKind) -> Bool {
        self == .tablePlus || kind.usesMySQLProtocol
    }
}

// The server that a copy reads from. A port of nil means the standard port of the instance
// that receives the copy, for example 3306 for MySQL.
public struct DatabaseServer: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var account: DatabaseAccount

    public init(host: String = "127.0.0.1", port: Int? = nil, account: DatabaseAccount = .standard) {
        self.host = host
        self.port = port
        self.account = account
    }
}

// Copies a database from another server into an instance of Nexus (D37). The other server is
// only read.
public struct DatabaseCopy: Codable, Sendable, Equatable {
    public var source: DatabaseServer
    public var database: String
    public var instance: String
    public var name: String?
    public var replace: Bool

    public init(source: DatabaseServer, database: String, instance: String, name: String? = nil, replace: Bool = false) {
        self.source = source
        self.database = database
        self.instance = instance
        self.name = name
        self.replace = replace
    }
}

public enum NexusRequest: Codable, Sendable, Equatable {
    case status
    case start(service: String)
    case stop(service: String)
    case setPort(service: String, port: Int)
    case available
    case installed
    case install(name: String, line: String)
    case remove(name: String, line: String)
    case trust
    case certificate(hosts: [String])
    case hosts
    case addHost(String)
    case removeHost(String)
    case uninstall
    case sites
    case addSite(folder: String, host: String?, aliases: [String], php: String?, server: WebServer?)
    case removeSite(host: String)
    case editSite(host: String, change: SiteChange)
    case park(folder: String, php: String?, server: WebServer?)
    case unpark(folder: String)
    case extensions(php: String)
    case setExtension(php: String, name: String, enabled: Bool)
    case modules(server: WebServer)
    case setModule(server: WebServer, name: String, enabled: Bool)
    case lan(enabled: Bool?)
    case databases
    case copyDatabase(DatabaseCopy)
}

public enum NexusResponse: Codable, Sendable, Equatable {
    case done(message: String)
    case services([ServiceStatus])
    case available([ManifestPackage])
    case installed([InstalledRuntime])
    case hosts([String])
    case sites([SiteInfo])
    case toggles([Toggle])
    case databases([DatabaseInstance])
    case failure(message: String)
}

public enum NexusMessageCoding {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
