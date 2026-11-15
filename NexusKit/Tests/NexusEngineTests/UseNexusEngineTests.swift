import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func siteWithoutLaravel(in root: URL) throws -> (site: Site, env: URL) {
        let shop = site("shop.test", in: root.appending(path: "projects", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: shop.folder, withIntermediateDirectories: true)
        let env = shop.folder.appending(path: ".env")
        try Data("DB_HOST=localhost\nDB_PORT=8889\n".utf8).write(to: env)

        return (shop, env)
    }

    @Test func aSiteWithoutLaravelGetsNoInfo() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, _) = try siteWithoutLaravel(in: root)
        var state = EngineState()
        state.sites = [shop]
        let engine = try makeSiteEngine(root: root, state: state)

        let response = await engine.handle(.useNexusInfo(host: "shop.test"))

        #expect(response == .useNexusInfo(nil))
    }

    @Test func theUseNexusRequestOfASiteWithoutLaravelChangesNothing() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, env) = try siteWithoutLaravel(in: root)
        var state = EngineState()
        state.sites = [shop]
        let engine = try makeSiteEngine(root: root, state: state)
        let request = UseNexusRequest(host: "shop.test", instance: nil, copy: false, changes: [EnvValueChange(key: "DB_HOST", oldValue: "localhost", newValue: "127.0.0.1")])

        let response = await engine.handle(.useNexus(request))

        #expect(response == .failure(message: "shop.test is no Laravel application. Nexus changed nothing."))
        #expect(try String(contentsOf: env, encoding: .utf8) == "DB_HOST=localhost\nDB_PORT=8889\n")
        #expect(await engine.stateStore.current().useNexusKeys.isEmpty)
    }

    @Test func theUseNexusRequestOfALaravelSiteWithoutAnEnvNamesTheMissingFile() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = site("shop.test", in: root.appending(path: "projects", directoryHint: .isDirectory))
        for file in ["artisan", "bootstrap/app.php"] {
            let url = shop.folder.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        var state = EngineState()
        state.sites = [shop]
        let engine = try makeSiteEngine(root: root, state: state)
        let request = UseNexusRequest(host: "shop.test", instance: nil, copy: false, changes: [])

        let response = await engine.handle(.useNexus(request))

        #expect(response == .failure(message: "shop.test has no .env file, so Nexus changed nothing."))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealCopyFromTheSocketOfAnotherServerMovesTheEnvToNexus() async throws {
        let oldRoot = shortTemporaryRoot()
        let root = shortTemporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: oldRoot)
            try? FileManager.default.removeItem(at: root)
        }

        let oldPaths = NexusPaths(root: oldRoot.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try oldPaths.createFolders()
        try linkRealRuntimes(in: oldPaths, ["mysql/8.0"])
        let oldPort = freePort()
        var oldState = EngineState()
        oldState.ports["mysql-8.0"] = oldPort
        oldState.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(oldState).write(to: oldPaths.config.appending(path: "state.json"))
        let oldEngine = NexusEngine(
            paths: oldPaths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: oldPaths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: oldRoot.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: oldRoot.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )

        let app = root.appending(path: "shop", directoryHint: .isDirectory)
        let files = ["artisan": "", "vendor/autoload.php": Self.bootstrappers, "bootstrap/app.php": Self.bootstrapApp, "config/database.php": Self.useNexusDatabaseConfig]

        for (path, text) in files {
            let file = app.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        try linkRealRuntimes(in: NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root), ["mysql/8.4", "php/8.5"])
        var state = EngineState()
        state.ports["mysql-8.4"] = freePort()
        state.sites = [Site(host: "shop.test", folder: app, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)

        try await whileRunning(oldEngine) {
            try await whileRunning(engine) {
                _ = await oldEngine.handle(.start(service: "mysql-8.0"))
                _ = await engine.handle(.start(service: "mysql-8.4"))
                let oldTools = try #require(await oldEngine.databaseRuntime("mysql-8.0"))
                let newTools = try #require(await engine.databaseRuntime("mysql-8.4"))
                let newPort = try await engine.port(of: newTools)
                let work = oldPaths.run.appending(path: "test", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let oldClient = DatabaseClient(tools: oldTools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: oldPort, account: .newInstance), options: work.appending(path: "old.cnf"))
                let newClient = DatabaseClient(tools: newTools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: newPort, account: .newInstance), options: work.appending(path: "new.cnf"))
                try oldClient.prepare()
                try newClient.prepare()
                try await oldClient.query("CREATE DATABASE shop")
                try await oldClient.query("CREATE TABLE items (id INT PRIMARY KEY); INSERT INTO items VALUES (1), (2), (3)", database: "shop")

                let socket = oldPaths.databaseSocket(.mysql, line: "8.0", port: oldPort).path(percentEncoded: false)
                let env = app.appending(path: ".env")
                try Data("DB_CONNECTION=mysql\nDB_HOST=localhost\nDB_PORT=\(oldPort)\nDB_SOCKET=\(socket)\nDB_DATABASE=shop\nDB_USERNAME=root\nDB_PASSWORD=\n".utf8).write(to: env)

                let answer = await engine.handle(.useNexusInfo(host: "shop.test"))

                guard case .useNexusInfo(let info?) = answer else {
                    Issue.record("no plan: \(answer)")
                    return
                }

                let choice = info.database?.choices.first
                let request = UseNexusRequest(host: "shop.test", instance: choice?.instance, copy: choice?.canCopy == true, changes: info.changes(choosing: choice?.instance))
                let done = await engine.handle(.useNexus(request))
                let after = await engine.handle(.useNexusInfo(host: "shop.test"))
                let rows = try await newClient.query("SELECT COUNT(*) FROM items", database: "shop")

                #expect(choice?.instance == "mysql-8.4")
                #expect(choice?.canCopy == true)
                #expect(done == .done(message: "Nexus copied shop to MySQL 8.4 and changed 3 keys. The old values stay as comment lines."))
                #expect(try String(contentsOf: env, encoding: .utf8) == "DB_CONNECTION=mysql\n# Before Nexus: DB_HOST=localhost\nDB_HOST=127.0.0.1\n# Before Nexus: DB_PORT=\(oldPort)\nDB_PORT=\(newPort)\n# Before Nexus: DB_SOCKET=\(socket)\nDB_DATABASE=shop\nDB_USERNAME=root\nDB_PASSWORD=\n")
                #expect(await engine.stateStore.current().useNexusKeys == ["shop.test": ["DB_HOST", "DB_PORT", "DB_SOCKET"]])
                #expect(after == .useNexusInfo(nil))
                #expect(rows == "3")
            }
        }
    }

    private static let useNexusDatabaseConfig = #"""
    <?php
    return [
        'default' => env('DB_CONNECTION', 'sqlite'),
        'connections' => [
            'mysql' => [
                'driver' => 'mysql',
                'url' => env('DB_URL'),
                'host' => env('DB_HOST', '127.0.0.1'),
                'port' => env('DB_PORT', '3306'),
                'database' => env('DB_DATABASE', 'laravel'),
                'username' => env('DB_USERNAME', 'root'),
                'password' => env('DB_PASSWORD', ''),
                'unix_socket' => env('DB_SOCKET', ''),
            ],
        ],
        'redis' => [
            'client' => 'phpredis',
        ],
    ];
    """#
}
