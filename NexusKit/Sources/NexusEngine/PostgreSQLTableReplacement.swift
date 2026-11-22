import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// "Replace only the tables" with a dump of pg_dump -Fc (owner, 2026-11-22). pg_restore drops each
// object of the dump and goes on after an error. When another object of the database uses a table
// of the dump, PostgreSQL keeps the old table and pg_restore adds the new rows to the old rows. So
// Nexus first runs the drop statements in a transaction that it does not commit.
struct PostgreSQLTableReplacement: Sendable, Equatable {
    static let nothingBlocked = PostgreSQLTableReplacement()

    // What PostgreSQL says about a table that it cannot replace.
    var conflicts: [String] = []

    // The tables with rows in the dump and no definition in the dump.
    var tablesWithoutDefinition: [String] = []

    // The extensions, types, functions and other shared objects that the database uses. pg_restore
    // leaves them out, so they stay as they were.
    var kept: [String] = []
    var useList: String?

    // Drop statements that fail although the old table goes away, for example the default of a
    // column that the old table does not have. pg_restore may report each of them one time.
    var harmlessCommands: [String] = []

    private static let sharedKinds: Set<String> = [
        "EXTENSION", "SCHEMA", "TYPE", "DOMAIN", "FUNCTION", "PROCEDURE", "AGGREGATE", "OPERATOR", "OPERATOR CLASS",
        "OPERATOR FAMILY", "COLLATION", "CONVERSION", "CAST", "TEXT SEARCH PARSER", "TEXT SEARCH DICTIONARY",
        "TEXT SEARCH TEMPLATE", "TEXT SEARCH CONFIGURATION", "ACCESS METHOD", "FOREIGN DATA WRAPPER", "SERVER",
        "PROCEDURAL LANGUAGE",
    ]

    private static let dependentObjectsStillExist = "2BP01"

    func conflictText(dump: String, database: String) -> String? {
        let advice = "Nothing changed. Replace the whole database or load the dump into another database."

        if !tablesWithoutDefinition.isEmpty {
            return "Nexus cannot replace only the tables of \(dump). The dump has rows without the definition of these tables: \(Self.short(tablesWithoutDefinition)). \(advice)"
        }

        guard !conflicts.isEmpty else {
            return nil
        }

        return "Nexus cannot replace only the tables of \(dump). Other parts of \(database) use them: \(Self.short(conflicts)). \(advice)"
    }

    func keptText(database: String) -> String {
        kept.isEmpty ? "" : " These stay as they were because other parts of \(database) use them: \(Self.short(kept))."
    }

    // pg_restore names the first line of the command of each error. Its last line gives the number of
    // errors.
    func explains(_ output: String) -> Bool {
        let commands = output.matches(of: /Command was: (.+)/).map { String($0.1) }

        guard !commands.isEmpty, let count = output.matches(of: /errors ignored on restore: ([0-9]+)/).last.flatMap({ Int($0.1) }), count == commands.count else {
            return false
        }

        var allowed = harmlessCommands

        return commands.allSatisfy { command in
            guard let index = allowed.firstIndex(of: command) else {
                return false
            }

            allowed.remove(at: index)
            return true
        }
    }

    static func check(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools) async throws -> PostgreSQLTableReplacement {
        let list = try await restoreOutput(of: plan, arguments: ["-l"], client: client, tools: tools)
        let script = try await restoreOutput(of: plan, arguments: ["--clean", "--if-exists", "--schema-only", "--no-owner", "--no-privileges", "-f", "-"], client: client, tools: tools)
        let contents = DumpContents(list: list, script: script)
        let sql = checkScript(contents)

        do {
            let answer = DatabaseClient.rows(in: try await client.output(ofScript: sql, database: plan.name))
            return PostgreSQLTableReplacement(contents: contents, answer: answer)
        } catch CommandError.failed(_, _, let output) where output.contains("lock timeout") {
            throw RuntimeError.unsupported("Another program uses a table of \(plan.name) now. Close its connection and import the dump again. Nothing changed.")
        } catch CommandError.failed(_, _, let output) where output.contains("out of shared memory") {
            throw RuntimeError.unsupported("The dump has too many tables to check them in one step. Nothing changed. Replace the whole database or load the dump into another database.")
        }
    }

    private static func restoreOutput(of plan: DumpLoad, arguments: [String], client: DatabaseClient, tools: DatabaseTools) async throws -> String {
        let file = client.options.deletingLastPathComponent().appending(path: "restore-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported("Nexus cannot write \(file.path(percentEncoded: false)).")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        try await CommandRunner.pipe(
            NexusEngine.reader(of: plan.file, container: plan.container, dump: plan.dump),
            into: Command(executable: tools.bin("pg_restore"), arguments: arguments),
            writingTo: file
        )

        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    // psql leaves the transaction open and closes the connection. So PostgreSQL rolls it back. The
    // check is no task that the user can stop. So it does not wait for a lock of another program.
    static func checkScript(_ contents: DumpContents) -> String {
        let tag = "$nexus\(UUID().uuidString.filter { $0 != "-" })$"
        let quoted = { (text: String) in "\(tag)\(text)\(tag)" }
        let statements = contents.statements.enumerated().map { number, statement in
            "(\(number), \(quoted(statement.text)), \(statement.relation.map(quoted) ?? "NULL"))"
        }
        let rows = contents.rowsWithoutTable.map { "(\(quoted($0)))" }

        return """
            BEGIN;
            SET LOCAL client_min_messages = error;
            SET LOCAL search_path = '';
            SET LOCAL lock_timeout = '5s';
            CREATE TEMP TABLE nexus_statements (number int, statement text, relation text, relation_oid oid, state text, detail text);
            CREATE TEMP TABLE nexus_rows (entry text);
            \(statements.isEmpty ? "" : "INSERT INTO pg_temp.nexus_statements (number, statement, relation) VALUES\n\(statements.joined(separator: ",\n"));")
            \(rows.isEmpty ? "" : "INSERT INTO pg_temp.nexus_rows VALUES\n\(rows.joined(separator: ",\n"));")
            UPDATE pg_temp.nexus_statements SET relation_oid = pg_catalog.to_regclass(relation);
            CREATE TEMP TABLE nexus_relations AS
                SELECT class.oid, class.oid::pg_catalog.regclass::text AS name,
                    (SELECT inhparent::pg_catalog.regclass::text FROM pg_catalog.pg_inherits WHERE inhrelid = class.oid LIMIT 1) AS parent
                FROM pg_catalog.pg_class class JOIN pg_catalog.pg_namespace schema ON schema.oid = class.relnamespace
                WHERE class.relkind IN ('r', 'p', 'f', 'v', 'm') AND schema.nspname NOT LIKE 'pg\\_%' AND schema.nspname <> 'information_schema';
            SELECT 'rows', class.oid::pg_catalog.regclass
                FROM pg_temp.nexus_rows entries, pg_catalog.pg_class class JOIN pg_catalog.pg_namespace schema ON schema.oid = class.relnamespace
                WHERE class.relkind IN ('r', 'p') AND pg_catalog.starts_with(entries.entry, schema.nspname || ' ' || class.relname || ' ')
                    AND NOT EXISTS (SELECT FROM pg_catalog.pg_depend WHERE classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND objid = class.oid AND deptype = 'e');
            DO $nexus_check$
            DECLARE
                entry record;
                found_state text;
                found_detail text;
                found_message text;
            BEGIN
                FOR entry IN SELECT * FROM pg_temp.nexus_statements ORDER BY number LOOP
                    BEGIN
                        EXECUTE entry.statement;
                    EXCEPTION
                        WHEN out_of_memory OR lock_not_available OR deadlock_detected THEN
                            RAISE;
                        WHEN OTHERS THEN
                            GET STACKED DIAGNOSTICS found_state = RETURNED_SQLSTATE, found_detail = PG_EXCEPTION_DETAIL, found_message = MESSAGE_TEXT;
                            UPDATE pg_temp.nexus_statements
                                SET state = found_state, detail = pg_catalog.translate(COALESCE(NULLIF(found_detail, ''), found_message), E'\\n\\t', pg_catalog.chr(31) || ' ')
                                WHERE number = entry.number;
                    END;
                END LOOP;
            END
            $nexus_check$;
            SELECT 'statement', number, state, EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid = relation_oid), detail
                FROM pg_temp.nexus_statements WHERE state IS NOT NULL ORDER BY number;
            SELECT 'lost', name, parent FROM pg_temp.nexus_relations relations
                WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid = relations.oid)
                    AND NOT EXISTS (SELECT FROM pg_temp.nexus_statements WHERE relation_oid = relations.oid);

            """
    }

    init() {}

    // Each row has its kind first: a table without a definition, a statement that failed, or a
    // relation that goes away although the dump does not have it.
    init(contents: DumpContents, answer: [[String]]) {
        var keptEntries: Set<Int> = []

        for row in answer {
            switch row.first {
            case "rows" where row.count == 2:
                tablesWithoutDefinition.append(Self.shown(row[1]))
            case "lost" where row.count == 3:
                conflicts.append("table \(Self.shown(row[1])) is a partition of table \(Self.shown(row[2]))")
            case "statement" where row.count >= 5:
                guard let number = Int(row[1]), contents.statements.indices.contains(number) else {
                    continue
                }

                let statement = contents.statements[number]
                let users = row[4].split(separator: "\u{1F}").map { Self.shown(String($0)) }

                if statement.relation != nil, row[3] == "t" {
                    conflicts += users.filter { !conflicts.contains($0) }
                    continue
                }

                guard let kind = statement.kind, Self.sharedKinds.contains(kind) else {
                    harmlessCommands.append(statement.firstLine)
                    continue
                }

                guard row[2] == Self.dependentObjectsStillExist, let entry = contents.entry(of: number) else {
                    conflicts += users.filter { !conflicts.contains($0) }
                    continue
                }

                kept.append("\(kind.lowercased()) \(Self.shown(statement.name))")
                keptEntries.insert(entry)
            default:
                continue
            }
        }

        if !keptEntries.isEmpty {
            useList = contents.useList(without: keptEntries)
        }
    }

    // PostgreSQL names at most 100 objects and then gives a line such as "and 20 other objects".
    private static func short(_ names: [String]) -> String {
        let counts = names.compactMap { $0.prefixMatch(of: /and ([0-9]+) other object/).flatMap { Int($0.1) } }
        let named = names.filter { $0.prefixMatch(of: /and [0-9]+ other object/) == nil }
        let more = max(named.count - 3, 0) + counts.reduce(0, +)

        return named.prefix(3).joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }

    private static func shown(_ name: String) -> String {
        name.replacing(/(^|[ (,\[])public\./) { String($0.1) }
    }
}

// The objects of a dump, from pg_restore -l and from the script of pg_restore --clean.
struct DumpContents: Sendable, Equatable {
    struct Statement: Sendable, Equatable {
        let text: String
        let kind: String?
        let name: String

        private static let relationKinds: Set<String> = ["TABLE", "FOREIGN TABLE", "VIEW", "MATERIALIZED VIEW", "SEQUENCE"]

        var relation: String? {
            kind.flatMap { Self.relationKinds.contains($0) ? name : nil }
        }

        var firstLine: String {
            String(text.prefix { !$0.isNewline })
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

    // pg_restore drops the objects in the opposite order of its list. The schema public has no drop.
    func entry(of number: Int) -> Int? {
        let statement = statements[number]

        guard let kind = statement.kind else {
            return nil
        }

        let drops = statements.indices.filter { statements[$0].kind == kind }
        let sameKind = entries.filter { Self.kind(of: $0.rest) == kind && !$0.rest.hasPrefix("SCHEMA - public ") }

        guard drops.count == sameKind.count, let position = drops.firstIndex(of: number) else {
            return nil
        }

        return sameKind[sameKind.count - 1 - position].id
    }

    // The rows of a table that only an extension makes have no table in the dump. When the extension
    // stays, its rows stay too.
    func useList(without kept: Set<Int>) -> String {
        let keepsExtension = entries.contains { kept.contains($0.id) && $0.rest.hasPrefix("EXTENSION ") }
        let left = keepsExtension ? Set(rowsWithoutTable.map { "TABLE DATA \($0)" }) : []
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
