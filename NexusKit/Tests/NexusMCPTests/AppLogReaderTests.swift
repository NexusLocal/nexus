import Foundation
import NexusCore
import NexusMCP
import Testing

struct AppLogReaderTests {
    private func project() throws -> (place: LogPlace, logs: URL, paths: NexusPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "nexus-app-logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let logs = root.appending(path: "storage/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("APP_TIMEZONE=UTC\n".utf8).write(to: root.appending(path: ".env"))
        let text = """
            [2026-11-23 13:00:00] local.INFO: Order 1042 paid. {"order_id":1042}
            [2026-11-23 13:01:00] testing.ERROR: A test failed.
            [2026-11-23 13:02:00] local.ERROR: SQLSTATE[23000]: Duplicate {"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE at \(root.path(percentEncoded: false))vendor/x/Connection.php:825)
            [stacktrace]
            #0 \(root.path(percentEncoded: false))app/Models/Order.php(131): Order->markPaid()
            #1 {main}
            "}

            """
        try Data(text.utf8).write(to: logs.appending(path: "laravel.log"))
        try Data("Starting import\n".utf8).write(to: logs.appending(path: "import.log"))
        let path = root.path(percentEncoded: false)
        let place = LogPlace(id: "shop.test", siteHost: "shop.test", workspace: nil, kind: .laravel, folder: path + "public", projectFolder: path, php: nil, hosts: [], otherFolders: [], appLog: nil)
        return (place, logs, NexusPaths(root: root.appending(path: "nexus")))
    }

    @Test func theEntriesComeOldestFirstWithTheLineOfTheApp() throws {
        let setup = try project()
        let reader = try AppLogReader(place: setup.place, paths: setup.paths, file: "laravel.log")

        let entries = reader.entries(count: 10, level: nil, containing: nil)

        #expect(entries.map(\.level) == ["info", "error", "error"])
        #expect(entries[0].text == "2026-11-23 \(Self.local("13:00:00")) info · Order 1042 paid. · order_id 1042")
        #expect(entries[1].channel == "testing")
        #expect(entries[2].exception == "QueryException")
        #expect(entries[2].source == "app/Models/Order.php:131")
    }

    @Test func aLevelAndATextKeepOnlyTheirEntries() throws {
        let setup = try project()
        let reader = try AppLogReader(place: setup.place, paths: setup.paths, file: nil)

        #expect(reader.entries(count: 10, level: .error, containing: nil).count == 2)
        #expect(reader.entries(count: 10, level: nil, containing: "DUPLICATE").map(\.exception) == ["QueryException"])
        #expect(reader.entries(count: 10, level: nil, containing: "import").map(\.file) == ["import.log"])
    }

    @Test func newEntriesGivesOnlyWhatCameAfterTheLastRead() throws {
        let setup = try project()
        let reader = try AppLogReader(place: setup.place, paths: setup.paths, file: "laravel.log")
        _ = reader.entries(count: 10, level: nil, containing: nil)

        #expect(reader.newEntries(level: nil, containing: nil).isEmpty)

        let handle = try FileHandle(forWritingTo: setup.logs.appending(path: "laravel.log"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-11-23 13:05:00] local.WARNING: Slow.\n".utf8))
        try handle.close()

        #expect(reader.newEntries(level: nil, containing: nil).map(\.message) == ["Slow."])
    }

    @Test func anUnknownFileNamesTheFilesOfThePlace() throws {
        let setup = try project()

        #expect(throws: (any Error).self) {
            try AppLogReader(place: setup.place, paths: setup.paths, file: "other.log")
        }
    }

    // The entries show the time of the Mac. The test logs have UTC.
    private static func local(_ time: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.date(from: "2026-11-23 \(time)")!
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
