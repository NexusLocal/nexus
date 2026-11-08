import Foundation
import Testing
@testable import NexusCore

struct WordPressWorkspaceConfigTests {
    private let config = """
    <?php
    // ** Database settings ** //
    define( 'DB_NAME', 'blog' );
    define( 'DB_USER', 'root' );
    define( 'DB_HOST', '127.0.0.1:13307' );
    // define( 'WP_HOME', 'https://old.test' );
    $table_prefix = 'wp_';
    define( 'WP_DEBUG', false );
    define( 'WP_HOME', 'https://blog.test' );
    require_once ABSPATH . 'wp-settings.php';
    """

    @Test func theIncludeLinesComeAfterTheOpeningLineAndEachDefineGetsAGuard() throws {
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: config))
        let lines = change.text.components(separatedBy: "\n")

        #expect(Array(lines[1...3]) == WordPressWorkspaceConfig.includeLines)
        #expect(lines.contains("defined( 'DB_HOST' ) || define( 'DB_HOST', '127.0.0.1:13307' );"))
        #expect(lines.contains("defined( 'WP_HOME' ) || define( 'WP_HOME', 'https://blog.test' );"))
        #expect(lines.contains("// define( 'WP_HOME', 'https://old.test' );"))
        #expect(lines.contains("defined( 'DB_NAME' ) || define( 'DB_NAME', 'blog' );"))
        #expect(lines.contains("define( 'WP_DEBUG', false );"))
        #expect(WordPressWorkspaceConfig.loadsIncludeFile(change.text))
    }

    @Test func theSheetShowsTheChangedLinesWithTheLineBeforeEachOne() throws {
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: config))

        #expect(change.lines == [
            TextChangeLine(.same, "<?php"),
            TextChangeLine(.added, "if (is_file(__DIR__ . '/wp-config-nexus.php')) {"),
            TextChangeLine(.added, "    require __DIR__ . '/wp-config-nexus.php';"),
            TextChangeLine(.added, "}"),
            TextChangeLine(.same, "// ** Database settings ** //"),
            TextChangeLine(.removed, "define( 'DB_NAME', 'blog' );"),
            TextChangeLine(.added, "defined( 'DB_NAME' ) || define( 'DB_NAME', 'blog' );"),
            TextChangeLine(.removed, "define( 'DB_USER', 'root' );"),
            TextChangeLine(.added, "defined( 'DB_USER' ) || define( 'DB_USER', 'root' );"),
            TextChangeLine(.removed, "define( 'DB_HOST', '127.0.0.1:13307' );"),
            TextChangeLine(.added, "defined( 'DB_HOST' ) || define( 'DB_HOST', '127.0.0.1:13307' );"),
            TextChangeLine(.same, "…"),
            TextChangeLine(.same, "define( 'WP_DEBUG', false );"),
            TextChangeLine(.removed, "define( 'WP_HOME', 'https://blog.test' );"),
            TextChangeLine(.added, "defined( 'WP_HOME' ) || define( 'WP_HOME', 'https://blog.test' );"),
        ])
    }

    @Test func theSheetDoesNotShowThePassword() throws {
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: "<?php\ndefine( 'DB_PASSWORD', 'secret' );\n"))

        #expect(change.lines.suffix(2) == [
            TextChangeLine(.removed, "define( 'DB_PASSWORD', '••••••' );"),
            TextChangeLine(.added, "defined( 'DB_PASSWORD' ) || define( 'DB_PASSWORD', '••••••' );"),
        ])
        #expect(change.text.contains("define( 'DB_PASSWORD', 'secret' );"))
    }

    @Test func theNewLinesComeAfterADeclareAndANamespaceStatement() throws {
        let text = "<?php\n/** Settings */\ndeclare(strict_types=1);\nnamespace Site;\ndefine( 'DB_HOST', '127.0.0.1:13307' );\n"
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: text))
        let lines = change.text.components(separatedBy: "\n")

        #expect(Array(lines[0...3]) == ["<?php", "/** Settings */", "declare(strict_types=1);", "namespace Site;"])
        #expect(Array(lines[4...6]) == WordPressWorkspaceConfig.includeLines)
        #expect(WordPressWorkspaceConfig.loadsIncludeFile(change.text))
    }

    @Test func aFileWithCRLFLineEndsAndAByteOrderMarkKeepsThem() throws {
        let text = "\u{FEFF}<?php\r\ndefine( 'DB_HOST', '127.0.0.1:13307' );\r\n"
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: text))

        #expect(change.text == "\u{FEFF}<?php\r\n" + WordPressWorkspaceConfig.includeLines.map { "\($0)\r\n" }.joined() + "defined( 'DB_HOST' ) || define( 'DB_HOST', '127.0.0.1:13307' );\r\n")
        #expect(change.lines.first == TextChangeLine(.same, "\u{FEFF}<?php"))
    }

    @Test func codeOnTheOpeningLineGoesBelowTheNewLines() throws {
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: "<?php define( 'DB_HOST', '127.0.0.1:13307' );\n"))

        #expect(change.text == "<?php\n" + WordPressWorkspaceConfig.includeLines.joined(separator: "\n") + "\ndefined( 'DB_HOST' ) || define( 'DB_HOST', '127.0.0.1:13307' );\n")
        #expect(WordPressWorkspaceConfig.loadsIncludeFile(change.text))
    }

    @Test func aFileThatLoadsTheIncludeFileAlreadyNeedsNoChange() throws {
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: config))

        #expect(WordPressWorkspaceConfig.addingIncludeLines(to: change.text) == nil)
    }

    @Test func anIncludeAfterTheDefineOfDBHostDoesNotCount() {
        let late = "<?php\ndefine( 'DB_HOST', '127.0.0.1:13307' );\n@include __DIR__ . '/wp-config-nexus.php';\n"
        let early = "<?php\n@include __DIR__ . '/wp-config-nexus.php';\ndefine( 'DB_HOST', '127.0.0.1:13307' );\n"
        let commented = "<?php\n// require __DIR__ . '/wp-config-nexus.php';\ndefine( 'DB_HOST', '127.0.0.1:13307' );\n"

        #expect(!WordPressWorkspaceConfig.loadsIncludeFile(late))
        #expect(WordPressWorkspaceConfig.loadsIncludeFile(early))
        #expect(!WordPressWorkspaceConfig.loadsIncludeFile(commented))
    }

    @Test func aFileWithoutAnOpeningLineGetsNoChange() {
        #expect(WordPressWorkspaceConfig.addingIncludeLines(to: "<?phpx\n") == nil)
        #expect(WordPressWorkspaceConfig.settingValues([("DB_HOST", "127.0.0.1:20001")], workspace: "fix", in: "text\n<?php\n") == nil)
    }

    @Test func theCopyInAWorktreeGetsTheValuesAtItsStartAndASecondSetupGivesTheSameFile() throws {
        let values = [(name: "DB_HOST", value: "127.0.0.1:20001"), (name: "WP_HOME", value: "https://blog-fix.test")]
        let first = try #require(WordPressWorkspaceConfig.settingValues(values, workspace: "fix", in: config))
        let second = try #require(WordPressWorkspaceConfig.settingValues(values, workspace: "fix", in: first))
        let lines = first.components(separatedBy: "\n")

        #expect(Array(lines[1...4]) == [
            WordPressWorkspaceConfig.blockStart,
            "define( 'DB_HOST', '127.0.0.1:20001' );",
            "define( 'WP_HOME', 'https://blog-fix.test' );",
            WordPressWorkspaceConfig.blockEnd,
        ])
        #expect(lines.contains("defined( 'DB_HOST' ) || define( 'DB_HOST', '127.0.0.1:13307' );"))
        #expect(second == first)
    }

    @Test func theIncludeFileDefinesEachValue() {
        let text = WordPressWorkspaceConfig.includeFileText([("DB_PASSWORD", "0123"), ("DB_HOST", "127.0.0.1:20001"), ("WP_REDIS_DATABASE", "16"), ("WP_HOME", "https://it's.test")], workspace: "fix")

        #expect(text.hasPrefix("<?php\n"))
        #expect(text.contains("define( 'DB_PASSWORD', '0123' );\n"))
        #expect(text.contains("define( 'DB_HOST', '127.0.0.1:20001' );\n"))
        #expect(text.contains("define( 'WP_REDIS_DATABASE', 16 );\n"))
        #expect(text.contains(#"define( 'WP_HOME', 'https://it\'s.test' );"#))
    }

    @Test func aDefineWithAGuardOrInAnotherCallStays() throws {
        let text = "<?php\ndefined( 'DB_HOST' ) || define( 'DB_HOST', 'a' );\nConfig::define( 'WP_HOME', 'b' );\n\\define( 'WP_SITEURL', 'c' );\n"
        let change = try #require(WordPressWorkspaceConfig.addingIncludeLines(to: text))

        #expect(change.text.contains("\ndefined( 'DB_HOST' ) || define( 'DB_HOST', 'a' );\n"))
        #expect(change.text.contains("\nConfig::define( 'WP_HOME', 'b' );\n"))
        #expect(change.text.contains("\ndefined( 'WP_SITEURL' ) || \\define( 'WP_SITEURL', 'c' );\n"))
    }
}
