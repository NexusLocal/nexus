import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// "Replace only the tables" with a dump of pg_dump -Fc (owner, 2026-11-22). pg_restore drops each
// object of the dump and goes on after an error. When another object of the database uses a table
// of the dump, PostgreSQL keeps the old table and pg_restore adds the new rows to the old rows. So
// Nexus first runs the drop statements in a transaction that it does not commit.
struct PostgreSQLTableReplacement: Sendable, Equatable {
    static let nothingBlocked = PostgreSQLTableReplacement(blocked: [])

    // What uses a table, a view or a sequence of the dump.
    let conflicts: [String]

    // The extensions, types, functions and schemas that other objects use. They stay as they were.
    let kept: [String]

    // The errors that pg_restore gives for the kept objects: one for the drop and one for the
    // create. An extension has no second error, because its statement has IF NOT EXISTS.
    let expectedErrors: Int

    private static let relationKinds: Set<String> = ["TABLE", "FOREIGN TABLE", "VIEW", "MATERIALIZED VIEW", "SEQUENCE"]
    private static let keptKinds: Set<String> = ["EXTENSION", "SCHEMA", "TYPE", "DOMAIN", "FUNCTION", "PROCEDURE", "AGGREGATE"]

    // Each row has the statement that PostgreSQL refuses and the lines of its detail.
    init(blocked rows: [[String]]) {
        var conflicts: [String] = []
        var kept: [String] = []
        var expectedErrors = 0

        for row in rows {
            guard let statement = row.first, let match = statement.wholeMatch(of: /DROP ([A-Z ]+?) IF EXISTS (.+);/) else {
                continue
            }

            let kind = String(match.1)

            if Self.relationKinds.contains(kind) {
                let users = row.dropFirst().joined().split(separator: "\u{1F}").map { Self.shown(String($0)) }
                conflicts += users.filter { !conflicts.contains($0) }
                continue
            }

            if Self.keptKinds.contains(kind) {
                kept.append("\(kind.lowercased()) \(Self.shown(String(match.2)))")
                expectedErrors += kind == "EXTENSION" ? 1 : 2
            }
        }

        self.conflicts = conflicts
        self.kept = kept
        self.expectedErrors = expectedErrors
    }

    func conflictText(dump: String, database: String) -> String? {
        guard !conflicts.isEmpty else {
            return nil
        }

        let shown = conflicts.prefix(3).joined(separator: ", ")
        let more = conflicts.count > 3 ? " and \(conflicts.count - 3) more" : ""
        return "Nexus cannot replace only the tables of \(dump). Other parts of \(database) use them: \(shown)\(more). Nothing changed. Replace the whole database or load the dump into another database."
    }

    func keptText(database: String) -> String {
        kept.isEmpty ? "" : " These stay as they were because other parts of \(database) use them: \(kept.joined(separator: ", "))."
    }

    // The last line of pg_restore gives the number of errors. Without that line the restore stopped
    // for another reason.
    func explains(_ output: String) -> Bool {
        guard expectedErrors > 0, let match = output.matches(of: /errors ignored on restore: ([0-9]+)/).last else {
            return false
        }

        return Int(match.1) == expectedErrors
    }

    // The statements that pg_restore --clean runs before it makes the objects again. They come
    // before the first object in the script.
    static func dropStatements(of plan: DumpLoad, restore: URL) async throws -> [String] {
        let script = "( \(plan.container.readerScript(dump: plan.dump)) ) 2>/dev/null"
            + #" | "$PG_RESTORE" --clean --if-exists --schema-only --no-owner --no-privileges -f - 2>/dev/null"#
            + #" | LC_ALL=C /usr/bin/awk '/^-- Name:/ { exit } /^(DROP|ALTER) .*;$/ { print }'; exit 0"#
        let output = try await CommandRunner.run(Command(
            executable: URL(filePath: "/bin/bash"),
            arguments: ["-c", script, "reader", plan.file.path(percentEncoded: false)] + (plan.dump.map { [$0] } ?? []),
            environment: ["PG_RESTORE": restore.path(percentEncoded: false)]
        ))

        return output.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
    }

    // psql leaves the transaction open and closes the connection. So PostgreSQL rolls it back. The
    // check is no task that the user can stop. So it does not wait for a lock of another program.
    static func checkScript(_ statements: [String]) -> String {
        let tag = "$nexus\(UUID().uuidString.filter { $0 != "-" })$"
        let list = statements.map { "\(tag)\($0)\(tag)" }.joined(separator: ",\n")

        return """
            BEGIN;
            SET LOCAL client_min_messages = error;
            SET LOCAL search_path = '';
            SET LOCAL lock_timeout = '5s';
            CREATE TEMP TABLE nexus_blocked (statement text, detail text);
            DO $nexus_check$
            DECLARE
                statement text;
                detail text;
            BEGIN
                FOREACH statement IN ARRAY ARRAY[
            \(list)
                ]::text[] LOOP
                    BEGIN
                        EXECUTE statement;
                    EXCEPTION
                        WHEN dependent_objects_still_exist THEN
                            GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
                            INSERT INTO pg_temp.nexus_blocked VALUES (statement, replace(detail, chr(10), chr(31)));
                        WHEN lock_not_available THEN
                            RAISE;
                        WHEN OTHERS THEN
                            NULL;
                    END;
                END LOOP;
            END
            $nexus_check$;
            SELECT statement, detail FROM pg_temp.nexus_blocked;

            """
    }

    static func check(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools) async throws -> PostgreSQLTableReplacement {
        let statements = try await dropStatements(of: plan, restore: tools.bin("pg_restore"))

        guard !statements.isEmpty else {
            return .nothingBlocked
        }

        do {
            return PostgreSQLTableReplacement(blocked: DatabaseClient.rows(in: try await client.output(ofScript: checkScript(statements), database: plan.name)))
        } catch CommandError.failed(_, _, let output) where output.contains("lock timeout") {
            throw RuntimeError.unsupported("Another program uses a table of \(plan.name) now. Close its connection and import the dump again. Nothing changed.")
        }
    }

    private static func shown(_ name: String) -> String {
        name.replacingOccurrences(of: "public.", with: "")
    }
}
