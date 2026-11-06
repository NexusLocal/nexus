import Darwin
import Foundation

enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case lineTooLong

    var description: String {
        switch self {
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .lineTooLong: "A line is longer than the limit."
        }
    }
}

// A TCP socket that reads and writes lines that end in CRLF. A bare LF also ends a line. The
// timeout ends a read or a write that waits too long, so a client that stops cannot keep a thread.
final class LineSocket {
    let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32, timeout: TimeInterval) {
        self.descriptor = descriptor

        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    // A line without its end, or nil when the other side closed the connection.
    func readLine(maxLength: Int = 1 << 20) throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]

                if line.last == UInt8(ascii: "\r") {
                    line = line.dropLast()
                }

                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }

            guard buffer.count <= maxLength else {
                throw SocketError.lineTooLong
            }

            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor, &chunk, chunk.count)

            guard count >= 0 else {
                throw SocketError.system("read", errno)
            }

            guard count > 0 else {
                return nil
            }

            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func writeLine(_ text: String) throws {
        try write(Data("\(text)\r\n".utf8))
    }

    func write(_ data: Data) throws {
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

    func close() {
        Darwin.close(descriptor)
    }

    static func connect(port: Int, timeout: TimeInterval) throws -> LineSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var address = loopback(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.system("connect", code)
        }

        return LineSocket(descriptor: descriptor, timeout: timeout)
    }

    static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

// SMTP lines end in CRLF. A mail from sendmail can use LF only, as PHP mail() writes it.
enum MailLines {
    static func lines(of data: Data) -> [Data] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
            line.last == UInt8(ascii: "\r") ? Data(line.dropLast()) : Data(line)
        }

        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }

    static func crlf(_ data: Data) -> Data {
        lines(of: data).reduce(into: Data()) { result, line in
            result.append(line)
            result.append(contentsOf: [13, 10])
        }
    }
}
