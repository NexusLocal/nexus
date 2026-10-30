import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func workspaceRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func git(_ arguments: String..., in folder: URL) async throws {
        _ = try await CommandRunner.run(Command(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Nexus", "-c", "user.email=nexus@example.test", "-C", folder.path(percentEncoded: false)] + arguments
        ))
    }

    private func repository(in root: URL) async throws -> URL {
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        return shop
    }

    private func settle(_ engine: NexusEngine) async throws {
        await engine.reconcileWorkspaces()

        while await engine.workspaceWorkRuns {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func workspaces(_ engine: NexusEngine) async -> [WorkspaceInfo] {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return []
        }

        return sites.flatMap { $0.workspaces ?? [] }
    }

    private func worktreeEngine(root: URL, shop: URL, automatic: Bool? = nil, runtimes: [(name: String, line: String)] = []) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", automaticWorkspaces: automatic)]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: runtimes)
        try await settle(engine)
        return engine
    }

    @Test func gitWorktreeAddGivesAWorkspaceAndGitWorktreeRemoveEndsIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "TICKET-123", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "ticket", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let path = RealPath.of(worktree)
        #expect(await workspaces(engine) == [WorkspaceInfo(name: "ticket-123", worktree: path, folder: path, branch: "ticket", hosts: ["shop-ticket-123.test"], problem: "Every site needs nginx, and nginx is not installed. Run: nexus install nginx 1.30", state: .ready, startedCopies: [])])

        try await git("worktree", "remove", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    private func writeFile(_ text: String, to path: String, in folder: URL) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func committedLaravelApplication(in root: URL, ignoring ignored: String) async throws -> URL {
        let shop = try await repository(in: root)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("{}", to: "composer.json", in: shop)
        try writeFile(ignored, to: ".gitignore", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile(#"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE', 'forge')],
            ],
            'redis' => [
                'default' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_DB', 0)],
            ],
        ];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "application", in: shop)
        try writeFile(Self.bootstrappers, to: "vendor/autoload.php", in: shop)
        return shop
    }

    private func databaseConfig(driver: String) -> String {
        #"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE', 'forge')],
                'cms' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE_CMS', 'forge_cms')],
                'old' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE_OLD', 'forge_old')],
            ],
        ];
        """#
    }

    private func engineWithDatabase(
        root: URL,
        shop: URL,
        runtime: (name: String, line: String),
        port: Int,
        host: String = "shop.test",
        keys: [WorkspaceEnvKey]? = nil,
        redisPort: Int? = nil
    ) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: host, folder: shop, php: "8.5", workspaceKeys: keys)]
        state.ports["\(runtime.name)-\(runtime.line)"] = port
        state.ports["redis-8.2"] = redisPort
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)

        let link = await engine.paths.runtime(runtime.name, line: runtime.line)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: "\(runtime.name)/\(runtime.line)"))
        return engine
    }

    private func databaseClient(_ engine: NexusEngine, id: String, port: Int) async throws -> DatabaseClient {
        let tools = try #require(await engine.databaseRuntime(id))
        let work = await engine.paths.run.appending(path: "test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let client = DatabaseClient(tools: tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: port, account: .newInstance), options: work.appending(path: "client.cnf"))
        try client.prepare()
        return client
    }

    private func digest(_ client: DatabaseClient, _ database: String) async throws -> String {
        let sql = client.tools.kind.usesMySQLProtocol
            ? "SELECT MD5(GROUP_CONCAT(id, name ORDER BY id)) FROM items"
            : "SELECT md5(string_agg(id::text || name, ',' ORDER BY id)) FROM items"

        return try await client.query(sql, database: database)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: [("mysql", "8.4", "mysql"), ("mariadb", "11.4", "mariadb"), ("postgresql", "17", "pgsql")])
    func aRealWorkspaceGetsACopyOfEachDatabaseAndTheMainDatabasesStayTheSame(name: String, line: String, driver: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(databaseConfig(driver: driver), to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "connections", in: shop)
        let id = "\(name)-\(line)"
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\nDB_DATABASE_CMS=shop_cms\nDB_DATABASE_OLD=not_here\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: (name, line), port: port)
        var mainBefore: [String] = []
        var mainAfter: [String] = []
        var copies: [String] = []
        var rowAfterRetry: String?
        var workspace: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            let client = try await databaseClient(engine, id: id, port: port)

            for database in ["shop", "shop_cms"] {
                try await client.query("CREATE DATABASE \(database)")
                try await client.query("CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(20))", database: database)
                try await client.query("INSERT INTO items VALUES (1, 'one'), (2, '\(database)')", database: database)
                mainBefore.append(try await digest(client, database))
            }

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            for database in ["shop", "shop_cms"] {
                copies.append(try await digest(client, "\(database)_fix"))
                mainAfter.append(try await digest(client, database))
            }

            try await client.query("INSERT INTO items VALUES (3, 'workspace')", database: "shop_fix")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            rowAfterRetry = try await client.query("SELECT name FROM items WHERE id = 3", database: "shop_fix")
            workspace = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first
        }

        #expect(workspace?.state == .ready)
        #expect(workspace?.databases == [WorkspaceDatabaseCopy(instance: id, name: "shop_fix"), WorkspaceDatabaseCopy(instance: id, name: "shop_cms_fix")])
        #expect(copies == mainBefore)
        #expect(mainAfter == mainBefore)
        #expect(rowAfterRetry == "workspace")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealRetryMakesACopyAgainThatWentAwayOrThatDidNotEnd() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        let copy = WorkspaceDatabaseCopy(instance: "mysql-8.4", name: "shop_fix")
        let key = RealPath.of(shop)
        var afterDrop, afterHalfCopy: String?
        var record: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")
            try await client.query("CREATE TABLE items (id INT PRIMARY KEY)", database: "shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            try await client.query("DROP DATABASE shop_fix")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            afterDrop = try await client.query("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'shop_fix' AND TABLE_NAME = 'items'")

            try await client.query("DROP TABLE items", database: "shop_fix")
            let store = await engine.stateStore
            try await store.update { state in
                state.worktrees[key]?.workspaces[0].databases = []
                state.worktrees[key]?.workspaces[0].startedCopies = [copy]
            }
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            afterHalfCopy = try await client.query("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'shop_fix' AND TABLE_NAME = 'items'")
            record = await store.current().worktrees[key]?.workspaces.first
        }

        #expect(afterDrop == "1")
        #expect(afterHalfCopy == "1")
        #expect(record?.state == .ready)
        #expect(record?.databases == [copy])
        #expect(record?.startedCopies.isEmpty == true)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealWorkspaceDoesNotReplaceADatabaseThatItDidNotMake() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        var kept: String?
        var withoutMain: [WorkspaceState?] = []
        var withOther: [WorkspaceState?] = []

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            withoutMain = await workspaces(engine).map(\.state)

            try await client.query("CREATE DATABASE shop")
            try await client.query("CREATE DATABASE shop_fix")
            try await client.query("CREATE TABLE mine (id INT)", database: "shop_fix")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            withOther = await workspaces(engine).map(\.state)
            kept = try await client.query("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'shop_fix' AND TABLE_NAME = 'mine'")
        }

        #expect(withoutMain == [.notIsolated("mysql-8.4 has no database shop. Import it, and then retry.")])
        #expect(withOther == [.notIsolated("mysql-8.4 has a database shop_fix already, and this workspace did not make it. Remove that database, and then retry.")])
        #expect(kept == "1")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealWorkspaceDoesNotClaimADatabaseAfterACopyThatFailed() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        var afterFailure: Workspace?
        var kept: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")
            try await client.query("CREATE TABLE items (id INT)", database: "shop")
            try await client.query("CREATE VIEW broken AS SELECT id FROM items", database: "shop")
            try await client.query("DROP TABLE items", database: "shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            afterFailure = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first

            try await client.query("CREATE DATABASE shop_fix")
            try await client.query("CREATE TABLE mine (id INT)", database: "shop_fix")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            kept = try await client.query("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'shop_fix' AND TABLE_NAME = 'mine'")
        }

        #expect(afterFailure?.startedCopies.isEmpty == true)
        #expect(afterFailure?.databases.isEmpty == true)
        #expect(kept == "1")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealWorkspaceCopiesADatabaseThatASecondKeyStillNames() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(databaseConfig(driver: "mysql"), to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "connections", in: shop)
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\nDB_DATABASE_CMS=shop\nDB_DATABASE_OLD=not_here\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port, keys: [WorkspaceEnvKey(key: "DB_DATABASE", value: "own")])
        var copies: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            copies = try await client.query("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'shop_fix'")
        }

        #expect(copies == "1")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealWorkspaceStartsAStoppedInstanceWithoutTheChoiceOfTheUser() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        var workspace: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await databaseClient(engine, id: "mysql-8.4", port: port).query("CREATE DATABASE shop")
            _ = await engine.handle(.stop(service: "mysql-8.4"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            workspace = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first
        }

        #expect(workspace?.state == .ready)
        #expect(workspace?.databases == [WorkspaceDatabaseCopy(instance: "mysql-8.4", name: "shop_fix")])
        #expect(await engine.stateStore.current().enabledServices.contains("mysql-8.4") == false)
    }

    private func sqliteApplication(in root: URL, ignoring: String) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let shop = try await committedLaravelApplication(in: root, ignoring: ignoring)
        try writeFile(#"""
        <?php
        return ['default' => 'main', 'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]]];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "sqlite", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "database"), withIntermediateDirectories: true)
        try writeFile("DB_DATABASE=\(RealPath.of(shop.appending(path: "database")))/database.sqlite\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        return (shop, engine, root.appending(path: "fix", directoryHint: .isDirectory))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceClonesTheFileBehindASymbolicLink() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        let shared = root.appending(path: "shared.sqlite")
        try Data("the data".utf8).write(to: shared)
        try FileManager.default.createSymbolicLink(at: shop.appending(path: "database/database.sqlite"), withDestinationURL: shared)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)
        let type = try FileManager.default.attributesOfItem(atPath: clone)[.type] as? FileAttributeType

        #expect(type == .typeRegular)
        #expect(try String(contentsOfFile: clone, encoding: .utf8) == "the data")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceClonesNoSQLiteFileWhenGitSeesItsWriteAheadFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        try writeFile("the data", to: "database/database.sqlite", in: shop)
        try writeFile("the last changes", to: "database/database.sqlite-wal", in: shop)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)

        #expect(!FileManager.default.fileExists(atPath: clone))
        #expect(!FileManager.default.fileExists(atPath: "\(clone)-wal"))
        #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore database/database.sqlite-wal, so Nexus does not clone that file.")])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)), arguments: [true, false])
    func aRealWorkspaceGetsACloneOfASQLiteFileThatGitIgnores(ignored: Bool) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ignored ? ".env\nvendor\n*.sqlite\n" : ".env\nvendor\n")
        try writeFile("the data", to: "database/database.sqlite", in: shop)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite")
        let env = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(env == "DB_DATABASE=\(RealPath.of(worktree))/database/database.sqlite\n")

        if ignored {
            #expect(try String(contentsOf: clone, encoding: .utf8) == "the data")
            #expect(await workspaces(engine).map(\.state) == [.ready])
        } else {
            #expect(!FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)))
            #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore database/database.sqlite, so Nexus does not clone that file.")])
        }
    }

    @Test func aSiteThatIsNoLaravelApplicationIsReadyWithoutAnEnvFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
    }

    @Test func aWorkspaceThatWaitsFromBeforeARestartGetsItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        let path = RealPath.of(worktree)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(listed: [RealPath.of(shop), path], workspaces: [Workspace(name: "fix", worktree: path, folder: path, branch: "fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
    }

    @Test func aWorkspaceWithoutItsFoldersWaitsForItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shop = root.appending(path: "disk/shop", directoryHint: .isDirectory)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/disk/fix", folder: "/disk/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.preparing])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWithItsOwnCachedConfigurationIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: worktree)
        try await settle(engine)

        #expect(await workspaces(engine).first?.isolationProblem?.contains("The worktree has bootstrap/cache/config.php") == true)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealKeyOfTheSiteThatReplacesADatabaseNameIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("DB_PORT=13999\nDB_DATABASE=shop\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "DB_DATABASE", value: "shop")])]
        state.ports["mysql-8.4"] = 13999
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated("The key DB_DATABASE of the site replaces the value that isolates this workspace.")])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNewKeyOfASiteReachesAWorkspaceThatExistsAndKeepsItsPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")])]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let store = await engine.stateStore
        let port = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first?.ports["scout"])
        let keys = [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}"), WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]

        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: keys)))
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SCOUT_PORT=\(port)\n"))
        #expect(text.contains("SECOND=fix\n"))
    }

    @Test func aWrongEnvKeyNameGivesAnErrorAndChangesNothing() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: [WorkspaceEnvKey(key: "TWO WORDS", value: "1")])))

        #expect(response == .failure(message: "TWO WORDS is not a valid env key. Use letters, digits and underscores, for example SCOUT_PORT."))
        let store = await engine.stateStore
        #expect(await store.current().sites.first?.workspaceKeys == nil)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceKeepsAnEnvFileThatNexusCannotRead() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let unreadable = Data("APP_NAME=Caf".utf8) + [0xE9]

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try unreadable.write(to: worktree.appending(path: ".env"))
        try await settle(engine)

        #expect(try Data(contentsOf: worktree.appending(path: ".env")) == unreadable)
        #expect(await workspaces(engine).map(\.state) == [.notIsolated("Nexus cannot read \(RealPath.of(worktree))/.env as UTF-8 text, so it does not write the .env of this workspace.")])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsTheKeysOfEverySiteOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("<?php", to: "public/index.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.5"),
            Site(host: "b.test", folder: shop.appending(path: "public", directoryHint: .isDirectory), php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SECOND=fix\n"))
    }

    @Test func aRetryAfterTheFixOfTheCauseClearsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        let unknown = await engine.handle(.retryWorkspace(host: "shop.test", name: "other"))
        let retried = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(unknown == .failure(message: "shop.test has no workspace other."))
        #expect(retried == .done(message: "Nexus sets up the workspace fix again."))
        #expect(await workspaces(engine).first?.state != .preparing)
    }

    @Test func aCachedConfigurationOfTheMainCheckoutGivesAWorkspaceThatIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated(ProbeError.cachedConfiguration.description)])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsAnEnvFileWithOnlyTheExpectedChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let databasePort = freePort()
        try writeFile("""
        APP_NAME=Shop
        APP_URL=https://my.shop.test
        SESSION_DOMAIN=.shop.test
        SESSION_DRIVER=redis
        DB_PORT=\(databasePort)
        DB_DATABASE=shop
        REDIS_PORT=16999

        """, to: ".env", in: shop)
        let engine = try await engineWithDatabase(
            root: root,
            shop: shop,
            runtime: ("mysql", "8.4"),
            port: databasePort,
            host: "my.shop.test",
            keys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")],
            redisPort: 16999
        )
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await databaseClient(engine, id: "mysql-8.4", port: databasePort).query("CREATE DATABASE shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
        }

        let store = await engine.stateStore
        let workspace = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first)
        let port = try #require(workspace.ports["scout"])
        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(workspace.state == .ready)
        #expect(workspace.redisIndexes == ["REDIS_DB": 16])
        #expect(text == """
        APP_NAME=Shop
        APP_URL=https://my.shop-fix.test
        SESSION_DOMAIN=.shop-fix.test
        SESSION_DRIVER=redis
        DB_PORT=\(databasePort)
        DB_DATABASE=shop_fix
        REDIS_PORT=16999
        REDIS_DB=16
        SCOUT_PORT=\(port)

        """)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWritesNoEnvFileThatGitSees() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: "vendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore .env, so Nexus does not write that file.")])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
    }

    @Test func aFailedAutomaticChangeShowsAtTheWorkspaceThatItLeftOut() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop, runtimes: [("php", "8.4"), ("nginx", "1.30")])
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        await engine.recordAutomaticFailure("nginx refused the file.")

        #expect(await workspaces(engine).first?.problem == "The web configuration did not change. nginx refused the file.")
        #expect(await workspaces(engine).first?.url == nil)
    }

    @Test func aWorkspaceThatCanRunHasAURL() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.problem == nil)
        #expect(workspace?.url == "https://shop-fix.test")
    }

    @Test func aWorkspaceWithoutItsPHPVersionHasNoURLAndSaysWhy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "PHP 8.4 is not installed. Run: nexus install php 8.4")
    }

    @Test func aWorkspaceRunsAsASiteWithThePHPAndTheServerOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "my.shop.test", folder: root, aliases: ["blog.local"], php: "8.4", server: .apache)]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "ticket-1", worktree: "/w/ticket-1", folder: "/w/ticket-1")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.conflicts.isEmpty)
        #expect(workspaces.sites == [Site(host: "my.shop-ticket-1.test", folder: URL(filePath: "/w/ticket-1", directoryHint: .isDirectory), aliases: ["blog-ticket-1.test"], php: "8.4", server: .apache)])
    }

    @Test func aWorkspaceWhoseHostIsTakenIsLeftOutWithAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, php: "8.4"),
            Site(host: "shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.isEmpty)
        #expect(Array(workspaces.conflicts.values) == ["The workspace fix does not run, because another site has the host shop-fix.test already."])
    }

    @Test func aWorkspaceThatDoesNotRunHasNoURLAndNamesTheHostThatIsTaken() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, aliases: ["www.shop.test"], php: "8.4"),
            Site(host: "www.shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state)

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "The workspace fix does not run, because another site has the host www.shop-fix.test already.")
    }

    @Test func aHostThatIsTooLongStopsOnlyItsOwnSite() throws {
        let runtime = InstalledRuntime(name: "php", line: "8.4", version: "8.4.0", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/php"))
        let site = Site(host: "\(String(repeating: "a.", count: 130))test", folder: URL(filePath: "/shop"), php: "8.4")

        let problem = NexusEngine.problem(of: site, installed: [runtime], checksNginx: false)

        #expect(problem?.contains("is not a valid host name") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCheckoutInAnEmptyWorktreeGivesADocumentRootInItsPublicFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", worktree.path(percentEncoded: false), "reset", "-q", "--hard", in: shop)
        let documentRoot = "\(RealPath.of(worktree))/public/"

        while await !(engine.appliedSites ?? []).contains(where: { $0.contains(documentRoot) }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func twoSitesOfOneProjectShareOneBlockForAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publicFolder = root.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "a.test", folder: root, php: "8.4"), Site(host: "b.test", folder: publicFolder, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.map(\.hosts) == [["a-fix.test", "b-fix.test"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func aMergeInAWorktreeThatAddsThePublicFolderChangesTheDocumentRoot() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("switch", "-q", "-c", "with-public", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: shop.appending(path: "public/index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        try await git("-C", worktree.path(percentEncoded: false), "merge", "-q", "with-public", in: shop)

        while await engine.appliedSites?.contains(where: { $0.contains("/fix/public") }) != true {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceDoesNotStartAWebServerThatTheUserStopped() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = freePort()
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        var whileStopped, afterStart: Bool?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)
            _ = await engine.handle(.stop(service: ServiceCatalog.nginxID))
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            whileStopped = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
            _ = await engine.handle(.start(service: ServiceCatalog.nginxID))
            afterStart = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
        }

        #expect(whileStopped != true)
        #expect(afterStart == true)
        #expect(await engine.stateStore.current().stoppedByStopAll.isEmpty)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceOpensOverHTTPSWithTheFilesOfItsWorktree() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)

        var main, workspace, gone: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "my.shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)

            let worktree = root.appending(path: "test-1", directoryHint: .isDirectory)
            try await git("worktree", "add", "-q", "-b", "test-1", worktree.path(percentEncoded: false), in: shop)
            try Data("<?php echo 'workspace';".utf8).write(to: worktree.appending(path: "public/index.php"))
            try await settle(engine)

            main = await page("my.shop.test", port: httpsPort, expecting: "main")
            workspace = await page("my.shop-test-1.test", port: httpsPort, expecting: "workspace")

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            gone = await page("my.shop-test-1.test", port: httpsPort, expecting: "main")
        }

        #expect(main == "main")
        #expect(workspace == "workspace")
        #expect(gone != "workspace")
    }

    @Test func aWorktreeThatStaysLockedAfterItsCheckoutGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "claude-test").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "-b", "worktree-claude-test", worktree, in: shop)
        try await git("worktree", "lock", "--reason", "claude agent", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["claude-test"])
    }

    @Test func aLockedWorktreeWithoutACheckoutWaits() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree, in: shop)
        try await git("worktree", "lock", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aWorktreeThatWasThereBeforeTheSiteGetsNoWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try await git("worktree", "add", "-q", "-b", "old", root.appending(path: "old").path(percentEncoded: false), in: shop)

        let engine = try await worktreeEngine(root: root, shop: shop)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aFolderThatGitNoLongerReadsKeepsItsWorkspaces() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let head = shop.appending(path: ".git/HEAD")
        let stored = try Data(contentsOf: head)
        try FileManager.default.removeItem(at: head)

        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        try stored.write(to: head)
    }

    @Test func theSettingOfASiteChangesWithAnEditWithoutANewWebConfiguration() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(automaticWorkspaces: false)))
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        guard case .done = response else {
            Issue.record("No change: \(response)")
            return
        }

        guard case .sites(let sites) = await engine.handle(.sites) else {
            Issue.record("No sites")
            return
        }

        #expect(sites.first?.automaticWorkspaces == false)
        #expect(sites.first?.workspaces == [])
    }

    @Test func aRemovedSiteTakesItsWorkspaceRecordWithIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore

        try await store.update { $0.sites = [] }
        try await settle(engine)

        #expect(await store.current().worktrees.isEmpty)
    }

    @Test func aRemovedSiteTakesItsRecordAlsoWhenAnotherSiteIsInItsFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let backend = shop.appending(path: "backend", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, php: "8.4"),
            Site(host: "backend.test", folder: backend, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        let store = await engine.stateStore

        try await store.update { $0.sites.removeAll { $0.host == "shop.test" } }
        try await settle(engine)

        #expect(await store.current().worktrees.keys.sorted() == [RealPath.of(backend)])
    }

    @Test func theMessageOfTheSettingCountsTheOtherSiteOfTheProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.4"),
            Site(host: "b.test", folder: publicFolder, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)

        let response = await engine.handle(.editSite(host: "b.test", change: SiteChange(automaticWorkspaces: false)))

        guard case .done(let message) = response else {
            Issue.record("No change: \(response)")
            return
        }

        #expect(message.contains("A new worktree gets a workspace."))
    }

    @Test func aSiteOnAPublicFolderKeepsItsWorkspacesWhileComposerJSONIsGone() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        let composerFile = shop.appending(path: "composer.json")
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: composerFile)
        let engine = try await worktreeEngine(root: root, shop: publicFolder)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let store = await engine.stateStore

        try FileManager.default.removeItem(at: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix")) + "/public"])

        try Data("{}".utf8).write(to: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix"))])
        #expect(await store.current().worktrees.count == 1)
    }

    @Test func aWorktreeAfterALaterGitInitGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)

        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfASiteFindsAGitInitWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("init", "-q", "-b", "main", in: shop)

        while await engine.watchedRepositories.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aFolderThatDoesNotExistKeepsItsWorkspaceRecord() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore
        let record = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/nexus/no/such/fix", folder: "/nexus/no/such/fix")])

        try await store.update { $0.worktrees["/nexus/no/such/shop"] = record }
        try await settle(engine)

        #expect(await store.current().worktrees["/nexus/no/such/shop"] == record)
    }

    @Test(arguments: [("a.test", "b.test"), ("b.test", "a.test")])
    func twoSitesOfOneProjectGiveAWorkspaceWhenOneHasTheSettingOn(on: String, off: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: on, folder: shop, php: "8.4", automaticWorkspaces: true),
            Site(host: off, folder: publicFolder, php: "8.4", automaticWorkspaces: false),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix", "fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfTheGitFolderFindsANewWorktreeWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(await workspaces(engine).map(\.name) == ["fix"])

        let moved = root.appending(path: "other/fix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git("worktree", "move", root.appending(path: "fix").path(percentEncoded: false), moved.path(percentEncoded: false), in: shop)

        while await workspaces(engine).first?.folder != RealPath.of(moved) {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", moved.path(percentEncoded: false), "switch", "-q", "-c", "second", in: shop)

        while await workspaces(engine).first?.branch != "second" {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("worktree", "remove", moved.path(percentEncoded: false), in: shop)

        while await !workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

extension NexusEngine {
    func recordAutomaticFailure(_ failure: String) {
        appliedSites = []
        automaticWebFailure = failure
    }
}

extension NexusEngine {
    var workspaceWorkRuns: Bool {
        reconcilingWorkspaces || settingUpWorkspaces
    }
}
