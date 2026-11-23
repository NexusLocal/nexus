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

    package static func checkPath(_ socket: URL) throws {
        try checkPath(socket.path(percentEncoded: false))
    }

    // A Unix socket path has room for 104 bytes with the end byte.
    package static func checkPath(_ path: String) throws {
        guard path.utf8.count <= 103 else {
            throw SocketError.pathTooLong(path)
        }
    }
}

package enum UnixSocket {
    // The address of a socket file for bind and connect.
    package static func address(of path: String) throws -> sockaddr_un {
        try SocketError.checkPath(path)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }

        return address
    }

    // SO_NOSIGPIPE comes before the connect, as for IPv4Socket.connectToLoopback.
    package static func connect(to path: String) throws -> Int32 {
        var target = try address(of: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }

        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("connect", code)
        }

        return descriptor
    }
}
