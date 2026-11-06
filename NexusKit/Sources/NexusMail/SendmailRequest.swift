import Foundation

public enum SendmailError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    public var description: String {
        switch self {
        case .usage(let text): text
        }
    }
}

// The arguments of nexus sendmail, as PHP and other programs give them to a sendmail. nexus sendmail
// reads the mail to the end of the input, as with -i. A flag that changes nothing for a local
// inbox, such as -oi or -odi, is accepted and has no effect.
public struct SendmailRequest: Sendable, Equatable {
    public var port: Int?
    public var from: String?
    public var recipients: [String] = []
    public var readsHeaders = false

    // These flags take a value, attached or as the next argument. Only -S, -f and -r count.
    private static let flagsWithValue: Set<Character> = ["S", "f", "r", "F", "B", "C", "L", "N", "O", "R", "V", "X", "h"]

    public static let usage = "Usage: nexus sendmail -S 127.0.0.1:<port> [-t] [-i] [-f <sender>] [<recipient> ...]"

    public static func parse(_ arguments: [String]) throws -> SendmailRequest {
        var request = SendmailRequest()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if argument == "--" {
                request.recipients += arguments[index...]
                break
            }

            guard argument.hasPrefix("-"), argument.count > 1 else {
                request.recipients.append(argument)
                continue
            }

            let flag = argument.dropFirst().first!

            if argument == "-bs" {
                throw SendmailError.usage("nexus sendmail does not speak SMTP on its input (-bs). Send the mail to 127.0.0.1 with SMTP, or leave out -bs.")
            }

            guard flagsWithValue.contains(flag) else {
                request.readsHeaders = request.readsHeaders || argument == "-t"
                continue
            }

            var value = String(argument.dropFirst(2))
            if value.isEmpty {
                guard index < arguments.count else {
                    throw SendmailError.usage("\(argument) needs a value. \(usage)")
                }

                value = arguments[index]
                index += 1
            }

            switch flag {
            case "S": request.port = try port(of: value)
            case "f", "r": request.from = value
            default: break
            }
        }

        return request
    }

    // The mail for the receiver. Without a recipient in the arguments, or with -t, the recipients
    // come from To, Cc and Bcc. Without -f, the sender comes from From.
    public func message(from data: Data, user: String?, received: Date = .now) throws -> MailMessage {
        let headers = MailHeaders.fields(of: data)
        var recipients = self.recipients

        if recipients.isEmpty || readsHeaders {
            let fromHeaders = headers.filter { ["to", "cc", "bcc"].contains($0.name.lowercased()) }.flatMap { MailHeaders.addresses(in: $0.value) }
            recipients += fromHeaders.filter { !recipients.contains($0) }
        }

        guard !recipients.isEmpty else {
            throw SendmailError.usage("The mail has no recipient. Give one, or put a To header in the mail.")
        }

        let sender = from ?? headers.first { $0.name.lowercased() == "from" }.flatMap { MailHeaders.addresses(in: $0.value).first } ?? ""
        return MailMessage(from: sender, recipients: recipients, user: user, received: received, data: data)
    }

    // The host must be the computer itself, because the receiver of nexusd listens only there.
    private static func port(of value: String) throws -> Int {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)

        guard parts.count == 2, ["127.0.0.1", "localhost"].contains(parts[0]), let port = Int(parts[1]), (1...65535).contains(port) else {
            throw SendmailError.usage("-S needs 127.0.0.1 and a port, for example -S 127.0.0.1:1025. \(usage)")
        }

        return port
    }
}

// The header of a raw mail. A line that starts with a space or a tab continues the line above it.
enum MailHeaders {
    static func fields(of data: Data) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = []

        for line in MailLines.lines(of: data).map({ String(decoding: $0, as: UTF8.self) }) {
            if line.isEmpty {
                break
            }

            if line.first == " " || line.first == "\t", !fields.isEmpty {
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                continue
            }

            fields.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }

        return fields
    }

    // "Doe, John" <john@example.com>, jane@example.com gives john@example.com and jane@example.com.
    // A comma in quotes or in a comment does not end an address. A part without an @ is no address,
    // for example the group undisclosed-recipients:;.
    static func addresses(in value: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var quoted = false
        var comment = 0

        for character in value {
            switch character {
            case "\"" where comment == 0:
                quoted.toggle()
            case "(" where !quoted:
                comment += 1
            case ")" where !quoted && comment > 0:
                comment -= 1
            case "," where !quoted && comment == 0:
                parts.append(part)
                part = ""
                continue
            default:
                break
            }

            part.append(character)
        }

        parts.append(part)

        return parts.compactMap { part in
            let address = part.firstMatch(of: /<([^<>]*)>/).map { String($0.1) } ?? part.replacing(/\([^)]*\)/, with: "")
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("@") ? trimmed : nil
        }
    }
}
