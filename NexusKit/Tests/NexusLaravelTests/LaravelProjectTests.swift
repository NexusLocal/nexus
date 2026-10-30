import Foundation
import NexusCore
import Testing
@testable import NexusLaravel

struct LaravelProjectTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-laravel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return URL(filePath: RealPath.of(folder), directoryHint: .isDirectory)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func theRootIsTheFolderWithArtisanAndBootstrapApp() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", to: "artisan", in: root)
        try write("", to: "bootstrap/app.php", in: root)
        try write("", to: "public/index.php", in: root)

        let found = LaravelProject.root(containing: root.appending(path: "public", directoryHint: .isDirectory))

        #expect(found.map(RealPath.of) == RealPath.of(root))
    }

    @Test func aFolderWithoutAnApplicationHasNoRoot() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", to: "artisan", in: root)

        #expect(LaravelProject.root(containing: root) == nil)
    }

    @Test func theKeysComeFromEveryFormOfAnEnvRead() {
        let source = """
        'a' => env('DB_DATABASE', 'shop'),
        'b' => env("REDIS_DB"),
        'c' => env( 'WITH_SPACE' ),
        'd' => Env::get('FROM_FACADE'),
        'e' => Env::getOrFail('REQUIRED'),
        'f' => getenv('FROM_GETENV'),
        'g' => env($dynamic),
        'h' => myenv('NOT_A_READ'),
        """

        #expect(LaravelProject.envKeys(in: source) == ["DB_DATABASE", "REDIS_DB", "WITH_SPACE", "FROM_FACADE", "REQUIRED", "FROM_GETENV"])
    }

    @Test func theKeysComeFromNestedConfigFilesAndFromTheFramework() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("<?php env('B_KEY'); env('A_KEY');", to: "config/app.php", in: root)
        try write("<?php env('NESTED');", to: "config/tenants/shop.php", in: root)
        try write("<?php env('FROM_FRAMEWORK'); env('A_KEY');", to: "vendor/laravel/framework/config/database.php", in: root)
        try write("env('NOT_PHP')", to: "config/notes.txt", in: root)

        #expect(LaravelProject.envKeys(of: root) == ["A_KEY", "B_KEY", "FROM_FRAMEWORK", "NESTED"])
    }
}
