import Foundation

// One command or one answer in the wire protocol of MongoDB (OP_MSG). MongoDB 3.6 and newer use it.
enum MongoDBMessage {
    static let operation: Int32 = 2013
    static let headerSize = 16
    // A server sends at most 48,000,000 bytes in a message.
    static let maxSize = 48_000_000

    struct Header: Equatable {
        let size: Int
        let id: Int32
        let answerTo: Int32
        let operation: Int32
    }

    static func command(_ document: BSONDocument, id: Int32) throws -> Data {
        let flags = BSON.littleEndian(UInt32(0))
        let body = flags + [0] + (try BSON.encode(document))

        return BSON.littleEndian(Int32(headerSize + body.count))
            + BSON.littleEndian(id)
            + BSON.littleEndian(Int32(0))
            + BSON.littleEndian(operation)
            + body
    }

    static func header(_ data: Data) throws -> Header {
        let bytes = Array(data)

        guard bytes.count == headerSize else {
            throw MongoDBError.invalidAnswer
        }

        let number = { (start: Int) in bytes[start..<start + 4].reversed().reduce(Int32.zero) { $0 << 8 | Int32($1) } }
        let header = Header(size: Int(number(0)), id: number(4), answerTo: number(8), operation: number(12))

        guard header.operation == operation, (headerSize + 5...maxSize).contains(header.size) else {
            throw MongoDBError.invalidAnswer
        }

        return header
    }

    // The flags, the kind of the one section (0) and the document. No option of Nexus gives a
    // checksum or a second section.
    static func answer(_ body: Data) throws -> BSONDocument {
        let bytes = Array(body)

        guard bytes.count > 5, bytes[0] & 1 == 0, bytes[4] == 0 else {
            throw MongoDBError.invalidAnswer
        }

        return try BSON.decode(Data(bytes[5...]))
    }
}

public enum MongoDBError: Error, Equatable, CustomStringConvertible {
    case connection(String)
    case invalidAnswer
    case loginFailed
    case command(name: String, message: String, code: Int)

    public var description: String {
        switch self {
        case .connection(let reason):
            "MongoDB gave no answer. \(reason)"
        case .invalidAnswer:
            "MongoDB gave an answer that Nexus cannot read."
        case .loginFailed:
            "MongoDB does not accept this user and password."
        case .command(_, let message, _):
            "MongoDB gave an error: \(message)"
        }
    }
}
