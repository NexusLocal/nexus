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
}

public enum NexusResponse: Codable, Sendable, Equatable {
    case done(message: String)
    case services([ServiceStatus])
    case available([ManifestPackage])
    case installed([InstalledRuntime])
    case hosts([String])
    case sites([SiteInfo])
    case toggles([Toggle])
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
