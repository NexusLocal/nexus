import Foundation
import Testing
@testable import NexusCore

struct ErrorDetailsTests {
    @Test func anUncaughtExceptionOfPHPGivesItsMessage() {
        let output = """
            PHP Fatal error:  Uncaught Roots\\WPConfig\\Exceptions\\ConstantAlreadyDefinedException: Aborted trying to redefine constant 'DISABLE_WP_CRON'. in /tmp/shop/vendor/roots/wp-config/src/Config.php:106
            Stack trace:
            #0 /tmp/shop/vendor/roots/wp-config/src/Config.php(74): Roots\\WPConfig\\Config::defined('DISABLE_WP_CRON')
            """

        #expect(ErrorDetails.summary(of: output) == "Aborted trying to redefine constant 'DISABLE_WP_CRON'.")
    }

    @Test func anErrorOfWPCLIOrMySQLGivesThatLine() {
        #expect(ErrorDetails.summary(of: "Warning: something\nError: Error establishing a database connection") == "Error establishing a database connection.")
        #expect(ErrorDetails.summary(of: "mysql: [Warning] Using a password\nERROR 1045 (28000): Access denied for user 'root'@'localhost'") == "ERROR 1045 (28000): Access denied for user 'root'@'localhost'.")
        #expect(ErrorDetails.summary(of: "#0 a trace\n\nThe environment file is invalid!") == "The environment file is invalid!")
    }

    @Test func anErrorWinsOverAWarningAndAConsoleGivesTheLineBelowItsPlace() {
        #expect(ErrorDetails.summary(of: "PHP Warning: Module 'xdebug' already loaded\nPHP Parse error: syntax error, unexpected '}' in /tmp/a.php on line 3") == "syntax error, unexpected '}'.")
        #expect(ErrorDetails.summary(of: "\nIn Connection.php line 825:\n\n  SQLSTATE[HY000] [2002] Connection refused\n") == "SQLSTATE[HY000] [2002] Connection refused.")
        #expect(ErrorDetails.summary(of: "PHP Deprecated: old call\nThe real cause") == "The real cause.")
    }

    @Test func aLongOutputKeepsWholeLinesAtTheStartAndTheEnd() {
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = ErrorDetails.excerpt(text, head: 30, tail: 30)

        #expect(excerpt.hasPrefix("line 1\nline 2\nline 3\nline 4\n...\n"))
        #expect(excerpt.hasSuffix("line 98\nline 99\nline 100"))
    }

    @Test func aKeyWithoutAValueKeepsTheNextLine() {
        #expect(ActivityLog.withoutSecrets("DB_PASSWORD=\nDB_NAME=shop\npassword: secret") == "DB_PASSWORD=\nDB_NAME=shop\npassword=<hidden>")
    }

    @Test func aLongLineEndsAtAWord() {
        let summary = ErrorDetails.summary(of: String(repeating: "word ", count: 100))

        #expect(summary.count <= 301)
        #expect(summary.hasSuffix("word…"))
    }

    @Test func aMessageLosesItsReferenceAndKeepsTheNewestOne() {
        let message = "WP-CLI did not load the site. php stopped: Aborted. (details 3F2A9C) A plugin can then send mail. (details 0A1B2C)"
        let split = ErrorDetails.split(message)

        #expect(split.text == "WP-CLI did not load the site. php stopped: Aborted. A plugin can then send mail.")
        #expect(split.id == "0A1B2C")
    }

    @Test func anEntryComesBackByItsReferenceWithoutPasswords() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "nexus-errors-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }

        let id = try #require(ErrorDetails.record(program: "php", status: 255, output: "first line\nDB_PASSWORD=secret\nlast line", in: file))
        let other = try #require(ErrorDetails.record(program: "mysql", status: 1, output: "other", in: file))
        let entry = try #require(ErrorDetails.entry(id, in: file))

        #expect(entry.output == "first line\nDB_PASSWORD=<hidden>\nlast line")
        #expect(entry.header.hasSuffix("php, exit status 255"))
        #expect(ErrorDetails.entry(other, in: file)?.output == "other")
        #expect(ErrorDetails.record(program: "git", status: 1, output: "  \n", in: file) == nil)
    }
}
