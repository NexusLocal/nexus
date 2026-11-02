import Foundation

// A value from the configuration of a Laravel application.
public enum ConfigValue: Codable, Sendable, Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .text(let text):
            try container.encode(text)
        case .number(let number):
            try container.encode(number)
        case .flag(let flag):
            try container.encode(flag)
        case .null:
            try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .text(let text):
            text
        case .number(let number):
            Int(exactly: number).map(String.init) ?? String(number)
        case .flag(let flag):
            String(flag)
        case .null:
            "null"
        }
    }
}

// One setting of the application, as the configuration probe found it (D43). keys holds the env
// keys that feed the value. No keys means that the value is fixed in a config file. exact is
// false when the application changes the value of the key, for example with a suffix.
public struct ConfigSetting: Codable, Sendable, Equatable {
    public let value: ConfigValue
    public let keys: [String]
    public let exact: Bool

    public init(value: ConfigValue, keys: [String] = [], exact: Bool = false) {
        self.value = value
        self.keys = keys
        self.exact = exact
    }

    public var isFixed: Bool {
        keys.isEmpty
    }
}

// The result of the configuration probe. settings has the path of each setting as its key, for
// example database.connections.main.database.
public struct LaravelConfiguration: Codable, Sendable, Equatable {
    public let version: String
    public let settings: [String: ConfigSetting]
    public let databaseConnections: [String]
    public let redisConnections: [String]

    public init(version: String, settings: [String: ConfigSetting], databaseConnections: [String], redisConnections: [String]) {
        self.version = version
        self.settings = settings
        self.databaseConnections = databaseConnections
        self.redisConnections = redisConnections
    }
}
