import Foundation

// The values of BSON that the commands of Nexus use. A value of another type stays as its bytes. So
// Nexus can change one key of a document of the server and write the document back.
public indirect enum BSONValue: Sendable, Equatable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(Data)
    case objectID(Data)
    case bool(Bool)
    case null
    case int32(Int32)
    case int64(Int64)
    case other(type: UInt8, bytes: Data)

    public var document: BSONDocument? {
        guard case .document(let document) = self else {
            return nil
        }

        return document
    }

    public var array: [BSONValue]? {
        guard case .array(let values) = self else {
            return nil
        }

        return values
    }

    public var string: String? {
        guard case .string(let text) = self else {
            return nil
        }

        return text
    }

    public var binary: Data? {
        guard case .binary(let data) = self else {
            return nil
        }

        return data
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }

        return value
    }

    // The server gives one number as a double, an int32 or an int64. listDatabases gives sizes as
    // each of them.
    public var int64: Int64? {
        switch self {
        case .int32(let value): Int64(value)
        case .int64(let value): value
        case .double(let value): Int64(exactly: value.rounded())
        default: nil
        }
    }
}

// A document keeps the order of its keys, because the first key of a command is its name.
public struct BSONDocument: Sendable, Equatable {
    public private(set) var elements: [(key: String, value: BSONValue)]

    public init(_ elements: [(key: String, value: BSONValue)] = []) {
        self.elements = elements
    }

    public static func == (first: BSONDocument, second: BSONDocument) -> Bool {
        first.elements.elementsEqual(second.elements) { $0.key == $1.key && $0.value == $1.value }
    }

    public subscript(key: String) -> BSONValue? {
        get {
            elements.first { $0.key == key }?.value
        }
        set {
            guard let index = elements.firstIndex(where: { $0.key == key }) else {
                if let newValue {
                    elements.append((key, newValue))
                }

                return
            }

            guard let newValue else {
                elements.remove(at: index)
                return
            }

            elements[index].value = newValue
        }
    }
}

extension BSONDocument: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, BSONValue)...) {
        self.init(elements.map { (key: $0.0, value: $0.1) })
    }
}

public enum BSONError: Error, Equatable {
    case invalidDocument
    case invalidKey(String)
}

public enum BSON {
    // A document of a server can be 16 MB. A nested value has no more levels than the server allows.
    static let maxDepth = 200

    public static func encode(_ document: BSONDocument) throws -> Data {
        var body = Data()

        for (key, value) in document.elements {
            try append(value, key: key, to: &body)
        }

        return littleEndian(Int32(body.count + 5)) + body + [0]
    }

    public static func decode(_ data: Data) throws -> BSONDocument {
        var reader = BSONReader(data: data)
        let document = try reader.document(depth: 0)

        guard reader.isAtEnd else {
            throw BSONError.invalidDocument
        }

        return document
    }

    private static func append(_ value: BSONValue, key: String, to body: inout Data) throws {
        guard !key.utf8.contains(0) else {
            throw BSONError.invalidKey(key)
        }

        body.append(type(of: value))
        body.append(contentsOf: key.utf8)
        body.append(0)

        switch value {
        case .double(let number):
            body.append(littleEndian(number.bitPattern))
        case .string(let text):
            body.append(littleEndian(Int32(text.utf8.count + 1)))
            body.append(contentsOf: text.utf8)
            body.append(0)
        case .document(let document):
            body.append(try encode(document))
        case .array(let values):
            body.append(try encode(BSONDocument(values.enumerated().map { (key: String($0.offset), value: $0.element) })))
        case .binary(let data):
            body.append(littleEndian(Int32(data.count)))
            body.append(0)
            body.append(data)
        case .objectID(let data):
            body.append(data)
        case .bool(let isTrue):
            body.append(isTrue ? 1 : 0)
        case .null:
            break
        case .int32(let number):
            body.append(littleEndian(number))
        case .int64(let number):
            body.append(littleEndian(number))
        case .other(_, let bytes):
            body.append(bytes)
        }
    }

    private static func type(of value: BSONValue) -> UInt8 {
        switch value {
        case .double: 1
        case .string: 2
        case .document: 3
        case .array: 4
        case .binary: 5
        case .objectID: 7
        case .bool: 8
        case .null: 10
        case .int32: 16
        case .int64: 18
        case .other(let type, _): type
        }
    }

    static func littleEndian(_ value: some FixedWidthInteger) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

// Reads the bytes of one document. Each read checks the length first, so a broken answer gives an
// error and no crash of nexusd.
struct BSONReader {
    private let bytes: [UInt8]
    private var position = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool {
        position == bytes.count
    }

    mutating func document(depth: Int) throws -> BSONDocument {
        guard depth <= BSON.maxDepth else {
            throw BSONError.invalidDocument
        }

        let start = position
        let length = Int(try integer(Int32.self))

        guard length >= 5, length <= bytes.count - start else {
            throw BSONError.invalidDocument
        }

        let end = start + length - 1
        var elements: [(key: String, value: BSONValue)] = []

        while position < end {
            let type = try byte()
            let key = try text(before: end)
            elements.append((key, try value(type: type, depth: depth)))
        }

        guard position == end, try byte() == 0 else {
            throw BSONError.invalidDocument
        }

        return BSONDocument(elements)
    }

    private mutating func value(type: UInt8, depth: Int) throws -> BSONValue {
        switch type {
        case 1:
            return .double(Double(bitPattern: try integer(UInt64.self)))
        case 2:
            return .string(try lengthAndText())
        case 3:
            return .document(try document(depth: depth + 1))
        case 4:
            return .array(try document(depth: depth + 1).elements.map(\.value))
        case 5:
            return try binary()
        case 7:
            return .objectID(try take(12))
        case 8:
            return .bool(try byte() == 1)
        case 10:
            return .null
        case 16:
            return .int32(try integer(Int32.self))
        case 18:
            return .int64(try integer(Int64.self))
        default:
            return .other(type: type, bytes: try bytesOfOther(type))
        }
    }

    // A binary of another subtype than 0 keeps its bytes as they are.
    private mutating func binary() throws -> BSONValue {
        let start = position
        let length = Int(try integer(Int32.self))
        let subtype = try byte()

        guard length >= 0 else {
            throw BSONError.invalidDocument
        }

        let data = try take(length)

        return subtype == 0 ? .binary(data) : .other(type: 5, bytes: Data(bytes[start..<position]))
    }

    // Dates, timestamps, undefined, the smallest and the largest key, Decimal128, regular
    // expressions, code and symbols. MongoDB still reads the old types.
    private mutating func bytesOfOther(_ type: UInt8) throws -> Data {
        let start = position

        switch type {
        case 6, 127, 255:
            break
        case 9, 17:
            _ = try take(8)
        case 19:
            _ = try take(16)
        case 11:
            _ = try text(before: bytes.count)
            _ = try text(before: bytes.count)
        case 12:
            _ = try lengthAndText()
            _ = try take(12)
        case 13, 14:
            _ = try lengthAndText()
        case 15:
            let length = Int(try integer(Int32.self))

            guard length >= 14 else {
                throw BSONError.invalidDocument
            }

            _ = try take(length - 4)
        default:
            throw BSONError.invalidDocument
        }

        return Data(bytes[start..<position])
    }

    private mutating func lengthAndText() throws -> String {
        let length = Int(try integer(Int32.self))

        guard length >= 1 else {
            throw BSONError.invalidDocument
        }

        let data = try take(length)

        guard data.last == 0, let text = String(data: data.dropLast(), encoding: .utf8) else {
            throw BSONError.invalidDocument
        }

        return text
    }

    private mutating func text(before end: Int) throws -> String {
        guard let zero = bytes[position..<end].firstIndex(of: 0), let text = String(bytes: bytes[position..<zero], encoding: .utf8) else {
            throw BSONError.invalidDocument
        }

        position = zero + 1
        return text
    }

    private mutating func byte() throws -> UInt8 {
        guard position < bytes.count else {
            throw BSONError.invalidDocument
        }

        defer { position += 1 }
        return bytes[position]
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - position else {
            throw BSONError.invalidDocument
        }

        defer { position += count }
        return Data(bytes[position..<position + count])
    }

    private mutating func integer<Integer: FixedWidthInteger>(_ type: Integer.Type) throws -> Integer {
        let data = try take(MemoryLayout<Integer>.size)
        return data.reversed().reduce(Integer.zero) { $0 << 8 | Integer(truncatingIfNeeded: $1) }
    }
}
