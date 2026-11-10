import Foundation

// A JSON value of any shape. The messages of MCP hold arguments and results whose shape only the
// tool knows. A whole number stays an integer. So an id 1 goes back as 1 and not as 1.0.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }

        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }

        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }

        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else {
            return nil
        }

        return object[key]
    }

    public var string: String? {
        guard case .string(let value) = self else {
            return nil
        }

        return value
    }

    public var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value: Int(exactly: value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string("true"): true
        case .string("false"): false
        default: nil
        }
    }

    public var object: [String: JSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }

        return value
    }

    // Any Encodable value as a JSON value, for the structured content of a tool result.
    public static func encoding(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder.mcp.encode(value))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

extension JSONEncoder {
    // One line without escaped slashes. A URL in a result stays readable for the agent. A message
    // of stdio must not hold a line break.
    static var mcp: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
