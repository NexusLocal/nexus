import Foundation
import NexusCore

// A host in a .env value and the host that replaces it. A from with a leading dot is a parent
// domain, as in SESSION_DOMAIN=.shop.test. It also matches inside a subdomain.
public struct HostRewrite: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// Changes only the hosts and the given keys of a .env file, and keeps all other lines (D44). A
// comment stays as it is. A value such as ${APP_HOST} stays as text, so it follows the line that
// sets APP_HOST.
public enum EnvRewrite {
    public static func apply(to text: String, hosts: [HostRewrite], keys: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        var written: Set<String> = []

        for index in lines.indices {
            guard let line = EnvLine(lines[index]) else {
                continue
            }

            if let value = keys[line.key] {
                lines[index] = line.prefix + quoted(value)
                written.insert(line.key)
            } else {
                lines[index] = line.prefix + replacingHosts(in: line.rawValue, hosts)
            }
        }

        let missing = keys.filter { !written.contains($0.key) }.sorted { $0.key < $1.key }

        guard !missing.isEmpty else {
            return lines.joined(separator: "\n")
        }

        var result = lines.joined(separator: "\n")

        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }

        return result + missing.map { "\($0.key)=\(quoted($0.value))\n" }.joined()
    }

    // The Redis indexes that a .env names. A config file can read any key, so the name of the key
    // only has to look like an index. A number that is no index keeps one index out of the choice.
    public static func redisIndexes(in text: String) -> Set<Int> {
        Set(EnvFile.values(in: text).compactMap { name, value -> Int? in
            let key = name.uppercased()

            guard key.contains("REDIS") || key.hasSuffix("_DB") || key.hasSuffix("_DATABASE"), !key.hasSuffix("PORT") else {
                return nil
            }

            return Int(value)
        })
    }

    // The keys whose line changes through a host, with their new value.
    public static func hostChanges(in text: String, hosts: [HostRewrite]) -> [(key: String, value: String)] {
        var changes: [(key: String, value: String)] = []

        for line in text.components(separatedBy: "\n").compactMap(EnvLine.init) {
            let rewritten = replacingHosts(in: line.rawValue, hosts)

            if rewritten != line.rawValue {
                changes.append((line.key, EnvFile.values(in: "\(line.key)=\(rewritten)")[line.key] ?? rewritten))
            }
        }

        return changes
    }

    private static func replacingHosts(in value: String, _ hosts: [HostRewrite]) -> String {
        hosts.sorted { $0.from.count > $1.from.count }.reduce(value) { result, host in
            replacing(host, in: result)
        }
    }

    private static func replacing(_ host: HostRewrite, in value: String) -> String {
        var result = ""
        var rest = value[...]

        while let found = rest.range(of: host.from, options: .caseInsensitive) {
            result += String(rest[..<found.lowerBound])
            let after = rest[found.upperBound...]
            let matches = isBoundary(before: result.last, of: host) && isBoundary(after: after)

            result += matches ? host.to : String(rest[found])
            rest = after
        }

        return result + String(rest)
    }

    private static func isBoundary(before: Character?, of host: HostRewrite) -> Bool {
        host.from.hasPrefix(".") || before.map { !isHostCharacter($0) } ?? true
    }

    private static func isBoundary(after: Substring) -> Bool {
        guard let next = after.first else {
            return true
        }

        if next == "." {
            return after.dropFirst().first.map { !isHostCharacter($0) } ?? true
        }

        return !isHostCharacter(next)
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "#\"'$\\".contains($0) }) else {
            return value
        }

        return "\"\(value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\""))\""
    }
}

// A line KEY=value of a .env file. prefix holds all up to and with the =. rawValue holds the rest
// with its quotes.
private struct EnvLine {
    let key: String
    let prefix: String
    let rawValue: String

    init?(_ line: String) {
        let start = line.drop { $0 == " " || $0 == "\t" }

        guard !start.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
            return nil
        }

        var name = line[..<equals].trimmingCharacters(in: .whitespaces)

        if name.hasPrefix("export ") {
            name = String(name.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else {
            return nil
        }

        key = name
        prefix = String(line[...equals])
        rawValue = String(line[line.index(after: equals)...])
    }
}
