import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

struct WordPressProbeTests {
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    private let root = shortTemporaryRoot()

    private func file(_ path: String, _ text: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var probe: WordPressProbe {
        WordPressProbe(php: URL(filePath: Self.realRuntimes!).appending(path: "php/8.4/bin/php"), environment: [:])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(1)))
    func theProbeReadsOnlyLiteralValuesWithoutARunOfTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try file("wp-config.php", #"""
            <?php
            // define('DB_NAME', 'commented');
            define( 'DB_NAME', 'shop' );
            \define('DB_USER', "root\tuser");
            define('DB_PASSWORD', getenv('SHOP_PASSWORD'));
            define('DB_HOST', '127.0.0.1:13307');
            define('WP_HOME', 'https://shop.test');
            define('WP_HOME', 'https://other.test');
            define('MULTISITE', true);
            define('SUBDOMAIN_INSTALL', false);
            define('DOMAIN_CURRENT_SITE', 'shop' . '.test');
            $table_prefix = 'shop_';
            file_put_contents('/tmp/nexus-probe-ran', 'yes');
            require_once ABSPATH . 'wp-settings.php';
            """#)
        let version = try file("wp-includes/version.php", "<?php\n$wp_version = '7.1.4';\n")

        let result = try await probe.run(config: config, version: version)

        #expect(result.version == "7.1.4")
        #expect(result.config == WordPressConfig(database: "shop", user: "root\tuser", host: "127.0.0.1:13307", tablePrefix: "shop_", multisite: true, subdomainInstall: false))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/nexus-probe-ran"))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(1)))
    func withoutAConfigFileTheProbeGivesOnlyTheVersion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let version = try file("wp-includes/version.php", "<?php\n$wp_version = '7.1.4';\n")

        let result = try await probe.run(config: nil, version: version)
        let missing = try await probe.run(config: nil, version: root.appending(path: "none.php"))

        #expect(result == WordPressProbe.Result(config: nil, version: "7.1.4"))
        #expect(missing == WordPressProbe.Result(config: nil, version: nil))
    }

    @Test func theMailWarningNamesEachSourceAndWhatTheUserCanDo() {
        let smtp = WordPressMailPlugin(folder: "wp-mail-smtp", name: "WP Mail SMTP", kind: .plugin)
        let theme = WordPressMailPlugin(folder: "shop", name: "shop", kind: .theme)
        let mailgun = WordPressMailPlugin(folder: "mailgun", name: "Mailgun", kind: .networkPlugin)

        #expect(NexusEngine.mailPluginWarning([smtp]) == "The plugin WP Mail SMTP sends each mail itself and not through Nexus. So a mail can reach a real person. Turn off the plugin in this copy of the site.")
        #expect(NexusEngine.mailPluginWarning([smtp, mailgun, theme]) == "The plugin WP Mail SMTP, the plugin Mailgun and the theme shop send each mail themselves and not through Nexus. So a mail can reach a real person. Turn off the plugins in this copy of the site. Nexus cannot turn off a theme, a file in mu-plugins or another file. Change that code in this copy of the site.")
    }

    @Test func theDatabaseOfANewSiteGetsItsNameFromTheHost() {
        #expect(NexusEngine.databaseBase(of: "blog.test") == "blog")
        #expect(NexusEngine.databaseBase(of: "My-Shop.test") == "my_shop")
        #expect(NexusEngine.databaseBase(of: "") == "wordpress")
    }

    @Test func sqlTextAndNamesGetTheirQuotes() {
        #expect(NexusEngine.sqlText("it's") == "'it''s'")
        #expect(NexusEngine.sqlText("a\\b") == "'a\\\\b'")
        #expect(NexusEngine.sqlName("we`ird") == "`we``ird`")
    }
}
