import Foundation
import Testing
@testable import NexusCore

struct WordPressCoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus WordPress \(UUID().uuidString)/shop", directoryHint: .isDirectory)

    private func file(_ path: String, _ text: String = "<?php\n") throws {
        try file(path, Data(text.utf8))
    }

    private func file(_ path: String, _ data: Data) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expected(_ path: String) -> String {
        "\(RealPath.of(root))/\(path)"
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @Test func wpCLIFindsAClassicSiteItselfAlsoFromAThemeFolder() throws {
        defer { cleanUp() }
        try file("wp-load.php")
        let theme = try folder("wp-content/themes/shop")

        #expect(WordPressCore.coreFolder(for: root, in: root) == nil)
        #expect(WordPressCore.coreFolder(for: theme, in: root) == nil)
    }

    @Test func aSiteWithWordPressInASubfolderGetsThatFolder() throws {
        defer { cleanUp() }
        try file("wordpress/wp-load.php")
        try file("wp-cli.yml", "color: true\n")
        let docs = try folder("docs")

        #expect(WordPressCore.coreFolder(for: root, in: root) == expected("wordpress"))
        #expect(WordPressCore.coreFolder(for: docs, in: root) == expected("wordpress"))
    }

    @Test func bedrockUsesItsConfigFileOrElseWebWp() throws {
        defer { cleanUp() }
        try file("web/wp/wp-load.php")
        let theme = try folder("web/app/themes/shop")

        let withoutConfig = WordPressCore.coreFolder(for: theme, in: root)
        try file("wp-cli.yml", "path: web/wp\nserver:\n  docroot: web\n")
        let withConfig = WordPressCore.coreFolder(for: theme, in: root)

        #expect(withoutConfig == expected("web/wp"))
        #expect(withConfig == nil)
    }

    @Test func onlyTheNearestConfigFileCounts() throws {
        defer { cleanUp() }
        try file("wordpress/wp-load.php")
        try file("wp-cli.yml", "path: wordpress\n")
        try file("wp-cli.local.yml", "url: https://shop.test\n")
        let theme = try folder("themes/shop")

        let localWins = WordPressCore.coreFolder(for: root, in: root)
        try FileManager.default.removeItem(at: root.appending(path: "wp-cli.local.yml"))
        let rootFile = WordPressCore.coreFolder(for: root, in: root)
        try file("themes/shop/wp-cli.yml", "color: false\n")
        let lowerFileWins = WordPressCore.coreFolder(for: theme, in: root)

        #expect(localWins == expected("wordpress"))
        #expect(rootFile == nil)
        #expect(lowerFileWins == expected("wordpress"))
    }

    @Test func anIndexFileThatLoadsWordPressFromASubfolderNeedsNoPath() throws {
        defer { cleanUp() }
        try file("index.php", "<?php\n// Loads core/wp-blog-header.php\ninclude 'core/wp-blog-header.php';\n")
        try file("core/wp-load.php")

        let onlyAMention = WordPressCore.coreFolder(for: root, in: root)
        try file("index.php", "<?php\nrequire __DIR__ . '/core/wp-blog-header.php';\n")
        let loads = WordPressCore.coreFolder(for: root, in: root)
        try file("index.php", Data("<?php\n// Caf\u{E9}\nrequire __DIR__ . '/core/wp-blog-header.php';\n".data(using: .isoLatin1)!))
        let latin1 = WordPressCore.coreFolder(for: root, in: root)

        #expect(onlyAMention == expected("core"))
        #expect(loads == nil)
        #expect(latin1 == nil)
    }

    @Test func twoFoldersWithWordPressOrNoneGiveNoPath() throws {
        defer { cleanUp() }
        try file("README.md", "# Shop\n")

        let none = WordPressCore.coreFolder(for: root, in: root)
        try file("one/wp-load.php")
        try file("two/wp-load.php")
        let two = WordPressCore.coreFolder(for: root, in: root)

        #expect(none == nil)
        #expect(two == nil)
    }

    @Test func aFolderOutsideTheSiteGetsNoPath() throws {
        defer { cleanUp() }
        try file("wordpress/wp-load.php")

        #expect(WordPressCore.coreFolder(for: root.deletingLastPathComponent(), in: root) == nil)
    }

    @Test func thePathOfNexusComesFirstUnlessTheUserChoosesTheWordPress() throws {
        defer { cleanUp() }
        let home = try folder("home")
        let core = "/Sites/shop/wordpress"
        let arguments = { (arguments: [String]) in WordPressCore.arguments(arguments, core: core, environment: [:], home: home) }

        #expect(arguments(["option", "get", "siteurl"]) == ["--path=\(core)", "option", "get", "siteurl"])
        #expect(arguments(["@prod", "option", "get", "siteurl"]) == ["@prod", "option", "get", "siteurl"])
        #expect(arguments(["option", "get", "siteurl", "--path=/other"]) == ["option", "get", "siteurl", "--path=/other"])
        #expect(arguments(["--ssh=me@prod", "plugin", "list"]) == ["--ssh=me@prod", "plugin", "list"])
        #expect(arguments(["--http=https://shop.example", "plugin", "list"]) == ["--http=https://shop.example", "plugin", "list"])
        #expect(arguments(["core", "download", "--locale=nl_NL"]) == ["core", "download", "--locale=nl_NL"])
        #expect(WordPressCore.arguments(["cli", "version"], core: nil, environment: [:], home: home) == ["cli", "version"])
    }

    @Test func aPathInTheGlobalConfigOfWPCLIWins() throws {
        defer { cleanUp() }
        let home = try folder("home")
        try file("home/.wp-cli/config.yml", "path: /Sites/blog\n")
        try file("other.yml", "color: false\n")
        let other = root.appending(path: "other.yml").path(percentEncoded: false)

        let fromHome = WordPressCore.arguments(["plugin", "list"], core: "/Sites/shop", environment: [:], home: home)
        let fromVariable = WordPressCore.arguments(["plugin", "list"], core: "/Sites/shop", environment: ["WP_CLI_CONFIG_PATH": other], home: home)

        #expect(fromHome == ["plugin", "list"])
        #expect(fromVariable == ["--path=/Sites/shop", "plugin", "list"])
    }
}
