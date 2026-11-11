import Foundation

// One line of a change that the user confirms before Nexus writes it.
public struct TextChangeLine: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case same
        case added
        case removed
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

// The values of a workspace of a classic WordPress site (Phase 4, 3e). WordPress reads them from
// wp-config.php. When git ignores that file, the copy in the worktree gets the values in a block at
// its start. When git tracks it, Nexus does not change it in a worktree (D50). That file then needs
// lines that load wp-config-nexus.php. Git must ignore wp-config-nexus.php. Nexus adds these lines to
// the main checkout only after a click of the user. The user commits them (open decision 3).
public enum WordPressWorkspaceConfig {
    public static let includeFile = "wp-config-nexus.php"

    // A define of one of these constants in wp-config.php gets a defined() guard. The value of the
    // workspace then comes first. PHP gives no warning about a second define.
    public static let constants = ["DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST", "WP_HOME", "WP_SITEURL", "DOMAIN_CURRENT_SITE", "WP_REDIS_DATABASE"]

    public static let includeLines = [
        "if (is_file(__DIR__ . '/\(includeFile)')) {",
        "    require __DIR__ . '/\(includeFile)';",
        "}",
    ]

    static let blockStart = "// Start of the values of the Nexus workspace. Nexus writes these lines at each setup."
    static let blockEnd = "// End of the values of the Nexus workspace."
    static let hiddenPassword = "••••••"

    public struct Change: Sendable, Equatable {
        public let text: String
        public let lines: [TextChangeLine]
    }

    // True when a require or an include of wp-config-nexus.php comes before the first define of
    // DB_HOST. A define before that line would win, because PHP keeps the first value.
    public static func loadsIncludeFile(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")

        guard let include = lines.firstIndex(where: { isCode($0) && $0.contains(includePattern) }) else {
            return false
        }

        guard let define = lines.firstIndex(where: { isCode($0) && $0.contains(definePattern("DB_HOST")) }) else {
            return true
        }

        return include < define
    }

    // The lines for workspaces in the wp-config.php of the main checkout, with the lines of the change
    // for the sheet. A file that loads wp-config-nexus.php already gives nil. A file without <?php at
    // its start gives nil too.
    public static func addingIncludeLines(to text: String) -> Change? {
        guard !loadsIncludeFile(text), var file = PHPFile(text) else {
            return nil
        }

        var shown = file.openingChange
        var lastShown = file.open

        if file.insertAt - 1 > lastShown {
            if file.insertAt - 2 > lastShown {
                shown.append(TextChangeLine(.same, "…"))
            }

            shown.append(TextChangeLine(.same, file.shown(file.lines[file.insertAt - 1])))
        }

        shown += includeLines.map { TextChangeLine(.added, $0) }
        lastShown = file.insertAt - 1

        for guarded in file.guardedLines() {
            if guarded.index - 1 > lastShown {
                if guarded.index - 2 > lastShown {
                    shown.append(TextChangeLine(.same, "…"))
                }

                shown.append(TextChangeLine(.same, file.shown(file.lines[guarded.index - 1])))
            }

            shown += [TextChangeLine(.removed, file.shown(file.lines[guarded.index], hiding: guarded.name)), TextChangeLine(.added, file.shown(guarded.line, hiding: guarded.name))]
            lastShown = guarded.index
            file.lines[guarded.index] = guarded.line
        }

        file.insert(includeLines)
        return Change(text: file.text, lines: shown)
    }

    // The copy of wp-config.php in a worktree that git ignores. A block of an earlier setup goes
    // first. So a second setup gives the same file.
    public static func settingValues(_ values: [(name: String, value: String)], workspace: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let bare = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let start = bare.firstIndex(of: blockStart), let end = bare[start...].firstIndex(of: blockEnd) {
            lines.removeSubrange(start...end)
        }

        guard var file = PHPFile(lines.joined(separator: "\n")) else {
            return nil
        }

        for guarded in file.guardedLines() {
            file.lines[guarded.index] = guarded.line
        }

        file.insert([blockStart] + values.map { "define( '\($0.name)', \(phpValue($0.value, of: $0.name)) );" } + [blockEnd])
        return file.text
    }

    // wp-config-nexus.php of a worktree.
    public static func includeFileText(_ values: [(name: String, value: String)], workspace: String) -> String {
        let defines = values.map { "define( '\($0.name)', \(phpValue($0.value, of: $0.name)) );" }
        return (["<?php", "// Nexus writes this file for the workspace \(workspace) at each setup. git ignores it."] + defines).joined(separator: "\n") + "\n"
    }

    // Only the index of Redis is a number. PHP reads a number with a 0 at its start as an octal
    // number. So a password such as 0123 stays a text.
    static func phpValue(_ value: String, of name: String) -> String {
        name == "WP_REDIS_DATABASE" && Int(value) != nil ? value : PHPString.quoted(value)
    }

    // The lines of wp-config.php. open is the line with <?php. Code after <?php on that line goes to
    // a line of its own, because the new lines must come before it. insertAt is the place of the new
    // lines. A declare statement and a namespace statement must stay first. So the new lines come
    // after them. A file with CRLF line ends gets CRLF in the new lines too.
    private struct PHPFile {
        var lines: [String]
        let open: Int
        let insertAt: Int
        let lineEnd: String
        let openingChange: [TextChangeLine]

        init?(_ text: String) {
            var lines = text.components(separatedBy: "\n")
            let lineEnd = text.contains("\r\n") ? "\r" : ""

            guard let open = lines.firstIndex(where: { !Self.bare($0).isEmpty }), Self.bare(lines[open]).hasPrefix("<?php") else {
                return nil
            }

            let original = lines[open]
            let rest = Self.bare(original).dropFirst("<?php".count)
            var openingChange = [TextChangeLine(.same, Self.withoutLineEnd(original))]

            if let first = rest.first, !first.isWhitespace {
                return nil
            }

            if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                let start = original.hasPrefix("\u{FEFF}") ? "\u{FEFF}<?php" : "<?php"
                lines[open] = start + lineEnd
                lines.insert(rest.trimmingCharacters(in: .whitespaces) + lineEnd, at: open + 1)
                openingChange = [TextChangeLine(.removed, Self.withoutLineEnd(original)), TextChangeLine(.added, "<?php")]
            }

            var insertAt = open + 1
            var index = open + 1

            for keyword in ["declare", "namespace"] {
                while index < lines.count, !isCode(lines[index]) || Self.bare(lines[index]).isEmpty {
                    index += 1
                }

                if index < lines.count, Self.bare(lines[index]).hasPrefix(keyword), Self.bare(lines[index]).hasSuffix(";") {
                    index += 1
                    insertAt = index
                }
            }

            self.lines = lines
            self.open = open
            self.insertAt = insertAt
            self.lineEnd = lineEnd
            self.openingChange = openingChange
        }

        var text: String {
            lines.joined(separator: "\n")
        }

        mutating func insert(_ newLines: [String]) {
            lines.insert(contentsOf: newLines.map { $0 + lineEnd }, at: insertAt)
        }

        // Each define of a constant of the list after the opening line, with its guard. A line in a
        // comment or with a guard of its own stays.
        func guardedLines() -> [(index: Int, name: String, line: String)] {
            lines.indices.dropFirst(open + 1).compactMap { index in
                let line = lines[index]

                guard isCode(line) else {
                    return nil
                }

                for name in constants {
                    guard let match = line.firstMatch(of: definePattern(name)), let range = match.output[1].range, !line.contains(guardPattern(name)) else {
                        continue
                    }

                    var guarded = line
                    guarded.replaceSubrange(range, with: "defined( '\(name)' ) || \(line[range])")
                    return (index, name, guarded)
                }

                return nil
            }
        }

        // A line for the sheet. The sheet does not show the password.
        func shown(_ line: String, hiding name: String? = nil) -> String {
            let text = Self.withoutLineEnd(line)

            guard name == "DB_PASSWORD", let range = text.firstRange(of: /,\s*(['"]).*\1\s*\)/) else {
                return text
            }

            return text.replacingCharacters(in: range, with: ", '\(WordPressWorkspaceConfig.hiddenPassword)' )")
        }

        private static func bare(_ line: String) -> String {
            String(line.drop { $0 == "\u{FEFF}" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func withoutLineEnd(_ line: String) -> String {
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    // A line in a comment does not run.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !["//", "#", "*", "/*"].contains { trimmed.hasPrefix($0) }
    }

    nonisolated(unsafe) private static let includePattern = /(?:require|include)(?:_once)?\b[^;\n]*wp-config-nexus\.php/

    // Swift has no lookbehind. So the define itself is the first group. The character before it must
    // not make it a method or a function with another name.
    private static func definePattern(_ name: String) -> Regex<AnyRegexOutput> {
        try! Regex(#"(?:^|[^\w$>:])(\\?define\s*\(\s*['"]\#(name)['"])"#)
    }

    private static func guardPattern(_ name: String) -> Regex<AnyRegexOutput> {
        try! Regex(#"defined\s*\(\s*['"]\#(name)['"]\s*\)"#)
    }
}
