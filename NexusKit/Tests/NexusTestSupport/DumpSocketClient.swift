import Darwin
import Foundation
import NexusCore
import NexusDumps

public enum DumpSocketClient {
    public static func connect(to socket: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = DumpReceiver.address(of: socket.path(percentEncoded: false))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("connect", code)
        }

        return descriptor
    }

    public static func write(_ text: String, to descriptor: Int32) throws {
        let data = Data(text.utf8)
        var offset = 0

        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress! + offset, data.count - offset)
            }

            guard written > 0 else {
                throw SocketError.system("write", errno)
            }

            offset += written
        }
    }

    public static func send(_ text: String, to socket: URL) throws {
        let descriptor = try connect(to: socket)
        defer { close(descriptor) }

        try write(text, to: descriptor)
    }
}
