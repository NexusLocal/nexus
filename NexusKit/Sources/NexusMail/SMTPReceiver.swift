import Foundation
import NexusCore

// The SMTP server of nexusd on 127.0.0.1. deliver decides for each mail. The client gets "250"
// only after deliver accepts the mail, so a mail is never lost after that answer.
public final class SMTPReceiver: Sendable {
    public static let standardMaxSize = 50 * 1024 * 1024

    private let listener: LoopbackListener

    // Port 0 takes a free port, for the tests.
    public init(port: Int, maxSize: Int = standardMaxSize, idleTimeout: TimeInterval = 300, deliver: @escaping @Sendable (MailMessage) -> MailAcceptance) {
        let connection = SMTPConnection(maxSize: maxSize, deliver: deliver)
        listener = LoopbackListener(port: port, label: "nl.roodfruit.nexus.smtp", idleTimeout: idleTimeout) { socket in
            connection.serve(socket)
        }
    }

    public var port: Int {
        listener.port
    }

    public func start() throws {
        try listener.start()
    }

    // The port is free when stop returns. So a removal or a port change can use it at once.
    public func stop() {
        listener.stop()
    }
}

// One SMTP connection, on the thread of the listener.
private struct SMTPConnection: Sendable {
    let maxSize: Int
    let deliver: @Sendable (MailMessage) -> MailAcceptance

    func serve(_ socket: LineSocket) {
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
}
