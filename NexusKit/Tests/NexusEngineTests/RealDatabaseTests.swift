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

// These tests run the real database servers. They run only when NEXUS_REAL_RUNTIMES names the
// runtimes folder of a Nexus install, for example:
// NEXUS_REAL_RUNTIMES="$HOME/Library/Application Support/Nexus/runtimes" swift test
// Each instance is new and lives in a folder in /tmp. So the instances of the user do not change.
extension NexusEngineTests {
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    @Test(.enabled(if: realRuntimes != nil), arguments: ["mysql/8.4", "mariadb/11.4", "postgresql/17"])
    func aRealInstanceStartsWithoutAPasswordListsItsDatabasesAndChangesItsAccount(_ runtime: String) async throws {
        let parts = runtime.split(separator: "/").map(String.init)
        let (name, line) = (parts[0], parts[1])
        let id = "\(name)-\(line)"
        let root = URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        let link = paths.runtime(name, line: line)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: runtime))

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
            let tools = try #require(await engine.databaseRuntime(id))
            let port = try await engine.port(of: tools)
            let work = paths.run.appending(path: "test", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let started = await engine.handle(.start(service: id))

            func client(_ account: DatabaseAccount) throws -> DatabaseClient {
                let client = DatabaseClient(tools: tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: port, account: account), options: work.appending(path: "\(UUID().uuidString).cnf"))
                try client.prepare()
                return client
            }

            let before = await engine.handle(.databaseSizes(instance: id))
            _ = try? await client(.newInstance).query("CREATE DATABASE nexus_test")
            let after = await engine.handle(.databaseSizes(instance: id))
            let changed = await engine.handle(.setAccount(instance: id, account: DatabaseAccount(user: "nexus", password: "s3cret'pw")))
            let newAccountWorks = try? await client(DatabaseAccount(user: "nexus", password: "s3cret'pw")).query("SELECT 1")
            let oldAccountFails = (try? await client(.newInstance).query("SELECT 1")) == nil
            let changedBack = await engine.handle(.setAccount(instance: id, account: .newInstance))
            let noPasswordWorks = try? await client(.newInstance).query("SELECT 1")

            if case .done = started {} else { Issue.record("the start failed: \(started)") }
            #expect(before == .databaseSizes([]))
            guard case .databaseSizes(let sizes) = after else {
                Issue.record("no sizes: \(after)")
                return
            }
            #expect(sizes.map(\.name) == ["nexus_test"])
            #expect(sizes.allSatisfy { $0.bytes >= 0 })
            if case .done = changed {} else { Issue.record("the account did not change: \(changed)") }
            #expect(newAccountWorks == "1")
            #expect(oldAccountFails)
            if case .done = changedBack {} else { Issue.record("the account did not change back: \(changedBack)") }
            #expect(noPasswordWorks == "1")
            #expect(await engine.stateStore.current().databaseAccounts[id] == .newInstance)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: ["mysql/8.4", "mariadb/11.4", "postgresql/17"])
    func aRealCopyShowsItsProgressAndAStoppedCopyLeavesNoDatabase(_ runtime: String) async throws {
        let parts = runtime.split(separator: "/").map(String.init)
        let (name, line) = (parts[0], parts[1])
        let id = "\(name)-\(line)"
        let root = URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        let link = paths.runtime(name, line: line)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: runtime))

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
            let tools = try #require(await engine.databaseRuntime(id))
            let port = try await engine.port(of: tools)
            let work = paths.run.appending(path: "test", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            _ = await engine.handle(.start(service: id))
            let client = DatabaseClient(tools: tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: port, account: .newInstance), options: work.appending(path: "client.cnf"))
            try client.prepare()

            try await client.query("CREATE DATABASE nexus_source")
            if tools.kind.usesMySQLProtocol {
                try await client.query("CREATE TABLE items (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(200))", database: "nexus_source")
                try await client.query("INSERT INTO items (v) SELECT REPEAT('x', 100) FROM information_schema.COLUMNS a, information_schema.COLUMNS b LIMIT 300000", database: "nexus_source")
            } else {
                try await client.query("CREATE TABLE items (id serial PRIMARY KEY, v text); INSERT INTO items (v) SELECT repeat('x', 100) FROM generate_series(1, 300000)", database: "nexus_source")
            }

            let source = DatabaseServer(host: "127.0.0.1", port: port, account: .newInstance)
            let listed = await engine.handle(.sourceDatabases(source: source, instance: id))
            let tasks = TaskRecorder()
            tasks.record(await engine.events())

            func copying(_ copy: String) -> (TaskList) -> Bool {
                { list in list.tasks.contains { $0.work == .copyDatabase(database: "nexus_source", instance: id, name: copy) && $0.completed > 0 } }
            }

            let copied = await engine.handle(.copyDatabase(DatabaseCopy(source: source, database: "nexus_source", instance: id, name: "nexus_copy")))
            let progress = await tasks.next(where: copying("nexus_copy"))?.tasks.first

            let stoppedCopy = Task { await engine.handle(.copyDatabase(DatabaseCopy(source: source, database: "nexus_source", instance: id, name: "nexus_stopped"))) }
            let running = await tasks.next(where: copying("nexus_stopped"))?.tasks.first
            let second = await engine.handle(.copyDatabase(DatabaseCopy(source: source, database: "nexus_source", instance: id, name: "nexus_stopped", replace: true)))
            let stop = await engine.handle(.stopTask(id: running?.id ?? ""))
            let stopped = await stoppedCopy.value
            let after = await engine.handle(.databaseSizes(instance: id))

            guard case .databaseSizes(let sources) = listed, case .databaseSizes(let databases) = after else {
                Issue.record("no database lists: \(listed) \(after)")
                return
            }
            #expect(sources.map(\.name) == ["nexus_source"])
            if case .done = copied {} else { Issue.record("the copy failed: \(copied)") }
            #expect(progress?.total ?? 0 > 0)
            #expect(progress?.tableCount == 1)
            #expect(progress?.table == (tools.kind.usesMySQLProtocol ? "items" : nil))
            #expect(second == .failure(message: "A copy into nexus_stopped on \(id) runs already. Wait until it ends, or stop it."))
            #expect(stop == .done(message: "The task stops."))
            #expect(stopped == .stopped(message: "The copy of nexus_source stopped. \(id) has no database nexus_stopped."))
            #expect(databases.map(\.name) == ["nexus_copy", "nexus_source"])
        }
    }
}
