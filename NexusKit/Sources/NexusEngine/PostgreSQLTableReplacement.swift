import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// "Replace only the tables" with a dump of pg_dump -Fc (owner, 2026-11-22). pg_restore --clean goes
// on after an error. When another object of the database uses a table of the dump, PostgreSQL keeps
// the old table and pg_restore adds the new rows to the old rows. So Nexus runs the drop statements
// itself. The check runs them in a transaction that it does not commit. The load runs them again in
// one transaction with the rest of the dump, so an error leaves the database as it was.
struct PostgreSQLTableReplacement: Sendable, Equatable {
    // What uses a table of the dump.
    var conflicts: [String] = []

    // Why PostgreSQL cannot drop an object that nothing uses.
    var refusals: [String] = []

    // The tables with rows in the dump and no definition in the dump.
    var tablesWithoutDefinition: [String] = []

    // The extensions, types, functions and other shared objects that the database uses. The load
    // leaves them out, so they stay as they were.
    var kept: [String] = []
    var useList: String?
    var script = ""

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

        if !conflicts.isEmpty {
            return "Nexus cannot replace only the tables of \(dump). Other parts of \(database) use them: \(Self.short(conflicts)). \(advice)"
        }

        guard !refusals.isEmpty else {
            return nil
        }

        return "Nexus cannot replace only the tables of \(dump). PostgreSQL cannot drop the old objects: \(Self.short(refusals)). \(advice)"
    }

    func keptText(database: String) -> String {
        kept.isEmpty ? "" : " These stay as they were because other parts of \(database) use them: \(Self.short(kept))."
    }

    static func check(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools) async throws -> PostgreSQLTableReplacement {
        let contents = DumpContents(
            list: try await restoreOutput(of: plan, "-l", tools: tools),
            script: try await restoreOutput(of: plan, "--clean --if-exists --no-owner --no-privileges -f - 2>/dev/null | /usr/bin/awk '/^-- Name:/ { exit } { print }'", tools: tools)
        )

        do {
            let answer = DatabaseClient.rows(in: try await client.output(ofScript: checkScript(contents), database: plan.name))
            return PostgreSQLTableReplacement(contents: contents, answer: answer)
        } catch CommandError.failed(_, _, let output) where output.contains("lock timeout") {
            throw RuntimeError.unsupported("Another program uses a table of \(plan.name) now. Close its connection and import the dump again. Nothing changed.")
        } catch CommandError.failed(_, _, let output) where output.contains(lockTableIsFull) {
            throw RuntimeError.unsupported(tooManyTables)
        }
    }

    static let lockTableIsFull = "out of shared memory"
    static let tooManyTables = "The dump has too many tables to replace them in one step. Nothing changed. Replace the whole database or load the dump into another database."

    // pg_restore stops before the end of its input. So only its own exit status counts. The script
    // has the rows of the dump too, so it ends at the first object. The list already shows that
    // pg_restore can read the dump.
    private static func restoreOutput(of plan: DumpLoad, _ options: String, tools: DatabaseTools) async throws -> String {
        try await CommandRunner.run(Command(
            executable: URL(filePath: "/bin/bash"),
            arguments: ["-c", "( \(plan.container.readerScript(dump: plan.dump)) ) 2>/dev/null | \"$PG_RESTORE\" \(options)", "reader", plan.file.path(percentEncoded: false)] + (plan.dump.map { [$0] } ?? []),
            environment: ["PG_RESTORE": tools.bin("pg_restore").path(percentEncoded: false)],
            name: "pg_restore"
        ))
        .standardOutput
    }

    // Each row has its kind first: a table without a definition, the extension of a table without a
    // definition, a statement that failed, or an object that goes away although it should stay.
    init(contents: DumpContents, answer: [[String]]) {
        var keptNumbers: Set<Int> = []
        var keptEntries: Set<Int> = []
        var keptExtensions: Set<String> = []
        var extensionRows: [String: String] = [:]

        for row in answer {
            switch row.first {
            case "rows" where row.count == 2:
                tablesWithoutDefinition.append(Self.shown(row[1]))
            case "extension" where row.count == 3:
                extensionRows[row[1]] = row[2]
            case "lost" where row.count == 4:
                conflicts.append(Self.lostText(kind: row[1], name: Self.shown(row[2]), parent: Self.shown(row[3])))
            case "statement" where row.count >= 5:
                guard let number = Int(row[1]), contents.statements.indices.contains(number) else {
                    continue
                }

                let statement = contents.statements[number]
                let shared = statement.kind.map(Self.sharedKinds.contains) ?? false
                let inUse = row[2] == Self.dependentObjectsStillExist

                if shared, inUse, !statement.cascades, let entry = contents.entry(of: number) {
                    kept.append("\(statement.kind?.lowercased() ?? "") \(Self.shown(statement.name))")
                    keptNumbers.insert(number)
                    keptEntries.insert(entry)

                    if statement.kind == "EXTENSION" {
                        keptExtensions.insert(statement.name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    }

                    continue
                }

                // The other statements are about a part of a table, and the table goes away. When such
                // a part stays, the load fails and changes nothing.
                if shared || (statement.relation != nil && row[3] == "t") {
                    let causes = row[4].split(separator: "\u{1F}").map { Self.shown(String($0)) }

                    if inUse {
                        conflicts += causes.filter { !conflicts.contains($0) }
                    } else {
                        refusals += causes.filter { !refusals.contains($0) }
                    }
                }
            default:
                continue
            }
        }

        // The rows of an extension stay when the load does not make that extension again.
        let newExtensions = Set(contents.statements.filter { $0.kind == "EXTENSION" }.map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }).subtracting(keptExtensions)
        let keptRows = Set(extensionRows.filter { !newExtensions.contains($0.value) }.keys)
        useList = keptEntries.isEmpty && keptRows.isEmpty ? nil : contents.useList(without: keptEntries, rows: keptRows)
        script = Self.loadScript(contents, skipping: keptNumbers)
    }

    private static func lostText(kind: String, name: String, parent: String) -> String {
        if kind == "index" {
            return "index \(name) belongs to table \(parent)"
        }

        return parent == "-" ? "\(name) goes away with them" : "table \(name) is a partition of table \(parent)"
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

extension PostgreSQLTableReplacement {
    // psql leaves the transaction open and closes the connection. So PostgreSQL rolls it back. The
    // check is no task that the user can stop. So it does not wait for a lock of another program.
    static func checkScript(_ contents: DumpContents) -> String {
        """
        BEGIN;
        SET LOCAL lock_timeout = '5s';
        \(snapshot(contents, skipping: []))
        \(rowsWithoutTable(contents))
        \(drops)
        SELECT 'statement', number, state, EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid = relation_oid), detail
            FROM pg_temp.nexus_statements WHERE state IS NOT NULL ORDER BY number;
        SELECT 'lost', kind, name, COALESCE(parent, '-') FROM (\(lost)) AS lost;

        """
    }

    // The script of pg_restore -1 comes after this script in the same session. It ends with COMMIT.
    static func loadScript(_ contents: DumpContents, skipping: Set<Int>) -> String {
        """
        BEGIN;
        \(snapshot(contents, skipping: skipping))
        \(drops)
        DO $nexus_verify$
        BEGIN
            IF EXISTS (SELECT FROM pg_temp.nexus_statements JOIN pg_catalog.pg_class class ON class.oid = relation_oid) OR EXISTS (\(lost)) THEN
                RAISE EXCEPTION 'Another program changed the database during the import.';
            END IF;
        END
        $nexus_verify$;
        DROP TABLE pg_temp.nexus_statements, pg_temp.nexus_relations;

        """
    }

    private static func quote() -> (String) -> String {
        let tag = "$nexus\(UUID().uuidString.filter { $0 != "-" })$"
        return { "\(tag)\($0)\(tag)" }
    }

    // The drop statements, and the tables, views and indexes of the database before the drops. An
    // object of an extension goes away and comes back with its extension.
    private static func snapshot(_ contents: DumpContents, skipping: Set<Int>) -> String {
        let quoted = quote()
        let statements = contents.statements.enumerated().filter { !skipping.contains($0.offset) }.map { number, statement in
            "(\(number), \(quoted(statement.text)), \(statement.relation.map(quoted) ?? "NULL"))"
        }

        return """
            SET LOCAL client_min_messages = error;
            SET LOCAL search_path = '';
            CREATE TEMP TABLE nexus_statements (number int, statement text, relation text, relation_oid oid, done boolean NOT NULL DEFAULT false, state text, detail text);
            \(statements.isEmpty ? "" : "INSERT INTO pg_temp.nexus_statements (number, statement, relation) VALUES\n\(statements.joined(separator: ",\n"));")
            UPDATE pg_temp.nexus_statements SET relation_oid = pg_catalog.to_regclass(relation);
            CREATE TEMP TABLE nexus_relations AS
                SELECT class.oid, 'table' AS kind, class.oid::pg_catalog.regclass::text AS name, parent.oid AS parent_oid, parent.oid::pg_catalog.regclass::text AS parent
                FROM pg_catalog.pg_class class JOIN pg_catalog.pg_namespace schema ON schema.oid = class.relnamespace
                    LEFT JOIN pg_catalog.pg_inherits inherits ON inherits.inhrelid = class.oid AND inherits.inhseqno = 1
                    LEFT JOIN pg_catalog.pg_class parent ON parent.oid = inherits.inhparent
                WHERE class.relkind IN ('r', 'p', 'f', 'v', 'm') AND schema.nspname NOT LIKE 'pg\\_%' AND schema.nspname <> 'information_schema'
                    AND NOT EXISTS (SELECT FROM pg_catalog.pg_depend WHERE classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND objid = class.oid AND deptype = 'e')
                UNION ALL
                SELECT indexes.indexrelid, 'index', indexes.indexrelid::pg_catalog.regclass::text, indexes.indrelid, indexes.indrelid::pg_catalog.regclass::text
                FROM pg_catalog.pg_index indexes JOIN pg_catalog.pg_class class ON class.oid = indexes.indexrelid
                    JOIN pg_catalog.pg_namespace schema ON schema.oid = class.relnamespace
                WHERE schema.nspname NOT LIKE 'pg\\_%';
            """
    }

    private static func rowsWithoutTable(_ contents: DumpContents) -> String {
        let quoted = quote()
        let rows = contents.rowsWithoutTable.map { "(\(quoted($0)))" }

        guard !rows.isEmpty else {
            return ""
        }

        return """
            CREATE TEMP TABLE nexus_rows AS
                SELECT entry, class.oid AS table_oid, extension.extname
                FROM (VALUES \(rows.joined(separator: ", "))) AS rows (entry)
                    JOIN pg_catalog.pg_namespace schema ON pg_catalog.starts_with(entry, schema.nspname || ' ')
                    JOIN pg_catalog.pg_class class ON class.relnamespace = schema.oid AND class.relkind IN ('r', 'p') AND pg_catalog.starts_with(entry, schema.nspname || ' ' || class.relname || ' ')
                    LEFT JOIN pg_catalog.pg_depend depend ON depend.classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND depend.objid = class.oid AND depend.objsubid = 0 AND depend.deptype = 'e'
                    LEFT JOIN pg_catalog.pg_extension extension ON extension.oid = depend.refobjid;
            SELECT 'rows', table_oid::pg_catalog.regclass FROM pg_temp.nexus_rows WHERE extname IS NULL;
            SELECT 'extension', entry, extname FROM pg_temp.nexus_rows WHERE extname IS NOT NULL;
            """
    }

    // The database can have a foreign key between two tables of the dump that the dump does not have.
    // Other uses that the dump does not know need another order, so a drop of an object in use runs
    // again after the drops that worked.
    private static let drops = """
        DO $nexus_drops$
        DECLARE
            entry record;
            worked boolean;
            found_state text;
            found_detail text;
            found_message text;
        BEGIN
            FOR entry IN SELECT conrelid::pg_catalog.regclass AS relation, conname FROM pg_catalog.pg_constraint
                WHERE contype = 'f' AND conparentid = 0
                    AND conrelid IN (SELECT relation_oid FROM pg_temp.nexus_statements) AND confrelid IN (SELECT relation_oid FROM pg_temp.nexus_statements) LOOP
                EXECUTE pg_catalog.format('ALTER TABLE %s DROP CONSTRAINT %I', entry.relation, entry.conname);
            END LOOP;
            LOOP
                worked := false;
                FOR entry IN SELECT * FROM pg_temp.nexus_statements WHERE NOT done AND (state IS NULL OR state = '2BP01') ORDER BY number LOOP
                    BEGIN
                        EXECUTE entry.statement;
                        UPDATE pg_temp.nexus_statements SET done = true, state = NULL, detail = NULL WHERE number = entry.number;
                        worked := true;
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
                EXIT WHEN NOT worked OR NOT EXISTS (SELECT FROM pg_temp.nexus_statements WHERE state = '2BP01');
            END LOOP;
        END
        $nexus_drops$;
        """

    // A table or a view that goes away although the dump does not have it, and an index or a partition
    // that goes away while its table stays.
    private static let lost = """
        SELECT kind, name, parent FROM pg_temp.nexus_relations relations
            WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid = relations.oid)
                AND (EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid = relations.parent_oid)
                    OR (kind = 'table' AND NOT EXISTS (SELECT FROM pg_temp.nexus_statements WHERE relation_oid = relations.oid)))
        """
}
