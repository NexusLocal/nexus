import Foundation

// Changes the keys of one table of ~/.codex/config.toml, for example [mcp_servers.nexus]. All other
// lines stay: other tables, comments, and keys that the user added to the table. An entry in
// another form, such as an inline table or a dotted key, is not safe to change. Nexus then changes
// nothing and shows the entry to copy.
public enum TOMLTextEdit {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    // keepExisting leaves a value that the user chose, for example a longer timeout.
    public struct Key: Equatable, Sendable {
        public let name: String
        public let value: String
        public let keepExisting: Bool

        public init(_ name: String, _ value: String, keepExisting: Bool = false) {
            self.name = name
            self.value = value
            self.keepExisting = keepExisting
        }
    }

    private enum Line {
        case header([String])
        case key([String], value: String)
        case other
    }

    public static func hasTable(_ path: [String], in text: String) throws -> Bool {
        let lines = lines(of: text)
        try checkForOtherForms(of: path, in: lines)
        return range(of: path, in: lines) != nil
    }

    // A value that is not a string gives its text.
    public static func value(_ key: String, inTable path: [String], in text: String) throws -> String? {
        let lines = lines(of: text)
        try checkForOtherForms(of: path, in: lines)

        guard let range = range(of: path, in: lines) else {
            return nil
        }

        for (index, line) in classified(lines) where range.contains(index) {
            if case .header(let header) = line, header != path {
                return nil
            }

            if case .key([key], let value) = line {
                return string(value) ?? value
            }
        }

        return nil
    }

    public static func setting(_ path: [String], keys: [Key], in text: String) throws -> String {
        var lines = lines(of: text)
        try checkForOtherForms(of: path, in: lines)

        guard let range = range(of: path, in: lines) else {
            while lines.last.map(isBlank) == true {
                lines.removeLast()
            }

            let block = ["[\(path.map(bareOrQuoted).joined(separator: "."))]"] + keys.map { "\($0.name) = \($0.value)" }
            return (lines.isEmpty ? block : lines + [""] + block).joined(separator: "\n") + "\n"
        }

        let own = classified(lines).filter { range.contains($0.0) }
        let ownEnd = own.dropFirst().first { if case .header = $0.1 { true } else { false } }?.0 ?? range.upperBound
        var insertAt = range.lowerBound + 1
        var missing: [String] = []

        for (index, line) in own where index < ownEnd {
            if !isBlank(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                insertAt = index + 1
            }
        }

        for key in keys {
            let existing = own.first { index, line in
                guard index < ownEnd, case .key([key.name], _) = line else {
                    return false
                }

                return true
            }

            if let existing {
                if !key.keepExisting {
                    lines[existing.0] = "\(key.name) = \(key.value)"
                }
            } else {
                missing.append("\(key.name) = \(key.value)")
            }
        }

        lines.insert(contentsOf: missing, at: insertAt)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removing(_ path: [String], in text: String) throws -> String {
        var lines = lines(of: text)
        try checkForOtherForms(of: path, in: lines)

        guard let range = range(of: path, in: lines) else {
            return text
        }

        lines.removeSubrange(range)

        if range.lowerBound > 0, range.lowerBound < lines.count, isBlank(lines[range.lowerBound - 1]), isBlank(lines[range.lowerBound]) {
            lines.remove(at: range.lowerBound)
        }

        while lines.last.map(isBlank) == true {
            lines.removeLast()
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func quoted(_ text: String) -> String {
        var result = "\""

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        return result + "\""
    }

    // A basic string with escapes, or a literal string in single quotes. A comment after it stays
    // out.
    static func string(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("'") {
            return text.dropFirst().firstIndex(of: "'").map { String(text[text.index(after: text.startIndex)..<$0]) }
        }

        guard text.hasPrefix("\"") else {
            return nil
        }

        var index = text.index(after: text.startIndex)

        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }

            if text[index] == "\"" {
                return try? JSONDecoder().decode(String.self, from: Data(text[...index].utf8))
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func bareOrQuoted(_ segment: String) -> String {
        segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } && !segment.isEmpty ? segment : quoted(segment)
    }

    private static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if text.hasSuffix("\n") {
            lines.removeLast()
        }

        return lines
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // The lines of the table and its subtables. The blank lines and the comments before the next
    // table belong to that table.
    private static func range(of path: [String], in lines: [String]) -> Range<Int>? {
        var start: Int?
        var end = lines.count

        for (index, line) in classified(lines) {
            guard case .header(let header) = line else {
                continue
            }

            if let begin = start, index > begin, !header.starts(with: path) || header.count == path.count {
                end = index
                break
            }

            if start == nil, header == path {
                start = index
            }
        }

        guard let start else {
            return nil
        }

        while end - 1 > start, isBlank(lines[end - 1]) || lines[end - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            end -= 1
        }

        return start..<end
    }

    // A line in a multi-line string is no header and no key.
    private static func classified(_ lines: [String]) -> [(Int, Line)] {
        var result: [(Int, Line)] = []
        var openString: String?

        for (index, line) in lines.enumerated() {
            let wasOpen = openString != nil

            for marker in ["\"\"\"", "'''"] where openString == nil || openString == marker {
                if line.components(separatedBy: marker).count % 2 == 0 {
                    openString = openString == nil ? marker : nil
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard !wasOpen, !trimmed.hasPrefix("#"), !trimmed.isEmpty else {
                result.append((index, .other))
                continue
            }

            if trimmed.hasPrefix("["), let name = headerName(trimmed) {
                result.append((index, .header(name)))
            } else if let equals = keyEnd(trimmed), let key = segments(trimmed[..<equals]) {
                result.append((index, .key(key, value: String(trimmed[trimmed.index(after: equals)...]))))
            } else {
                result.append((index, .other))
            }
        }

        return result
    }

    // [mcp_servers."nexus-dev"] and [ mcp_servers . nexus ] both give mcp_servers, nexus.
    static func headerName(_ line: String) -> [String]? {
        let body = line.hasPrefix("[[") ? line.dropFirst(2) : line.dropFirst()

        guard let end = body.firstIndex(of: "]") else {
            return nil
        }

        return segments(body[..<end])
    }

    private static func segments(_ key: Substring) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?

        for character in key {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? nil : parts
    }

    // The = after a key. An = in a quoted key does not count.
    private static func keyEnd(_ line: String) -> String.Index? {
        var quote: Character?

        for index in line.indices {
            let character = line[index]

            if let open = quote {
                if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }

        return nil
    }

    // Two definitions of one table make the whole file invalid for Codex. So any other form of
    // the entry stops the change: nexus = { } or nexus.command in [mcp_servers], a dotted key such
    // as mcp_servers.nexus.command, and an inline table mcp_servers = { nexus = { } }.
    private static func checkForOtherForms(of path: [String], in lines: [String]) throws {
        var section: [String] = []

        for (index, line) in classified(lines) {
            switch line {
            case .header(let header):
                section = header
            case .key(let key, let value):
                let full = section + key
                let outsideOwnTable = section.count < path.count || !section.starts(with: path)
                let definesEntry = full.starts(with: path) && outsideOwnTable
                let inlineHoldsEntry = path.starts(with: full) && full.count < path.count && value.contains(try! Regex("(^|[{,\\s])[\"']?\(NSRegularExpression.escapedPattern(for: path[full.count]))[\"']?\\s*="))

                if definesEntry || inlineHoldsEntry {
                    throw Failure(description: "line \(index + 1) sets \(path.joined(separator: ".")) in a form that Nexus does not change")
                }
            case .other:
                break
            }
        }
    }
}
