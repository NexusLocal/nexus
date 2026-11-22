import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

struct PostgreSQLTableReplacementTests {
    private let list = """
        ;
        ; Archive created at 2026-11-22
        ;
        4; 2615 2200 SCHEMA - public postgres
        5; 2615 16386 SCHEMA - x postgres
        2; 3079 16387 EXTENSION - citext
        3; 3079 16388 EXTENSION - postgis
        900; 1247 16500 TYPE public mood postgres
        901; 1247 16501 TYPE public size postgres
        240; 1255 16502 FUNCTION public total(public.mood, text) postgres
        220; 1259 16510 TABLE public users postgres
        221; 1259 16511 TABLE public Odd Name postgres
        3400; 0 16510 TABLE DATA public users postgres
        3401; 0 16600 TABLE DATA public spatial_ref_sys postgres
        """

    private let script = """
        --
        -- PostgreSQL database dump
        --

        SET statement_timeout = 0;
        SELECT pg_catalog.set_config('search_path', '', false);

        ALTER TABLE IF EXISTS ONLY public."Odd Name" DROP CONSTRAINT IF EXISTS odd_user_id_fkey;
        DROP INDEX IF EXISTS public.users_email;
        CREATE OR REPLACE VIEW public.active AS
        SELECT
            NULL::integer AS id,
            NULL::bigint AS total;
        ALTER TABLE IF EXISTS public.users ALTER COLUMN id DROP DEFAULT;
        DROP SEQUENCE IF EXISTS public.users_id_seq;
        DROP TABLE IF EXISTS public."Odd Name";
        DROP TABLE IF EXISTS public.users;
        DROP FUNCTION IF EXISTS public.total(a public.mood, b text);
        DROP TYPE IF EXISTS public.size;
        DROP TYPE IF EXISTS public.mood;
        DROP EXTENSION IF EXISTS postgis;
        DROP EXTENSION IF EXISTS citext;
        DROP SCHEMA IF EXISTS x;
        --
        -- Name: x; Type: SCHEMA; Schema: -; Owner: -
        --

        DROP TABLE this_is_no_drop;
        """

    private var contents: DumpContents { DumpContents(list: list, script: script) }

    private func number(_ text: String) -> String {
        String(contents.statements.firstIndex { $0.text == text } ?? -1)
    }

    private func failed(_ text: String, state: String = "2BP01", stays: Bool = false, detail: String) -> [String] {
        ["statement", number(text), state, stays ? "t" : "f", detail]
    }

    private func ids(_ useList: String?) -> [String] {
        (useList ?? "").split(separator: "\n").compactMap { $0.split(separator: ";").first.map(String.init) }
    }

    @Test func theDropStatementsEndBeforeTheFirstObjectAndAViewIsOneStatement() {
        #expect(contents.statements.count == 13)
        #expect(contents.statements[2].text == "CREATE OR REPLACE VIEW public.active AS\nSELECT\n    NULL::integer AS id,\n    NULL::bigint AS total;")
        #expect(contents.statements.compactMap(\.relation) == ["public.users_email", "public.users_id_seq", "public.\"Odd Name\"", "public.users"])
    }

    @Test func nothingBlockedDropsAllAndLeavesOutNothing() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [])

        #expect(replacement.conflictText(dump: "shop.dump", database: "shop") == nil)
        #expect(replacement.keptText(database: "shop") == "")
        #expect(replacement.useList == nil)
        #expect(replacement.script.contains("DROP TABLE IF EXISTS public.users;"))
    }

    @Test func aForeignKeyOrAViewOfAnotherTableStopsTheImport() throws {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            failed("DROP TABLE IF EXISTS public.users;", stays: true, detail: "constraint orders_user_id_fkey on table public.orders depends on table public.users\u{1F}view notpublic.report depends on table public.users"),
        ])

        let text = try #require(replacement.conflictText(dump: "shop.dump", database: "shop"))
        #expect(text == "Nexus cannot replace only the tables of shop.dump. Other parts of shop use them: constraint orders_user_id_fkey on table orders depends on table users, view notpublic.report depends on table users. Nothing changed. Replace the whole database or load the dump into another database.")
    }

    @Test func aLongListOfConflictsIsShort() throws {
        let users = (1...5).map { "view public.v\($0) depends on table public.users" } + ["and 20 other objects (see server log for list)"]
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [failed("DROP TABLE IF EXISTS public.users;", stays: true, detail: users.joined(separator: "\u{1F}"))])

        let text = try #require(replacement.conflictText(dump: "shop.dump", database: "shop"))
        #expect(text.contains("view v3 depends on table users and 22 more."))
        #expect(!text.contains("view v4"))
    }

    @Test func aPartitionOrAnIndexThatTheDumpDoesNotHaveStopsTheImport() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            ["lost", "table", "public.logs_2", "public.logs"],
            ["lost", "index", "public.users_email", "public.users_old"],
        ])

        #expect(replacement.conflicts == ["table logs_2 is a partition of table logs", "index users_email belongs to table users_old"])
    }

    @Test func rowsWithoutTheirTableStopTheImport() throws {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [["rows", "public.users"]])

        #expect(try #require(replacement.conflictText(dump: "shop.dump", database: "shop")).contains("The dump has rows without the definition of these tables: users."))
    }

    @Test func sharedObjectsStayAndLeaveTheList() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            ["extension", "public spatial_ref_sys postgres", "postgis"],
            failed("DROP FUNCTION IF EXISTS public.total(a public.mood, b text);", detail: "default value for column n of table public.kept depends on function"),
            failed("DROP TYPE IF EXISTS public.mood;", detail: "column m of table public.kept depends on type public.mood"),
            failed("DROP EXTENSION IF EXISTS citext;", detail: "column name of table public.kept depends on type public.citext"),
            failed("DROP SCHEMA IF EXISTS x;", detail: "table x.kept depends on schema x"),
        ])

        #expect(replacement.conflictText(dump: "shop.dump", database: "shop") == nil)
        #expect(replacement.kept == ["function total(a mood, b text)", "type mood", "extension citext", "schema x"])
        #expect(replacement.keptText(database: "shop") == " These stay as they were because other parts of shop use them: function total(a mood, b text), type mood, extension citext and 1 more.")
        #expect(ids(replacement.useList) == ["4", "3", "901", "220", "221", "3400", "3401"])
        #expect(!replacement.script.contains("DROP TYPE IF EXISTS public.mood;"))
        #expect(replacement.script.contains("DROP TYPE IF EXISTS public.size;"))
    }

    @Test func theRowsOfAnExtensionThatStaysStayToo() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            ["extension", "public spatial_ref_sys postgres", "postgis"],
            failed("DROP EXTENSION IF EXISTS postgis;", detail: "column place of table public.kept depends on type public.geometry"),
        ])

        #expect(ids(replacement.useList) == ["4", "5", "2", "900", "901", "240", "220", "221", "3400"])
    }

    @Test func theSchemaPublicStaysWhenTheDumpDropsIt() {
        let contents = DumpContents(list: list, script: script.replacingOccurrences(of: "DROP SCHEMA IF EXISTS x;", with: "DROP SCHEMA IF EXISTS x;\nDROP SCHEMA IF EXISTS public;"))
        let number = String(contents.statements.count - 1)
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [["statement", number, "2BP01", "f", "table public.kept depends on schema public"]])

        #expect(replacement.kept == ["schema public"])
        #expect(!ids(replacement.useList).contains("4"))
        #expect(ids(replacement.useList).contains("5"))
    }

    @Test func aSharedObjectOfAnotherKindInTheDatabaseStopsTheImport() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            failed("DROP TYPE IF EXISTS public.mood;", state: "42809", detail: "\"public.mood\" is a domain"),
        ])

        #expect(replacement.conflicts == ["\"public.mood\" is a domain"])
    }

    @Test func aDropThatFailsWhileItsTableGoesAwayIsNoConflict() {
        let replacement = PostgreSQLTableReplacement(contents: contents, answer: [
            failed("ALTER TABLE IF EXISTS public.users ALTER COLUMN id DROP DEFAULT;", state: "42703", detail: "column \"id\" does not exist"),
            failed("DROP SEQUENCE IF EXISTS public.users_id_seq;", detail: "cannot drop sequence because column id requires it"),
        ])

        #expect(replacement.conflicts.isEmpty)
        #expect(replacement.kept.isEmpty)
        #expect(replacement.useList == nil)
    }
}

extension NexusEngineTests {
    private static func hasRealRuntime(_ runtime: String) -> Bool {
        realRuntimes.map { FileManager.default.fileExists(atPath: "\($0)/\(runtime)/bin/pg_restore") } ?? false
    }

    @Test(.enabled(if: hasRealRuntime("postgresql/18")), .timeLimit(.minutes(3)))
    func theTablesOfARealPostgreSQLDumpReplaceOnlyTablesThatNothingElseUses() async throws {
        let id = "postgresql-18"
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths, ["postgresql/18"])

        var state = EngineState()
        state.ports[id] = freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            let tools = try #require(await engine.databaseRuntime(id))
            let work = paths.run.appending(path: "test", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let client = DatabaseClient(tools: tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: try await engine.port(of: tools), account: .newInstance), options: work.appending(path: "client.cnf"))

            let shared = "CREATE EXTENSION citext; CREATE EXTENSION pg_stat_statements; CREATE TYPE size AS ENUM ('s'); CREATE TYPE mood AS ENUM ('a', 'b'); CREATE FUNCTION f(m mood DEFAULT 'a') RETURNS int LANGUAGE sql AS 'SELECT 1'; CREATE SCHEMA x; CREATE COLLATION dutch (provider = icu, locale = 'nl');"
            let tables = "CREATE TABLE users (id serial PRIMARY KEY, name citext, m mood, s size, n int DEFAULT f(), c text COLLATE dutch, filler text); CREATE INDEX users_name ON users (name); CREATE TABLE x.notes (user_id int REFERENCES users); CREATE VIEW active AS SELECT id, name, count(*) AS total FROM users GROUP BY id; CREATE TABLE logs (day int) PARTITION BY RANGE (day); CREATE TABLE logs_1 PARTITION OF logs FOR VALUES FROM (1) TO (2);"
            let old = "INSERT INTO users (id, name) VALUES (9, 'Old');"

            func run(_ program: String, _ arguments: [String]) async throws {
                _ = try await CommandRunner.run(Command(executable: tools.bin(program), arguments: ["-h", "127.0.0.1", "-p", String(client.endpoint.port), "-U", client.endpoint.account.user] + arguments, environment: ["PGPASSWORD": client.endpoint.account.password]))
            }

            try await client.query("CREATE DATABASE source")
            try await client.query("\(shared) \(tables) INSERT INTO users (name, m) VALUES ('Ann', 'a'), ('Bob', 'b')", database: "source")
            let dump = work.appending(path: "source.dump")
            let rows = work.appending(path: "rows.dump")
            let onlyPublic = work.appending(path: "public.dump")
            try await run("pg_dump", ["-Fc", "-f", dump.path(percentEncoded: false), "source"])
            try await run("pg_dump", ["-Fc", "--data-only", "-f", rows.path(percentEncoded: false), "source"])

            try await client.query("CREATE DATABASE big")
            try await client.query("CREATE TABLE users (id int PRIMARY KEY, filler text); INSERT INTO users SELECT n, (SELECT string_agg(md5(random()::text), '') FROM generate_series(1, 20 + n * 0)) FROM generate_series(1, 20000) AS n", database: "big")
            let big = work.appending(path: "big.dump")
            try await run("pg_dump", ["-Fc", "-f", big.path(percentEncoded: false), "big"])
            try await run("pg_dump", ["-Fc", "-n", "public", "-f", onlyPublic.path(percentEncoded: false), "big"])
            let zip = work.appending(path: "big.zip")
            _ = try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/zip"), arguments: ["-q", "-j", zip.path(percentEncoded: false), big.path(percentEncoded: false)]))

            func load(_ file: URL, into name: String, _ setup: String) async throws -> (answer: NexusResponse, users: String) {
                try await client.query("CREATE DATABASE \(name)")
                try await client.query(setup, database: name)
                let answer = await engine.handle(.importDump(DumpImport(file: file.path(percentEncoded: false), target: .instance(id), name: name, existing: .replaceTables)))
                return (answer, try await client.query("SELECT CASE WHEN count(*) > 10 THEN count(*)::text ELSE string_agg(id::text, ',' ORDER BY id) END FROM users", database: name))
            }

            let same = "\(shared) \(tables) \(old)"
            let sharing = try await load(dump, into: "sharing", "\(same) CREATE TABLE kept (name citext, m mood, n int DEFAULT f(), c text COLLATE dutch); CREATE TABLE x.other (id int)")
            let replaced = [
                ("free", try await load(dump, into: "free", "\(same) CREATE TABLE kept (id int)"), "1,2"),
                ("sharing", sharing, "1,2"),
                ("older", try await load(dump, into: "older", "\(shared) CREATE TABLE users (id int GENERATED ALWAYS AS IDENTITY, note text); INSERT INTO users (note) VALUES ('old')"), "1,2"),
                ("noid", try await load(dump, into: "noid", "\(shared) CREATE TABLE users (note text)"), "1,2"),
                ("empty", try await load(dump, into: "empty", "SELECT 1"), "1,2"),
                ("plain", try await load(big, into: "plain", "CREATE TABLE users (id int); CREATE TABLE kept (id int)"), "20000"),
                ("zipped", try await load(zip, into: "zipped", "CREATE TABLE users (id int); CREATE TABLE kept (id int)"), "20000"),
                ("onlypublic", try await load(onlyPublic, into: "onlypublic", "CREATE TABLE users (id int); CREATE TABLE kept (id int)"), "20000"),
            ]

            for (name, loaded, users) in replaced {
                #expect(loaded.users == users, "\(name)")
                #expect(Self.message(loaded.answer)?.contains("The other tables stay as they were.") == true, "\(name)")
            }

            let stays = try #require(Self.message(sharing.answer))
            #expect(stays.contains("These stay as they were because other parts of sharing use them:"))
            #expect(stays.contains("and 2 more."))
            #expect(try await client.query("SELECT count(*) FROM pg_type WHERE typname = 'mood'", database: "sharing") == "1")

            let unchanged = [
                ("key", try await load(dump, into: "key", "\(same) CREATE TABLE kept (user_id int REFERENCES users); INSERT INTO kept VALUES (9)"), "Nothing changed."),
                ("view", try await load(dump, into: "view", "\(same) CREATE VIEW kept AS SELECT * FROM users"), "Nothing changed."),
                ("parts", try await load(dump, into: "parts", "\(same) CREATE TABLE logs_2 PARTITION OF logs FOR VALUES FROM (2) TO (3); INSERT INTO logs VALUES (2)"), "Nothing changed."),
                ("rows", try await load(rows, into: "rows", same), "Nothing changed."),
                ("renamed", try await load(dump, into: "renamed", "\(shared) CREATE TABLE users_old (name citext); CREATE INDEX users_name ON users_old (name); CREATE TABLE users (id int); INSERT INTO users VALUES (9)"), "index users_name belongs to table users_old"),
                ("taken", try await load(dump, into: "taken", "\(shared) CREATE TABLE users_old (id int CONSTRAINT users_pkey PRIMARY KEY); CREATE TABLE users (id int); INSERT INTO users VALUES (9)"), "did not change."),
                ("labels", try await load(dump, into: "labels", "\(same.replacingOccurrences(of: "('a', 'b')", with: "('a')")) CREATE TABLE kept (m mood)"), "did not change."),
            ]

            for (name, loaded, text) in unchanged {
                #expect(loaded.users == "9", "\(name)")
                #expect(Self.failure(loaded.answer)?.contains(text) == true, "\(name): \(loaded.answer)")
            }

            try await client.query("CREATE DATABASE locked")
            try await client.query(same, database: "locked")
            let lock = Task { try await client.query("BEGIN; LOCK TABLE users IN ACCESS SHARE MODE; SELECT pg_sleep(12)", database: "locked") }
            while try await client.query("SELECT count(*) FROM pg_stat_activity WHERE datname = 'locked' AND query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()") != "1" {
                try await Task.sleep(for: .milliseconds(100))
            }
            let waiting = await engine.handle(.importDump(DumpImport(file: dump.path(percentEncoded: false), target: .instance(id), name: "locked", existing: .replaceTables)))
            _ = try? await client.query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'locked'")
            _ = try? await lock.value

            #expect(Self.failure(waiting)?.contains("Another program uses a table of locked now.") == true)
            #expect(try await client.query("SELECT string_agg(id::text, ',') FROM users", database: "locked") == "9")
        }
    }

    private static func message(_ response: NexusResponse) -> String? {
        guard case .done(let message) = response else {
            Issue.record("no success: \(response)")
            return nil
        }

        return message
    }

    private static func failure(_ response: NexusResponse) -> String? {
        guard case .failure(let message) = response else {
            Issue.record("no failure: \(response)")
            return nil
        }

        return message
    }
}
