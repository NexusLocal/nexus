import Darwin
import Dispatch
import Foundation
import Synchronization

// The SMTP server of nexusd on 127.0.0.1. Each connection runs on its own thread with blocking
// reads, because a local server has few connections. deliver decides for each mail. The client
// gets "250" only after deliver accepts the mail, so a mail is never lost after that answer.
public final class SMTPReceiver: Sendable {
    public static let standardMaxSize = 50 * 1024 * 1024

    private struct Listening: @unchecked Sendable {
        let descriptor: Int32
        let source: any DispatchSourceRead
        let closed: DispatchSemaphore
    }

    private let requestedPort: Int
    private let maxSize: Int
    private let idleTimeout: TimeInterval
    private let deliver: @Sendable (MailMessage) -> MailAcceptance
    private let listening = Mutex<Listening?>(nil)
    private let boundPort = Mutex(0)

    // Port 0 takes a free port, for the tests.
    public init(port: Int, maxSize: Int = standardMaxSize, idleTimeout: TimeInterval = 300, deliver: @escaping @Sendable (MailMessage) -> MailAcceptance) {
        requestedPort = port
        self.maxSize = maxSize
        self.idleTimeout = idleTimeout
        self.deliver = deliver
    }

    public var port: Int {
        boundPort.withLock { $0 }
    }

    public func start() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = LineSocket.loopback(port: requestedPort)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bound == 0, listen(descriptor, 64) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("bind", code)
        }

        boundPort.withLock { $0 = Self.localPort(of: descriptor) }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "nl.roodfruit.nexus.smtp"))
        source.setEventHandler { [weak self] in
            self?.acceptConnection(on: descriptor)
        }
        let closed = DispatchSemaphore(value: 0)
        source.setCancelHandler {
            close(descriptor)
            closed.signal()
        }
        listening.withLock { $0 = Listening(descriptor: descriptor, source: source, closed: closed) }
        source.resume()
    }

    // The port is free when stop returns. So a removal or a port change can use it at once.
    public func stop() {
        let current = listening.withLock { listening in
            defer { listening = nil }
            return listening
        }

        guard let current else {
            return
        }

        current.source.cancel()
        current.closed.wait()
    }

    private func acceptConnection(on descriptor: Int32) {
        let client = accept(descriptor, nil, nil)

        guard client >= 0 else {
            return
        }

        Thread.detachNewThread { [self] in
            serve(LineSocket(descriptor: client, timeout: idleTimeout))
        }
    }

    private func serve(_ socket: LineSocket) {
        defer { socket.close() }
        var session = SMTPSession(maxSize: maxSize)

        do {
            try socket.writeLine(SMTPSession.greeting)

            while let line = try socket.readLine() {
                switch session.handle(String(decoding: line, as: UTF8.self)) {
                case .reply(let text):
                    try socket.writeLine(text)
                case .close(let text):
                    try socket.writeLine(text)
                    return
                case .startData(let text):
                    try socket.writeLine(text)
                    try socket.writeLine(try receiveData(from: socket, into: &session))
                }
            }
        } catch {
            return
        }
    }

    // The data ends with a line that holds one dot. A line that starts with a dot got a second dot
    // from the client. A mail above the limit is read to its end and then refused.
    private func receiveData(from socket: LineSocket, into session: inout SMTPSession) throws -> String {
        var data = Data()
        var tooLarge = false

        while let line = try socket.readLine() {
            if line == Data(".".utf8) {
                let message = session.message(tooLarge ? Data() : data)

                guard !tooLarge else {
                    return "552 5.3.4 The mail is larger than \(maxSize) bytes"
                }

                switch deliver(message) {
                case .accepted:
                    return "250 2.0.0 OK"
                case .refused(let reason):
                    return "452 4.3.1 \(reason)"
                }
            }

            guard !tooLarge else {
                continue
            }

            data.append(line.first == UInt8(ascii: ".") ? line.dropFirst() : line)
            data.append(contentsOf: [13, 10])
            tooLarge = data.count > maxSize
        }

        throw SocketError.system("read", ECONNRESET)
    }

    private static func localPort(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}
