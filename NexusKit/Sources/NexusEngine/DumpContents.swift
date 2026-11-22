import Foundation

// The objects of a dump of pg_dump -Fc, from pg_restore -l and from the script of
// pg_restore --clean.
struct DumpContents: Sendable, Equatable {
    struct Statement: Sendable, Equatable {
        let text: String
        let kind: String?
        let name: String

        private static let relationKinds: Set<String> = ["TABLE", "FOREIGN TABLE", "VIEW", "MATERIALIZED VIEW", "SEQUENCE", "INDEX"]

        var relation: String? {
            kind.flatMap { Self.relationKinds.contains($0) ? name : nil }
        }

        init(_ text: String) {
            let match = text.wholeMatch(of: /DROP ([A-Z ]+?) IF EXISTS (.+);/)
            self.text = text
            kind = match.map { String($0.1) }
            name = match.map { String($0.2) } ?? ""
        }
    }

    struct Entry: Sendable, Equatable {
        let id: Int
        let rest: String
    }

    let statements: [Statement]
    let entries: [Entry]
    private let lines: [String]

    init(list: String, script: String) {
        lines = list.split(whereSeparator: \.isNewline).map(String.init)
        entries = lines.compactMap { line in
            line.wholeMatch(of: /([0-9]+); [0-9]+ [0-9]+ (.+)/).map { Entry(id: Int($0.1) ?? 0, rest: String($0.2)) }
        }
        statements = Self.dropStatements(in: script).map(Statement.init)
    }

    // The drop statements come before the first object. A view that needs the primary key of a table
    // first becomes a view without that need, in a statement of more than one line.
    static func dropStatements(in script: String) -> [String] {
        var statements: [String] = []
        var current: [Substring] = []

        for line in script.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-- Name:") {
                break
            }

            if current.isEmpty, !["DROP ", "ALTER ", "CREATE OR REPLACE VIEW "].contains(where: line.hasPrefix) {
                continue
            }

            current.append(line)

            if line.hasSuffix(";") {
                statements.append(current.joined(separator: "\n"))
                current = []
            }
        }

        return statements
    }

    // pg_restore drops the objects in the opposite order of its list. A dump of only the schema public
    // drops that schema. Other dumps have it in the list without a drop.
    func entry(of number: Int) -> Int? {
        let statement = statements[number]

        guard let kind = statement.kind else {
            return nil
        }

        let drops = statements.indices.filter { statements[$0].kind == kind }
        let dropsPublic = statements.contains { $0.text == "DROP SCHEMA IF EXISTS public;" }
        let sameKind = entries.filter { Self.kind(of: $0.rest) == kind && (dropsPublic || !$0.rest.hasPrefix("SCHEMA - public ")) }

        guard drops.count == sameKind.count, let position = drops.firstIndex(of: number) else {
            return nil
        }

        return sameKind[sameKind.count - 1 - position].id
    }

    // The list for pg_restore -L without these entries and without the rows of these tables.
    func useList(without kept: Set<Int>, rows: Set<String>) -> String {
        let left = Set(rows.map { "TABLE DATA \($0)" })
        let excluded = kept.union(entries.filter { left.contains($0.rest) }.map(\.id))

        return lines.filter { line in
            line.prefixMatch(of: /([0-9]+);/).flatMap { Int($0.1) }.map { !excluded.contains($0) } ?? false
        }
        .joined(separator: "\n") + "\n"
    }

    var rowsWithoutTable: [String] {
        let tables = Set(rests(after: "TABLE "))
        return rests(after: "TABLE DATA ").filter { !tables.contains($0) }
    }

    private func rests(after prefix: String) -> [String] {
        entries.filter { $0.rest.hasPrefix(prefix) }.map { String($0.rest.dropFirst(prefix.count)) }
    }

    private static let longKinds = [
        "OPERATOR CLASS", "OPERATOR FAMILY", "TEXT SEARCH PARSER", "TEXT SEARCH DICTIONARY", "TEXT SEARCH TEMPLATE",
        "TEXT SEARCH CONFIGURATION", "ACCESS METHOD", "FOREIGN DATA WRAPPER", "PROCEDURAL LANGUAGE",
    ]

    private static func kind(of rest: String) -> String {
        longKinds.first { rest.hasPrefix("\($0) ") } ?? String(rest.prefix { $0 != " " })
    }
}
