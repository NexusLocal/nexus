import Foundation
import NexusCore

public enum SMTPClientError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case refused(String)

    // A 5xx answer stays the same on a retry. A 4xx answer, such as a full outbox, can change.
    public var isPermanent: Bool {
        if case .refused(let answer) = self {
            return answer.hasPrefix("5")
        }

        return false
    }

    public var description: String {
        switch self {
        case .unreachable(let reason): "The mail server does not answer: \(reason)"
        case .refused(let answer): "The mail server refused the mail: \(answer)"
        }
    }
}

// Sends one mail to an SMTP server on 127.0.0.1: to the receiver of nexusd from nexus sendmail, and
// to Mailpit from nexusd. The user name of the mail goes with AUTH PLAIN, so it stays the tag.
public struct SMTPClient: Sendable {
    public let port: Int
    public let timeout: TimeInterval

    public init(port: Int, timeout: TimeInterval = 30) {
        self.port = port
        self.timeout = timeout
    }

    // .unreachable means that the mail did not arrive, so the caller can keep it. .refused means
    // that the server read the mail and does not want it.
    public func send(_ message: MailMessage) throws {
        let socket: LineSocket

        do {
            socket = try LineSocket.connect(port: port, timeout: timeout)
        } catch {
            throw SMTPClientError.unreachable(ErrorText.plain(error))
        }

        defer { socket.close() }

        do {
            try expect(220, from: socket)
            let extensions = try command("EHLO nexus", expecting: 250, on: socket)

            // Another mail catcher on the port, such as a Mailpit of Homebrew, can refuse AUTH.
            // Without AUTH in its answer to EHLO, the mail goes without the tag.
            if let user = message.user, Self.offersLogin(extensions) {
                let credentials = Data("\0\(user)\0nexus".utf8).base64EncodedString()
                try command("AUTH PLAIN \(credentials)", expecting: 235, on: socket)
            }

            try command("MAIL FROM:<\(message.from)>", expecting: 250, on: socket)

            for recipient in message.recipients {
                try command("RCPT TO:<\(recipient)>", expecting: 250, on: socket)
            }

            try command("DATA", expecting: 354, on: socket)
            try socket.write(Self.stuffed(message.data))
            try command(".", expecting: 250, on: socket)
            try? socket.writeLine("QUIT")
        } catch let error as SMTPClientError {
            throw error
        } catch {
            throw SMTPClientError.unreachable(ErrorText.plain(error))
        }
    }

    // A line that starts with a dot gets a second dot, so it does not end the data.
    static func stuffed(_ data: Data) -> Data {
        MailLines.lines(of: data).reduce(into: Data()) { result, line in
            if line.first == UInt8(ascii: ".") {
                result.append(UInt8(ascii: "."))
            }

            result.append(line)
            result.append(contentsOf: [13, 10])
        }
    }

    // A line of the answer to EHLO such as "250-AUTH PLAIN LOGIN".
    static func offersLogin(_ lines: [String]) -> Bool {
        lines.contains { $0.dropFirst(4).uppercased().hasPrefix("AUTH") }
    }

    @discardableResult
    private func command(_ text: String, expecting code: Int, on socket: LineSocket) throws -> [String] {
        try socket.writeLine(text)
        return try expect(code, from: socket)
    }

    // An answer can have more lines. Each line but the last has a hyphen after the code.
    @discardableResult
    private func expect(_ code: Int, from socket: LineSocket) throws -> [String] {
        var lines: [String] = []

        while true {
            guard let data = try socket.readLine() else {
                throw SMTPClientError.unreachable("The server closed the connection.")
            }

            let line = String(decoding: data, as: UTF8.self)

            guard line.count >= 3, let received = Int(line.prefix(3)) else {
                throw SMTPClientError.refused(line)
            }

            lines.append(line)

            if line.dropFirst(3).first == "-" {
                continue
            }

            guard received == code else {
                throw SMTPClientError.refused(line)
            }

            return lines
        }
    }
}
