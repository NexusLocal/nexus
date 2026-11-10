import Foundation
import NexusCore

// A migrate:fresh in a test run can remove all development data. PHPUnit sets the <env> and
// <server> values of phpunit.xml first. The immutable dotenv of Laravel does not replace them. With APP_ENV=testing Laravel reads
// .env.testing instead of .env and not both. So a key of the tests comes from phpunit.xml, else
// from the env file that the tests load.
public struct TestDatabaseCheck: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case sqliteMemory = "sqlite_memory"
        case separate
        case development
    }

    public let kind: Kind
    public let connection: String?
    public let database: String?
    // The file that names the database of the tests: phpunit.xml, .env.testing or .env.
    public let source: String
    public let developmentDatabase: String?
    // The file of PHPUnit that Nexus read: phpunit.xml or phpunit.xml.dist.
    public let phpunitFile: String
    // The env file that Laravel reads in tests, for example .env.testing, also when it does not
    // exist yet. Nil when phpunit.xml sets no APP_ENV. The tests then read .env.
    public let testEnvFile: String?
    // The tests use the server of the development database, with the same or another database.
    public let onDevelopmentServer: Bool
    // The DB_ keys that phpunit.xml sets. They win over each env file.
    public let phpunitDatabaseValues: [String: String]

    static let serverKeys = ["DB_CONNECTION", "DB_URL", "DB_HOST", "DB_PORT"]
    static let keys = serverKeys + ["DB_DATABASE"]

    public var usesDevelopmentDatabase: Bool {
        kind == .development
    }

    public var developmentDatabaseLabel: String {
        developmentDatabase ?? "the database of .env"
    }

    // When phpunit.xml itself names the development database, Nexus changes no file. The user
    // changes that line.
    var phpunitNamesDevelopmentDatabase: Bool {
        kind == .development && source == phpunitFile
    }

    // nil when the project has no phpunit.xml or phpunit.xml.dist.
    public static func check(projectFolder: URL) -> TestDatabaseCheck? {
        let candidates = ["phpunit.xml", "phpunit.xml.dist"]

        guard let phpunitName = candidates.first(where: { FileManager.default.fileExists(atPath: projectFolder.appending(path: $0).path(percentEncoded: false)) }),
              let phpunitText = try? String(contentsOf: projectFolder.appending(path: phpunitName), encoding: .utf8) else {
            return nil
        }

        let phpunit = phpunitValues(in: phpunitText)
        let development = EnvFile.values(of: projectFolder.appending(path: ".env"))
        let testEnvName = phpunit["APP_ENV"].map { ".env.\($0)" }
        let testEnvFile = testEnvName.map { projectFolder.appending(path: $0) }
        let testEnvExists = testEnvFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        let testEnv = testEnvExists ? EnvFile.values(of: testEnvFile!) : development
        let testEnvLabel = testEnvExists ? testEnvName! : ".env"

        return decide(phpunit: phpunit, phpunitFile: phpunitName, testEnv: testEnv, testEnvFile: testEnvLabel, development: development)
    }

    // testEnvFile is the file that the tests read now: the env file of APP_ENV when it exists,
    // else .env.
    static func decide(phpunit: [String: String], phpunitFile: String, testEnv: [String: String], testEnvFile: String, development: [String: String]) -> TestDatabaseCheck {
        func test(_ key: String) -> String? {
            phpunit[key] ?? testEnv[key]
        }

        let connection = test("DB_CONNECTION")
        let database = test("DB_DATABASE")
        let source = phpunit["DB_DATABASE"] != nil || phpunit["DB_CONNECTION"] != nil || phpunit["DB_URL"] != nil ? phpunitFile : testEnvFile

        let kind: Kind = if connection == "sqlite", database == ":memory:" {
            .sqliteMemory
        } else if keys.allSatisfy({ isSame($0, test($0), development[$0]) }) {
            .development
        } else {
            .separate
        }

        return TestDatabaseCheck(
            kind: kind,
            connection: connection,
            database: database,
            source: source,
            developmentDatabase: development["DB_DATABASE"],
            phpunitFile: phpunitFile,
            testEnvFile: phpunit["APP_ENV"].map { ".env.\($0)" },
            onDevelopmentServer: serverKeys.allSatisfy { isSame($0, test($0), development[$0]) },
            phpunitDatabaseValues: phpunit.filter { $0.key.hasPrefix("DB_") }
        )
    }

    // Only a clear difference makes the tests safe. A key that one side does not set counts as the
    // same. Laravel then often uses the same default. A wrong warning costs less than lost data.
    // 127.0.0.1, localhost and ::1 are one host.
    static func isSame(_ key: String, _ test: String?, _ development: String?) -> Bool {
        guard let test, let development else {
            return true
        }

        guard key == "DB_HOST" else {
            return test == development
        }

        let local: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        return test.lowercased() == development.lowercased() || (local.contains(test.lowercased()) && local.contains(development.lowercased()))
    }

    // The <env> and <server> values of phpunit.xml. A comment does not count. The default
    // phpunit.xml of Laravel has the SQLite lines in a comment.
    static func phpunitValues(in text: String) -> [String: String] {
        let withoutComments = text.replacing(/<!--[\s\S]*?-->/, with: "")
        var values: [String: String] = [:]

        for tag in withoutComments.matches(of: /<(?:env|server)\b[^>]*>/) {
            let element = String(tag.output)

            guard let name = attribute("name", in: element), let value = attribute("value", in: element) else {
                continue
            }

            values[name] = value
        }

        return values
    }

    private static func attribute(_ name: String, in element: String) -> String? {
        let pattern = try! Regex("\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")

        guard let match = element.firstMatch(of: pattern) else {
            return nil
        }

        let value = match.output[1].substring ?? match.output[2].substring
        return value.map { String($0).replacing("&amp;", with: "&").replacing("&quot;", with: "\"").replacing("&apos;", with: "'").replacing("&lt;", with: "<").replacing("&gt;", with: ">") }
    }
}
