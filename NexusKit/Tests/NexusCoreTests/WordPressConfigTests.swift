import Foundation
import Testing
@testable import NexusCore

struct WordPressConfigTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus WordPress Config \(UUID().uuidString)", directoryHint: .isDirectory)

    private func file(_ path: String, _ text: String = "<?php\n") throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test(arguments: [
        ("127.0.0.1:13307", DatabaseAddress.tcp(host: "127.0.0.1", port: 13307)),
        ("127.0.0.1", .tcp(host: "127.0.0.1", port: 3306)),
        ("db.example.com:3307", .tcp(host: "db.example.com", port: 3307)),
        ("[::1]:13307", .tcp(host: "::1", port: 13307)),
        ("localhost", .socket(path: nil)),
        ("LOCALHOST:13307", .socket(path: nil)),
        ("localhost:/tmp/mysql.sock", .socket(path: "/tmp/mysql.sock")),
        (":/tmp/mysql.sock", .socket(path: "/tmp/mysql.sock")),
    ])
    func dbHostGivesTheAddressThatPHPUses(dbHost: String, address: DatabaseAddress) {
        #expect(DatabaseAddress(dbHost: dbHost) == address)
    }

    @Test func onlyAHostOnThisMacHasALocalPort() {
        #expect(DatabaseAddress(dbHost: "127.0.0.1:13307").localPort == 13307)
        #expect(DatabaseAddress(dbHost: "[::1]").localPort == 3306)
        #expect(DatabaseAddress(dbHost: "db.example.com:13307").localPort == nil)
        #expect(DatabaseAddress(dbHost: "localhost:13307").localPort == nil)
    }

    @Test func wordPressReadsWpConfigInItsFolderOrInTheFolderAbove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("own/wp-config.php")
        try file("above/wp-config.php")
        try file("above/wordpress/wp-load.php")
        try file("blocked/wp-config.php")
        try file("blocked/wp-settings.php")
        try file("blocked/wordpress/wp-load.php")
        let folder = { (path: String) in root.appending(path: path, directoryHint: .isDirectory) }

        #expect(WordPressFiles.configFile(core: folder("own"))?.lastPathComponent == "wp-config.php")
        #expect(WordPressFiles.configFile(core: folder("above/wordpress")) == folder("above").appending(path: "wp-config.php"))
        #expect(WordPressFiles.configFile(core: folder("blocked/wordpress")) == nil)
    }

    @Test func bedrockReadsEnvThenEnvLocalAndDatabaseURLWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("plain/.env", "DB_NAME='shop'\nDB_USER=root\nDB_PASSWORD=secret\nWP_HOME=https://shop.test\nWP_SITEURL=\"${WP_HOME}/wp\"\n")
        try file("plain/.env.local", "DB_NAME=shop_local\n")
        try file("url/.env", "DB_NAME=ignored\nDATABASE_URL=mysql://wp:pw@127.0.0.1:13307/blog\n")
        let plain = WordPressFiles.bedrockConfig(project: root.appending(path: "plain", directoryHint: .isDirectory))
        let url = WordPressFiles.bedrockConfig(project: root.appending(path: "url", directoryHint: .isDirectory))

        #expect(plain == WordPressConfig(database: "shop_local", user: "root", password: "secret", host: "localhost", tablePrefix: "wp_", home: "https://shop.test", siteURL: "https://shop.test/wp"))
        #expect(url.database == "blog")
        #expect(url.user == "wp")
        #expect(url.password == "pw")
        #expect(url.host == "127.0.0.1:13307")
    }

    @Test func dbHostGetsTheNewValueAndKeepsTheOldLineAsAComment() {
        let text = "<?php\n// define('DB_HOST', 'old');\n\tdefine( 'DB_HOST', 'localhost' );\ndefine('DB_NAME', 'blog');\n"
        let twice = "<?php\nif ($local) {\n    define('DB_HOST', 'localhost');\n} else {\n    define('DB_HOST', 'db');\n}\n"

        let changed = WordPressFiles.settingDBHost("127.0.0.1:13307", in: text)

        #expect(changed == "<?php\n// define('DB_HOST', 'old');\n\t// Before Nexus: define( 'DB_HOST', 'localhost' );\n\tdefine( 'DB_HOST', '127.0.0.1:13307' );\ndefine('DB_NAME', 'blog');\n")
        #expect(WordPressFiles.settingDBHost("127.0.0.1:13307", in: twice) == nil)
        #expect(WordPressFiles.settingDBHost("127.0.0.1:13307", in: "<?php\n") == nil)
        #expect(WordPressFiles.settingDBHost("x'y", in: text) == nil)
        #expect(WordPressFiles.settingDBHost("127.0.0.1:13307", in: "<?php\ndefine('DB_HOST', 'localhost'); define('DB_NAME', 'blog');\n") == nil)
        #expect(WordPressFiles.settingDBHost("127.0.0.1:13307", in: "<?php\ndefine('DB_HOST', 'localhost'); // the socket\n") != nil)
    }

    @Test func aTablePrefixWithOtherCharactersIsNotSafe() {
        #expect(WordPressConfig(tablePrefix: "wp_2_").safeTablePrefix == "wp_2_")
        #expect(WordPressConfig(tablePrefix: "wp`;DROP").safeTablePrefix == nil)
        #expect(WordPressConfig(tablePrefix: "").safeTablePrefix == nil)
    }
}
