import Foundation

// The commands of one SMTP connection, without the socket. The receiver gives it each line and
// sends back each answer. AUTH accepts every user name and password, because the user name is only
// the tag of the mail. There is no STARTTLS, because the receiver listens on 127.0.0.1 only.
public struct SMTPSession: Sendable {
    public enum Step: Sendable, Equatable {
        case reply(String)
        case startData(String)
        case close(String)
    }

    private enum Waiting: Sendable {
        case command
        case plainCredentials
        case loginUser
        case loginPassword
    }

    public static let greeting = "220 nexus ESMTP Nexus mail"
    public static let maxRecipients = 1000

    public let maxSize: Int
    private(set) public var user: String?
    private var from: String?
    private var recipients: [String] = []
    private var waiting = Waiting.command

    public init(maxSize: Int) {
        self.maxSize = maxSize
    }

    public mutating func handle(_ line: String) -> Step {
        switch waiting {
        case .plainCredentials:
            waiting = .command
            return acceptPlain(line)
        case .loginUser:
            user = Self.decoded(line).flatMap { $0.isEmpty ? nil : $0 }
            waiting = .loginPassword
            return .reply("334 UGFzc3dvcmQ6")
        case .loginPassword:
            waiting = .command
            return .reply("235 2.7.0 Authentication successful")
        case .command:
            return command(line)
        }
    }

    // The message ends the transaction. The next mail of this connection starts with MAIL again.
    public mutating func message(_ data: Data, received: Date = .now) -> MailMessage {
        defer { reset() }
        return MailMessage(from: from ?? "", recipients: recipients, user: user, received: received, data: data)
    }

    private mutating func command(_ line: String) -> Step {
        let verb = line.prefix { $0 != " " }.uppercased()
        let argument = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)

        switch verb {
        case "EHLO":
            reset()
            return .reply(["250-nexus", "250-SIZE \(maxSize)", "250-8BITMIME", "250-SMTPUTF8", "250 AUTH PLAIN LOGIN"].joined(separator: "\r\n"))
        case "HELO":
            reset()
            return .reply("250 nexus")
        case "AUTH":
            return authenticate(argument)
        case "MAIL":
            return mail(argument)
        case "RCPT":
            return recipient(argument)
        case "DATA":
            guard from != nil, !recipients.isEmpty else {
                return .reply("503 5.5.1 Send MAIL and RCPT first")
            }

            return .startData("354 End data with <CR><LF>.<CR><LF>")
        case "RSET":
            reset()
            return .reply("250 2.0.0 OK")
        case "NOOP":
            return .reply("250 2.0.0 OK")
        case "VRFY":
            return .reply("252 2.1.5 Cannot verify the user")
        case "QUIT":
            return .close("221 2.0.0 Bye")
        case "STARTTLS":
            return .reply("454 4.7.0 TLS is not available")
        default:
            return .reply("502 5.5.2 Command not implemented")
        }
    }

    private mutating func authenticate(_ argument: String) -> Step {
        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)

        switch parts.first?.uppercased() {
        case "PLAIN":
            guard parts.count == 2 else {
                waiting = .plainCredentials
                return .reply("334 ")
            }

            return acceptPlain(parts[1])
        case "LOGIN":
            guard parts.count == 2 else {
                waiting = .loginUser
                return .reply("334 VXNlcm5hbWU6")
            }

            user = Self.decoded(parts[1]).flatMap { $0.isEmpty ? nil : $0 }
            waiting = .loginPassword
            return .reply("334 UGFzc3dvcmQ6")
        default:
            return .reply("504 5.5.4 Unknown authentication method")
        }
    }

    // PLAIN holds an authorization identity, the user name and the password, each after a zero byte.
    private mutating func acceptPlain(_ credentials: String) -> Step {
        let fields = Self.decoded(credentials)?.split(separator: "\0", omittingEmptySubsequences: false) ?? []

        if fields.count >= 2, !fields[1].isEmpty {
            user = String(fields[1])
        }

        return .reply("235 2.7.0 Authentication successful")
    }

    private mutating func mail(_ argument: String) -> Step {
        guard let address = Self.address(after: "FROM:", in: argument) else {
            return .reply("501 5.5.4 Use MAIL FROM:<address>")
        }

        if let size = Self.parameter("SIZE", in: argument).flatMap(Int.init), size > maxSize {
            return .reply("552 5.3.4 The mail is larger than \(maxSize) bytes")
        }

        from = address
        recipients = []
        return .reply("250 2.1.0 OK")
    }

    private mutating func recipient(_ argument: String) -> Step {
        guard from != nil else {
            return .reply("503 5.5.1 Send MAIL first")
        }

        guard let address = Self.address(after: "TO:", in: argument), !address.isEmpty else {
            return .reply("501 5.5.4 Use RCPT TO:<address>")
        }

        guard recipients.count < Self.maxRecipients else {
            return .reply("452 4.5.3 Too many recipients")
        }

        recipients.append(address)
        return .reply("250 2.1.5 OK")
    }

    private mutating func reset() {
        from = nil
        recipients = []
    }

    static func decoded(_ base64: String) -> String? {
        Data(base64Encoded: base64.trimmingCharacters(in: .whitespaces)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MAIL FROM:<a@b> and RCPT TO:<a@b>, also with a space after the colon or without the brackets.
    static func address(after prefix: String, in argument: String) -> String? {
        guard argument.uppercased().hasPrefix(prefix) else {
            return nil
        }

        let rest = argument.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)

        if rest.hasPrefix("<") {
            guard let end = rest.firstIndex(of: ">") else {
                return nil
            }

            return String(rest[rest.index(after: rest.startIndex)..<end])
        }

        return rest.split(separator: " ").first.map(String.init) ?? ""
    }

    static func parameter(_ name: String, in argument: String) -> String? {
        argument.split(separator: " ").first { $0.uppercased().hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}
