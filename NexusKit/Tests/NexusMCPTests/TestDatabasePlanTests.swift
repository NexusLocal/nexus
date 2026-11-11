import Foundation
import Testing
@testable import NexusMCP

struct TestDatabasePlanTests {
    private static let phpunit = """
    <phpunit>
        <php>
            <env name="APP_ENV" value="testing"/>
        </php>
    </phpunit>
    """

    private static let env = """
    APP_KEY=base64:abc
    # The database
    DB_CONNECTION=mysql
    DB_HOST=127.0.0.1
    DB_PORT=3306
    DB_DATABASE=db_finly
    DB_PASSWORD=secret
    MAIL_MAILER=smtp
    """

    private func project(phpunit: String = phpunit, env: String = env, envTesting: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try phpunit.write(to: folder.appending(path: "phpunit.xml"), atomically: true, encoding: .utf8)
        try env.write(to: folder.appending(path: ".env"), atomically: true, encoding: .utf8)
        try envTesting?.write(to: folder.appending(path: ".env.testing"), atomically: true, encoding: .utf8)
        return folder
    }

    private func read(_ name: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    @Test func aNewEnvTestingIsACopyOfEnvWithOnlyTheDatabaseChanged() throws {
        let folder = try project()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = try #require(TestDatabasePlan.make(for: .database("db_finly_testing"), check: check, projectFolder: folder))
        let backup = try plan.apply()

        #expect(plan.file == ".env.testing")
        #expect(plan.createsFile)
        #expect(backup == nil)
        #expect(try read(".env.testing", in: folder) == Self.env.replacing("DB_DATABASE=db_finly", with: "DB_DATABASE=db_finly_testing"))
        #expect(try read(".env", in: folder) == Self.env)
        #expect(TestDatabaseCheck.check(projectFolder: folder)?.kind == .separate)
    }

    @Test func anExistingEnvTestingKeepsItsOtherLinesAndGetsABackup() throws {
        let testing = "APP_KEY=base64:test\nDB_DATABASE=db_finly\n"
        let folder = try project(envTesting: testing)
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = try #require(TestDatabasePlan.make(for: .sqliteMemory, check: check, projectFolder: folder))
        let backup = try plan.apply()

        #expect(!plan.createsFile)
        #expect(backup == ".env.testing.backup")
        #expect(try read(".env.testing.backup", in: folder) == testing)
        #expect(try read(".env.testing", in: folder) == "APP_KEY=base64:test\nDB_DATABASE=:memory:\nDB_CONNECTION=sqlite\n")
        #expect(TestDatabaseCheck.check(projectFolder: folder)?.kind == .sqliteMemory)
    }

    @Test func aSecondBackupDoesNotReplaceTheFirst() throws {
        let folder = try project(envTesting: "DB_DATABASE=db_finly\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        try "old".write(to: folder.appending(path: ".env.testing.backup"), atomically: true, encoding: .utf8)
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let backup = try TestDatabasePlan.make(for: .database("other"), check: check, projectFolder: folder)?.apply()

        #expect(backup == ".env.testing.backup-2")
        #expect(try read(".env.testing.backup", in: folder) == "old")
    }

    @Test func aDatabaseURLBecomesEmpty() throws {
        let folder = try project(env: Self.env + "\nDB_URL=mysql://root@127.0.0.1/db_finly\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = try #require(TestDatabasePlan.make(for: .database("db_finly_testing"), check: check, projectFolder: folder))

        #expect(plan.changes.map(\.key) == ["DB_DATABASE", "DB_URL"])
        #expect(plan.changeText == "DB_DATABASE=db_finly_testing and DB_URL=")
    }

    @Test func anEnvTestingOnAnotherServerGetsTheServerOfEnv() throws {
        let folder = try project(envTesting: "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3307\nDB_DATABASE=other\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = try #require(TestDatabasePlan.make(for: .database("db_finly_testing"), check: check, projectFolder: folder))

        #expect(!check.onDevelopmentServer)
        #expect(plan.changes.map(\.key) == ["DB_PORT", "DB_PASSWORD", "DB_DATABASE"])
        #expect(plan.changeText == "DB_PORT=3306, the DB_PASSWORD of .env and DB_DATABASE=db_finly_testing")
        #expect(plan.backupFile == ".env.testing.backup")
    }

    @Test func aPlanForTheValuesThatTheFileHasChangesNothing() throws {
        let folder = try project(envTesting: Self.env.replacing("db_finly", with: "db_finly_testing"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = try #require(TestDatabasePlan.make(for: .database("db_finly_testing"), check: check, projectFolder: folder))

        #expect(plan.changesNothing)
        #expect(try plan.apply() == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".env.testing.backup").path(percentEncoded: false)))
    }

    @Test func phpunitWithTheSameConnectionStillGetsAPlan() throws {
        let folder = try project(phpunit: Self.phpunit.replacing("</php>", with: "<env name=\"DB_CONNECTION\" value=\"mysql\"/></php>"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = try #require(TestDatabaseCheck.check(projectFolder: folder))

        let plan = TestDatabasePlan.make(for: .database("db_finly_testing"), check: check, projectFolder: folder)

        #expect(plan?.changes.map(\.key) == ["DB_DATABASE"])
        #expect(TestDatabasePlan.phpunitConflicts(for: .sqliteMemory, check: check, projectFolder: folder) == ["DB_CONNECTION"])
        #expect(TestDatabasePlan.make(for: .sqliteMemory, check: check, projectFolder: folder) == nil)
    }

    @Test func phpunitWithTheDatabaseOrWithoutAppEnvGetsNoPlan() throws {
        let namesDatabase = try project(phpunit: Self.phpunit.replacing("</php>", with: "<env name=\"DB_DATABASE\" value=\"db_finly\"/></php>"))
        let withoutAppEnv = try project(phpunit: "<phpunit><php></php></phpunit>")
        defer {
            try? FileManager.default.removeItem(at: namesDatabase)
            try? FileManager.default.removeItem(at: withoutAppEnv)
        }

        for folder in [namesDatabase, withoutAppEnv] {
            let check = try #require(TestDatabaseCheck.check(projectFolder: folder))
            #expect(check.kind == .development)
            #expect(TestDatabasePlan.make(for: .sqliteMemory, check: check, projectFolder: folder) == nil)
        }
    }
}
