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
    @Test func aForeignKeyOrAViewOfAnotherTableStopsTheImport() throws {
        let replacement = PostgreSQLTableReplacement(blocked: [
            ["ALTER TABLE IF EXISTS ONLY public.users DROP CONSTRAINT IF EXISTS users_pkey;", "constraint orders_user_id_fkey on table public.orders depends on index public.users_pkey"],
            ["DROP TABLE IF EXISTS public.users;", "constraint orders_user_id_fkey on table public.orders depends on table public.users\u{1F}view public.active depends on table public.users"],
        ])

        #expect(replacement.conflicts == ["constraint orders_user_id_fkey on table orders depends on table users", "view active depends on table users"])
        #expect(replacement.kept.isEmpty)

        let text = try #require(replacement.conflictText(dump: "shop.dump", database: "shop"))
        #expect(text == "Nexus cannot replace only the tables of shop.dump. Other parts of shop use them: constraint orders_user_id_fkey on table orders depends on table users, view active depends on table users. Nothing changed. Replace the whole database or load the dump into another database.")
    }

    @Test func aLongListOfConflictsIsShort() throws {
        let users = (1...5).map { "view public.v\($0) depends on table public.users" }.joined(separator: "\u{1F}")
        let replacement = PostgreSQLTableReplacement(blocked: [["DROP TABLE IF EXISTS public.users;", users]])

        let text = try #require(replacement.conflictText(dump: "shop.dump", database: "shop"))
        #expect(text.contains("view v3 depends on table users and 2 more."))
        #expect(!text.contains("view v4"))
    }

    @Test func anExtensionATypeAFunctionAndASchemaStay() {
        let replacement = PostgreSQLTableReplacement(blocked: [
            ["DROP FUNCTION IF EXISTS public.total(a public.mood, b text);", "default value for column n of table public.kept depends on function"],
            ["DROP TYPE IF EXISTS public.mood;", "column m of table public.kept depends on type public.mood"],
            ["DROP EXTENSION IF EXISTS citext;", "column name of table public.kept depends on type public.citext"],
            ["DROP SCHEMA IF EXISTS x;", "table x.kept depends on schema x"],
        ])

        #expect(replacement.conflicts.isEmpty)
        #expect(replacement.conflictText(dump: "shop.dump", database: "shop") == nil)
        #expect(replacement.kept == ["function total(a mood, b text)", "type mood", "extension citext", "schema x"])
        #expect(replacement.expectedErrors == 7)
        #expect(replacement.keptText(database: "shop") == " These stay as they were because other parts of shop use them: function total(a mood, b text), type mood, extension citext, schema x.")
    }

    @Test func onlyTheExpectedNumberOfErrorsCounts() {
        let replacement = PostgreSQLTableReplacement(blocked: [["DROP TYPE IF EXISTS public.mood;", "column m of table public.kept depends on type public.mood"]])

        #expect(replacement.explains("pg_restore: warning: errors ignored on restore: 2"))
        #expect(!replacement.explains("pg_restore: warning: errors ignored on restore: 3"))
        #expect(!replacement.explains("pg_restore: error: connection to server was lost"))
        #expect(!PostgreSQLTableReplacement.nothingBlocked.explains("pg_restore: warning: errors ignored on restore: 1"))
        #expect(!PostgreSQLTableReplacement.nothingBlocked.explains(""))
        #expect(PostgreSQLTableReplacement.nothingBlocked.keptText(database: "shop") == "")
    }
}

// The real server, as in RealDatabaseTests.
extension NexusEngineTests {
    private static func hasRealRuntime(_ runtime: String) -> Bool {
        realRuntimes.map { FileManager.default.fileExists(atPath: "\($0)/\(runtime)/bin/pg_restore") } ?? false
    }

    @Test(.enabled(if: hasRealRuntime("postgresql/18")), .timeLimit(.minutes(2)))
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

            let shared = "CREATE EXTENSION citext; CREATE TYPE mood AS ENUM ('a'); CREATE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 1'; CREATE SCHEMA x;"
            let tables = "CREATE TABLE users (id int PRIMARY KEY, name citext, m mood, n int DEFAULT f()); CREATE TABLE x.notes (user_id int REFERENCES users); CREATE VIEW named AS SELECT id, count(*) AS total FROM users GROUP BY id;"

            try await client.query("CREATE DATABASE source")
            try await client.query("\(shared) \(tables) INSERT INTO users VALUES (1, 'Ann', 'a'), (2, 'Bob', 'a')", database: "source")
            let dump = work.appending(path: "source.dump")
            _ = try await CommandRunner.run(Command(
                executable: tools.bin("pg_dump"),
                arguments: ["-h", "127.0.0.1", "-p", String(client.endpoint.port), "-U", client.endpoint.account.user, "-Fc", "-f", dump.path(percentEncoded: false), "source"],
                environment: ["PGPASSWORD": client.endpoint.account.password]
            ))

            func load(into name: String, kept: String) async throws -> (answer: NexusResponse, users: String, kept: String) {
                try await client.query("CREATE DATABASE \(name)")
                try await client.query("\(shared) \(tables) INSERT INTO users VALUES (9, 'Old', 'a'); \(kept)", database: name)
                let answer = await engine.handle(.importDump(DumpImport(file: dump.path(percentEncoded: false), target: .instance(id), name: name, existing: .replaceTables)))
                return (answer, try await client.query("SELECT string_agg(id::text, ',' ORDER BY id) FROM users", database: name), try await client.query("SELECT count(*) FROM kept", database: name))
            }

            let free = try await load(into: "free", kept: "CREATE TABLE kept (id int); INSERT INTO kept VALUES (1)")
            let sharing = try await load(into: "sharing", kept: "CREATE TABLE kept (name citext, m mood, n int DEFAULT f()); CREATE TABLE x.other (id int); INSERT INTO kept VALUES ('a', 'a')")
            let key = try await load(into: "key", kept: "CREATE TABLE kept (user_id int REFERENCES users); INSERT INTO kept VALUES (9)")
            let view = try await load(into: "view", kept: "CREATE VIEW kept AS SELECT * FROM users")

            try await client.query("CREATE DATABASE locked")
            try await client.query("\(shared) \(tables) INSERT INTO users VALUES (9, 'Old', 'a'); CREATE TABLE kept (id int)", database: "locked")
            let lock = Task { try await client.query("BEGIN; LOCK TABLE users IN ACCESS SHARE MODE; SELECT pg_sleep(12)", database: "locked") }
            while try await client.query("SELECT count(*) FROM pg_stat_activity WHERE datname = 'locked' AND query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()") != "1" {
                try await Task.sleep(for: .milliseconds(100))
            }
            let waiting = await engine.handle(.importDump(DumpImport(file: dump.path(percentEncoded: false), target: .instance(id), name: "locked", existing: .replaceTables)))
            _ = try? await client.query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'locked'")
            _ = try? await lock.value
            let lockedUsers = try await client.query("SELECT string_agg(id::text, ',') FROM users", database: "locked")

            #expect(Self.failure(waiting)?.contains("Another program uses a table of locked now.") == true)
            #expect(lockedUsers == "9")

            #expect(free.users == "1,2")
            #expect(free.kept == "1")
            #expect(Self.message(free.answer)?.contains("The other tables stay as they were. Nexus put a copy") == true)

            #expect(sharing.users == "1,2")
            #expect(sharing.kept == "1")
            let stays = try #require(Self.message(sharing.answer))
            #expect(stays.contains("These stay as they were because other parts of sharing use them:"))
            for object in ["extension citext", "type mood", "function f()", "schema x"] {
                #expect(stays.contains(object))
            }

            for blocked in [key, view] {
                #expect(blocked.users == "9")
                #expect(blocked.kept == "1")
                #expect(Self.failure(blocked.answer)?.contains("Nothing changed.") == true)
            }
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
