import Foundation

// A code block keeps its line ends. Each paragraph of a license is one line in the file, and the
// About window wraps it.
public struct ThirdPartyNotices: Sendable, Equatable {
    public struct Project: Sendable, Equatable, Identifiable {
        public let name: String
        public let version: String
        public let license: String
        public let use: String

        public var id: String {
            name
        }
    }

    public enum Block: Sendable, Equatable {
        case paragraph(String)
        case heading(String)
        case text(String)
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let name: String
        public let blocks: [Block]

        public var id: String {
            name
        }
    }

    public let projects: [Project]
    public let sections: [Section]

    public init(markdown: String) {
        var reader = Reader()

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            reader.read(String(line))
        }

        reader.endSection()
        projects = reader.projects
        sections = reader.sections
    }

    // A link to a part of the same file does not work in the app. So it becomes its text.
    private static func withoutLinksInFile(_ text: String) -> String {
        text.replacing(/\[([^\]]+)\]\(#[^)]*\)/) { match in String(match.1) }
    }

    // A row of the table: | [Name](#anchor) | 1.2.3 | License | Use |. The head and the line under
    // it give no project.
    static func project(inRow row: String) -> Project? {
        let cells = row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }

        guard cells.count == 4, let name = cells[0].firstMatch(of: /^\[([^\]]+)\]/)?.1 else {
            return nil
        }

        return Project(name: String(name), version: cells[1], license: cells[2], use: cells[3])
    }

    private static func startsListItem(_ line: String) -> Bool {
        line.contains(/^\s*([-*+]|\d+[.)])\s/)
    }

    private struct Reader {
        var projects: [Project] = []
        var sections: [Section] = []
        private var name: String?
        private var blocks: [Block] = []
        private var paragraph: [String] = []
        private var code: [String]?

        mutating func read(_ line: String) {
            if code != nil {
                readCode(line)
                return
            }

            if line.hasPrefix("```") {
                endParagraph()
                code = []
                return
            }

            if line.hasPrefix("## ") {
                endSection()
                name = String(line.dropFirst(3))
                return
            }

            if line.hasPrefix("### ") {
                endParagraph()
                blocks.append(.heading(String(line.dropFirst(4))))
                return
            }

            if line.hasPrefix("|") {
                ThirdPartyNotices.project(inRow: line).map { projects.append($0) }
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || ThirdPartyNotices.startsListItem(line) {
                endParagraph()
            }

            if !trimmed.isEmpty {
                paragraph.append(trimmed)
            }
        }

        mutating func endSection() {
            endParagraph()

            if let name {
                sections.append(Section(name: name, blocks: blocks))
            }

            blocks = []
        }

        private mutating func readCode(_ line: String) {
            guard line.hasPrefix("```") else {
                code?.append(line)
                return
            }

            blocks.append(.text((code ?? []).joined(separator: "\n")))
            code = nil
        }

        private mutating func endParagraph() {
            if paragraph.isEmpty {
                return
            }

            blocks.append(.paragraph(ThirdPartyNotices.withoutLinksInFile(paragraph.joined(separator: " "))))
            paragraph = []
        }
    }
}
