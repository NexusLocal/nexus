import Foundation

// The error that a client of a held port gets when its server does not start (plan item 3e, owner
// 2026-11-15). MySQL and MariaDB: an error packet in place of the greeting, without the # of the
// SQL state, as a server sends it before the handshake. 1053 is a code of the server. The mariadb
// client reads a code of the clients, for example 2003, as a malformed packet. PostgreSQL: an
// ErrorResponse after the startup message. 57P03 is "cannot connect now".
public enum PortRefusal {
    public static let mysqlCode: UInt16 = 1053
    public static let postgreSQLState = "57P03"
    public static let messageLimit = 400
    // PostgreSQL closes a connection with a longer first message.
    public static let longestStart = 10_000

    static let sslRequestCode: UInt32 = 80_877_103
    static let encryptionRequestCode: UInt32 = 80_877_104
    static let cancelRequestCode: UInt32 = 80_877_102

    public enum PostgreSQLStart: Equatable, Sendable {
        case sslRequest
        case encryptionRequest
        case cancelRequest(length: Int)
        case startup(length: Int)
        case tooLong
    }

    public static func mysqlErrorPacket(_ message: String) -> Data {
        var payload = Data([0xFF, UInt8(mysqlCode & 0xFF), UInt8(mysqlCode >> 8)])
        payload.append(limited(message))

        var packet = Data([UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF), UInt8((payload.count >> 16) & 0xFF), 0])
        packet.append(payload)
        return packet
    }

    public static func postgreSQLErrorResponse(_ message: String) -> Data {
        var fields = Data()

        for (code, value) in [("S", Data("FATAL".utf8)), ("V", Data("FATAL".utf8)), ("C", Data(postgreSQLState.utf8)), ("M", limited(message))] {
            fields.append(contentsOf: code.utf8)
            fields.append(value)
            fields.append(0)
        }

        fields.append(0)

        var response = Data("E".utf8)
        response.append(bigEndian(UInt32(fields.count + 4)))
        response.append(fields)
        return response
    }

    // The first 8 bytes of a PostgreSQL client: its length and its code. A cancel request of the
    // protocol 3.2 of PostgreSQL 18 can have a longer key, so its length can be more than 16.
    public static func postgreSQLStart(_ head: Data) -> PostgreSQLStart {
        let bytes = [UInt8](head.prefix(8))

        guard bytes.count == 8 else {
            return .tooLong
        }

        let length = Int(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let code = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        guard length >= 8, length <= longestStart else {
            return .tooLong
        }

        switch code {
        case sslRequestCode: return .sslRequest
        case encryptionRequestCode: return .encryptionRequest
        case cancelRequestCode: return .cancelRequest(length: length)
        default: return .startup(length: length)
        }
    }

    // A text longer than the limit ends at a whole character. A zero byte would end the text of
    // PostgreSQL too early.
    static func limited(_ message: String) -> Data {
        var text = Data()

        for character in message where character != "\0" {
            let bytes = Data(String(character).utf8)

            guard text.count + bytes.count <= messageLimit else {
                break
            }

            text.append(bytes)
        }

        return text
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
