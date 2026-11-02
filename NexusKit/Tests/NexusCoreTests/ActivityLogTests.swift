import Foundation
import Testing
@testable import NexusCore

struct ActivityLogTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Activity \(UUID().uuidString)", directoryHint: .isDirectory)

    private var file: URL {
        root.appending(path: "activity.log")
    }

    @Test func aLineHasTheTimeTheSourceTheKindAndTheText() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ActivityLog(file: file, source: "app")

        log.write("click", "Show config folder")
        log.waitForWrites()

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(" app click: Show config folder\n"))
        #expect(text.hasPrefix("20"))
    }

    @Test func twoWritersAddToOneFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ActivityLog(file: file, source: "app")
        let nexusd = ActivityLog(file: file, source: "nexusd")

        app.write("click", "one")
        app.waitForWrites()
        nexusd.write("request", "two")
        nexusd.waitForWrites()

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("nexusd request: two"))
    }

    @Test func aFullFileMovesToTheOlderFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ActivityLog(file: file, source: "app", limit: 100)

        log.write("click", String(repeating: "a", count: 120))
        log.write("click", "new")
        log.waitForWrites()

        let older = try String(contentsOf: ActivityLog.olderFile(of: file), encoding: .utf8)
        let current = try String(contentsOf: file, encoding: .utf8)
        #expect(older.contains("aaa"))
        #expect(current.contains("click: new"))
        #expect(ActivityLog.olderFile(of: file).lastPathComponent == "activity.1.log")
    }

    @Test(arguments: [
        ("password=hunter2 failed", "password=<hidden> failed"),
        ("MYSQL_PWD: hunter2", "MYSQL_PWD=<hidden>"),
        ("DB_PASSWORD=hunter2", "DB_PASSWORD=<hidden>"),
        ("api_key = hunter2", "api_key=<hidden>"),
        ("mysql://root:hunter2@127.0.0.1:3306/shop", "mysql://root:<hidden>@127.0.0.1:3306/shop"),
        (#"password="two words" failed"#, "password=<hidden> failed"),
        (#"{"password":"two words"}"#, #"{"password=<hidden>}"#),
        ("ALTER USER 'root'@'%' IDENTIFIED BY 'it''s secret';", "ALTER USER 'root'@'%' IDENTIFIED BY <hidden>;"),
        ("ALTER ROLE admin PASSWORD 'two words';", "ALTER ROLE admin PASSWORD <hidden>;"),
    ])
    func aSecretInAnErrorDoesNotReachTheFile(_ text: String, _ expected: String) {
        #expect(ActivityLog.hidingSecrets(in: text) == expected)
    }

    @Test func aLineStaysOneShortLine() {
        let text = ActivityLog.hidingSecrets(in: "one\ntwo" + String(repeating: "a", count: 900))

        #expect(!text.contains("\n"))
        #expect(text.count == 500)
    }
}
