import Darwin
import Foundation

// A failed socket call of a receiver in nexusd, for example of the mail or the dump receiver.
package enum SocketError: Error, Equatable, CustomStringConvertible {
    case system(String, Int32)
    case lineTooLong
    case pathTooLong(String)

    package var description: String {
        switch self {
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .lineTooLong: "A line is longer than the limit."
        case .pathTooLong(let path): "The socket path \(path) is longer than the 103 bytes that macOS permits."
        }
    }

    // A Unix socket path has room for 104 bytes with the end byte.
    package static func checkPath(_ socket: URL) throws {
        let path = socket.path(percentEncoded: false)

        guard path.utf8.count <= 103 else {
            throw SocketError.pathTooLong(path)
        }
    }
}
