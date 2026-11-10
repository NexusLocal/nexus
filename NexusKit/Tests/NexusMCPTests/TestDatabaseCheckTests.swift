import Foundation
import Testing
@testable import NexusMCP

struct TestDatabaseCheckTests {
    private static let laravelPHPUnit = """
    <phpunit>
        <php>
            <env name="APP_ENV" value="testing"/>
            <env name="CACHE_STORE" value="array"/>
            <!-- <env name="DB_CONNECTION" value="sqlite"/> -->
            <!-- <env name="DB_DATABASE" value=":memory:"/> -->
        </php>
    </phpunit>
    """

    private let mysql = ["DB_CONNECTION": "mysql", "DB_HOST": "127.0.0.1", "DB_PORT": "3306", "DB_DATABASE": "db_finly"]

    @Test func theDefaultPHPUnitOfLaravelUsesTheDevelopmentDatabase() {
        let phpunit = TestDatabaseCheck.phpunitValues(in: Self.laravelPHPUnit)
        let check = TestDatabaseCheck.decide(phpunit: phpunit, phpunitFile: "phpunit.xml", testEnv: mysql, testEnvFile: ".env", development: mysql)

        #expect(phpunit["DB_CONNECTION"] == nil)
        #expect(check.kind == .development)
        #expect(check.developmentDatabase == "db_finly")
        #expect(check.source == ".env")
        #expect(!check.phpunitNamesDevelopmentDatabase)
    }

    @Test func sqliteInMemoryIsSafe() {
        let phpunit = ["APP_ENV": "testing", "DB_CONNECTION": "sqlite", "DB_DATABASE": ":memory:"]
        let check = TestDatabaseCheck.decide(phpunit: phpunit, phpunitFile: "phpunit.xml", testEnv: mysql, testEnvFile: ".env", development: mysql)

        #expect(check.kind == .sqliteMemory)
    }

    @Test func anEnvTestingWithItsOwnDatabaseIsSafe() {
        var testing = mysql
        testing["DB_DATABASE"] = "db_finly_testing"
        let check = TestDatabaseCheck.decide(phpunit: ["APP_ENV": "testing"], phpunitFile: "phpunit.xml", testEnv: testing, testEnvFile: ".env.testing", development: mysql)

        #expect(check.kind == .separate)
        #expect(check.database == "db_finly_testing")
        #expect(check.source == ".env.testing")
        #expect(check.testEnvFile == ".env.testing")
        #expect(check.onDevelopmentServer)
    }

    @Test func phpunitThatNamesTheDevelopmentDatabaseSaysSo() {
        let check = TestDatabaseCheck.decide(phpunit: ["DB_DATABASE": "db_finly"], phpunitFile: "phpunit.xml.dist", testEnv: mysql, testEnvFile: ".env", development: mysql)

        #expect(check.kind == .development)
        #expect(check.phpunitNamesDevelopmentDatabase)
    }

    @Test(arguments: [
        ["DB_CONNECTION": "mysql", "DB_DATABASE": "db_finly"],
        ["DB_CONNECTION": "mysql", "DB_HOST": "localhost", "DB_DATABASE": "db_finly"],
        ["DB_DATABASE": "db_finly"],
    ])
    func anEnvTestingWithTheSameDatabaseInOtherWordsIsTheDevelopmentDatabase(testing: [String: String]) {
        let check = TestDatabaseCheck.decide(phpunit: ["APP_ENV": "testing"], phpunitFile: "phpunit.xml", testEnv: testing, testEnvFile: ".env.testing", development: mysql)

        #expect(check.kind == .development)
    }

    @Test func anotherPortIsAnotherServer() {
        let check = TestDatabaseCheck.decide(phpunit: ["DB_PORT": "3307"], phpunitFile: "phpunit.xml", testEnv: mysql, testEnvFile: ".env", development: mysql)

        #expect(check.kind == .separate)
        #expect(!check.onDevelopmentServer)
        #expect(check.testEnvFile == nil)
    }

    @Test func theSQLiteFileOfANewLaravelSiteIsTheDevelopmentDatabase() {
        let development = ["DB_CONNECTION": "sqlite"]
        let check = TestDatabaseCheck.decide(phpunit: ["DB_CONNECTION": "sqlite"], phpunitFile: "phpunit.xml", testEnv: development, testEnvFile: ".env", development: development)

        #expect(check.kind == .development)
    }

    @Test func attributesInAnyOrderAndWithSingleQuotesCount() {
        let values = TestDatabaseCheck.phpunitValues(in: "<server value='a&amp;b' name='DB_PASSWORD' force='true'/><env name=\"DB_DATABASE\" value=\"x\" />")

        #expect(values == ["DB_PASSWORD": "a&b", "DB_DATABASE": "x"])
    }

    @Test func aProjectWithoutPHPUnitHasNoCheck() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(TestDatabaseCheck.check(projectFolder: folder) == nil)

        try Self.laravelPHPUnit.write(to: folder.appending(path: "phpunit.xml"), atomically: true, encoding: .utf8)
        try "DB_CONNECTION=mysql\nDB_DATABASE=shop\n".write(to: folder.appending(path: ".env"), atomically: true, encoding: .utf8)

        #expect(TestDatabaseCheck.check(projectFolder: folder)?.kind == .development)

        try "DB_CONNECTION=mysql\nDB_DATABASE=shop_testing\n".write(to: folder.appending(path: ".env.testing"), atomically: true, encoding: .utf8)

        #expect(TestDatabaseCheck.check(projectFolder: folder)?.kind == .separate)
    }
}
