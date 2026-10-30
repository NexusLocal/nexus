import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private static let realProbeRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    private func probeRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func probeFailure(_ engine: NexusEngine, folder: URL, php: String? = nil) async -> String? {
        guard case .failure(let message) = await engine.handle(.probe(folder: folder.path(percentEncoded: false), php: php)) else {
            return nil
        }

        return message
    }

    private func laravelFiles(in app: URL) throws {
        try write("", to: "artisan", in: app)
        try write("{}", to: "composer.json", in: app)
        try write("<?php return (object) ['root' => dirname(__DIR__)];", to: "bootstrap/app.php", in: app)
    }

    @Test func aFolderOutsideALaravelApplicationGivesAClearFailure() async throws {
        let root = probeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root)

        let failure = await probeFailure(engine, folder: folder)

        #expect(failure == ProbeError.notLaravel(folder: folder.path(percentEncoded: false)).description)
    }

    @Test func aPHPThatIsNotInstalledGivesTheInstallCommand() async throws {
        let root = probeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "shop", directoryHint: .isDirectory)
        try laravelFiles(in: app)
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])

        let failure = await probeFailure(engine, folder: app, php: "8.4")

        #expect(failure?.contains("nexus install php 8.4") == true)
    }

    @Test func theRootOfAnApplicationUsesThePHPOfASiteOnItsPublicFolder() async throws {
        let root = probeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "shop", directoryHint: .isDirectory)
        try laravelFiles(in: app)
        let publicFolder = app.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: publicFolder, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])

        let failure = await probeFailure(engine, folder: app)

        #expect(failure?.contains("nexus install php 8.4") == true)
    }

    @Test func aFolderOfAnotherSiteInTheApplicationUsesThePHPOfTheApplication() async throws {
        let root = probeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "shop", directoryHint: .isDirectory)
        try laravelFiles(in: app)
        let publicFolder = app.appending(path: "public", directoryHint: .isDirectory)
        let docs = app.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: publicFolder, php: "8.4"), Site(host: "docs.test", folder: docs, php: "8.3")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])

        let failure = await probeFailure(engine, folder: docs)

        #expect(failure?.contains("nexus install php 8.4") == true)
    }

    @Test(.enabled(if: realProbeRuntimes != nil), .timeLimit(.minutes(1)))
    func aRealPHPReadsWhichKeyFeedsEachSettingAndChangesNoFile() async throws {
        let root = probeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        let php = await engine.paths.runtime("php", line: "8.5")
        try FileManager.default.createSymbolicLink(at: php.appending(path: "bin"), withDestinationURL: URL(filePath: Self.realProbeRuntimes!).appending(path: "php/8.5/bin"))

        let app = root.appending(path: "shop", directoryHint: .isDirectory)
        try write("", to: "artisan", in: app)
        try write("DB_DATABASE=shop\nREDIS_DB=2\n", to: ".env", in: app)
        try write(Self.bootstrappers, to: "vendor/autoload.php", in: app)
        try write(Self.bootstrapApp, to: "bootstrap/app.php", in: app)
        try write(Self.databaseConfig, to: "config/database.php", in: app)
        let before = try Self.snapshot(of: app)

        let response = await engine.handle(.probe(folder: app.path(percentEncoded: false), php: "8.5"))

        guard case .configuration(let configuration) = response else {
            Issue.record("No configuration: \(response)")
            return
        }

        #expect(configuration.version == "1.2.3")
        #expect(configuration.databaseConnections == ["main", "cms", "legacy"])
        #expect(configuration.settings["database.connections.legacy.database"] == ConfigSetting(value: .text("shop_legacy")))
        #expect(configuration.redisConnections == ["default"])
        #expect(configuration.settings["database.default"] == ConfigSetting(value: .text("main")))
        #expect(configuration.settings["database.connections.main.database"] == ConfigSetting(value: .text("shop"), keys: ["DB_DATABASE"], exact: true))
        #expect(configuration.settings["database.connections.cms.database"] == ConfigSetting(value: .text("shop_cms")))
        #expect(configuration.settings["database.redis.default.database"] == ConfigSetting(value: .number(2), keys: ["REDIS_DB"], exact: true))
        #expect(configuration.settings["database.redis.default.port"] == ConfigSetting(value: .number(6379), keys: ["REDIS_PORT"], exact: true))
        #expect(configuration.settings["database.redis.options.prefix"] == ConfigSetting(value: .text("shop:"), keys: ["REDIS_PREFIX"], exact: false))
        #expect(configuration.settings["session.lifetime"] == ConfigSetting(value: .number(7200)))
        #expect(try Self.snapshot(of: app) == before)
    }

    private static func snapshot(of folder: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var snapshot: [String: Data] = [:]

        for file in files where !file.hasDirectoryPath {
            snapshot[file.path(percentEncoded: false)] = try Data(contentsOf: file)
        }

        return snapshot
    }

    private static let bootstrappers = #"""
    <?php
    namespace Illuminate\Foundation\Bootstrap {
        class LoadEnvironmentVariables {
            public function bootstrap($app) {
                foreach (file("{$app->root}/.env", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                    [$key, $value] = explode('=', $line, 2);
                    $_SERVER[$key] ??= $value;
                }
            }
        }

        class LoadConfiguration {
            public function bootstrap($app) {
                $app['config'] = new class(['database' => require "{$app->root}/config/database.php", 'session' => ['lifetime' => (int) env('SESSION_LIFETIME', 120) * 60]]) {
                    public function __construct(private array $items) {}
                    public function all() { return $this->items; }
                    public function get($path, $default) {
                        return array_reduce(explode('.', $path), fn ($items, $key) => $items[$key] ?? $default, $this->items);
                    }
                };
            }
        }
    }

    namespace {
        function env($key, $default = null) {
            return $_SERVER[$key] ?? $default;
        }
    }
    """#

    private static let bootstrapApp = #"""
    <?php
    return new class(dirname(__DIR__)) extends ArrayObject {
        public function __construct(public string $root) { parent::__construct(); }
        public function version() { return '1.2.3'; }
    };
    """#

    private static let databaseConfig = #"""
    <?php
    return [
        'default' => 'main',
        'connections' => [
            'main' => ['driver' => 'mysql', 'database' => env('DB_DATABASE', 'forge')],
            'cms' => ['driver' => 'mysql', 'database' => 'shop_cms'],
            'legacy' => ['driver' => 'mysql', 'database' => env('USE_LEGACY') ? env('LEGACY_DB') : 'shop_legacy'],
        ],
        'redis' => [
            'client' => 'phpredis',
            'options' => ['prefix' => env('REDIS_PREFIX', 'shop').':'],
            'default' => ['database' => (int) env('REDIS_DB', 0), 'port' => (int) env('REDIS_PORT', 6379)],
        ],
    ];
    """#
}
