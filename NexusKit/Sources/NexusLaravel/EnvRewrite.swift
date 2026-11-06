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

    // "Send mail to Nexus" keeps the old line of each key that it changes as a comment line above
    // that key. A key that Nexus adds gets a comment line with its name. So "Use the old mail
    // settings…" can put the old lines back. A key line after a comment line of Nexus for that key
    // gets no second comment line. The first one holds the value of before Nexus.
    public static func applyKeepingOldValues(to text: String, keys: [String: String]) -> String {
        var result: [String] = []
        var written: Set<String> = []
        var marked: Set<String> = []

        for line in text.components(separatedBy: "\n") {
            if let mark = NexusMark(line) {
                marked.insert(mark.key)
            }

            guard let envLine = EnvLine(line) else {
                result.append(line)
                continue
            }

            let hasMark = marked.remove(envLine.key) != nil

            guard let value = keys[envLine.key] else {
                result.append(line)
                continue
            }

            let newLine = envLine.prefix + quoted(value)
            written.insert(envLine.key)

            if newLine != line, !hasMark {
                result.append(EnvFile.beforeNexus + line)
            }

            result.append(newLine)
        }

        let missing = keys.filter { !written.contains($0.key) }.sorted { $0.key < $1.key }
        var joined = result.joined(separator: "\n")

        guard !missing.isEmpty else {
            return joined
        }

        if !joined.isEmpty, !joined.hasSuffix("\n") {
            joined += "\n"
        }

        return joined + missing.map { "\(EnvFile.addedByNexus)\($0.key)\n\($0.key)=\(quoted($0.value))\n" }.joined()
    }

    public static func hasOldValues(in text: String) -> Bool {
        let restore = restoringOldValues(in: text)
        return !restore.restored.isEmpty || !restore.removed.isEmpty
    }

    // Puts back each old line and removes each line that Nexus added, with the comment lines of
    // Nexus. A comment line acts on the first line below it that sets its key. Other lines can be
    // between them. A comment line of a changed key without that line gives back the old line in
    // its place. A comment line that holds no valid key line stays, because Laravel reads no .env
    // with a wrong line.
    public static func restoringOldValues(in text: String) -> (text: String, restored: [String], removed: [String]) {
        var lines: [String?] = text.components(separatedBy: "\n")
        var restored: [String] = []
        var removed: [String] = []

        for index in lines.indices {
            guard let line = lines[index], let mark = NexusMark(line) else {
                continue
            }

            let target = lines.indices.first { $0 > index && lines[$0].flatMap(EnvLine.init)?.key == mark.key }
            target.map { lines[$0] = nil }

            switch mark {
            case .changed(let key, let oldLine):
                lines[index] = oldLine
                restored.append(key)
            case .added(let key):
                lines[index] = nil

                if target != nil {
                    removed.append(key)
                }
            }
        }

        return (lines.compactMap { $0 }.joined(separator: "\n"), restored, removed)
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

// A comment line of "Send mail to Nexus". changed holds the line of before Nexus.
private enum NexusMark {
    case changed(key: String, oldLine: String)
    case added(key: String)

    var key: String {
        switch self {
        case .changed(let key, _), .added(let key): key
        }
    }

    init?(_ line: String) {
        let start = line.drop { $0 == " " || $0 == "\t" }

        if start.hasPrefix(EnvFile.beforeNexus) {
            let oldLine = String(start.dropFirst(EnvFile.beforeNexus.count))

            guard let key = EnvLine(oldLine)?.key else {
                return nil
            }

            self = .changed(key: key, oldLine: oldLine)
            return
        }

        guard start.hasPrefix(EnvFile.addedByNexus), let key = EnvLine("\(start.dropFirst(EnvFile.addedByNexus.count).trimmingCharacters(in: .whitespaces))=")?.key else {
            return nil
        }

        self = .added(key: key)
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
