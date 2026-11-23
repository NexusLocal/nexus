import Foundation
import NexusCore
import Testing
@testable import NexusDumps

// The data of the web page of the logs: the same entries as the Logs screen, by a key of the file
// and the offset of the entry. Only a file of the project of the place opens.
struct LogPageStoreTests {
    struct Project {
        let place: LogPlace
        let root: String
        let log: URL
        let paths: NexusPaths
    }

    static func logText(root: String) -> String {
        """
        [2026-11-23 13:00:00] local.INFO: Order 1042 paid. {"order_id":1042,"trace_id":"9f2c41d0"}
        [2026-11-23 13:01:00] testing.ERROR: A test failed.
        [2026-11-23 13:02:00] local.ERROR: SQLSTATE[23000]: Duplicate {"user_id":18,"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE[23000]: Duplicate at \(root)/vendor/laravel/Connection.php:825)
        [stacktrace]
        #0 \(root)/app/Models/Order.php(131): App\\\\Models\\\\Order->markPaid()
        #1 /etc/hosts(1): Outside->call()
        #2 \(root)/app/../../../hosts(2): Escape->call()
        #3 \(root)/vendor/laravel/Kernel.php(40): Kernel->handle()
        #4 {main}
        "}
        [2026-11-23 13:03:00] local.ERROR: SQLSTATE[23000]: Duplicate {"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE at \(root)/app/Models/Order.php:131)
        [stacktrace]
        #0 {main}
        "}
        [2026-11-23 13:04:00] local.DEBUG: Cache hit.
        [2026-11-23 13:05:00] local.WARNING: Nested. {"order":{"id":7,"tags":["a","b"]},"ok":true,"none":null,"price":12.5}

        """
    }

    static func project() throws -> Project {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-log-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = RealPath.trimmed(folder.path(percentEncoded: false))
        let logs = folder.appending(path: "storage/logs", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appending(path: "app/Models"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appending(path: "vendor/laravel"), withIntermediateDirectories: true)
        try Data("<?php\n".utf8).write(to: folder.appending(path: "app/Models/Order.php"))
        try Data("<?php\n".utf8).write(to: folder.appending(path: "vendor/laravel/Connection.php"))
        try Data("APP_TIMEZONE=UTC\n".utf8).write(to: folder.appending(path: ".env"))
        let log = logs.appending(path: "laravel.log")
        try Data(logText(root: root).utf8).write(to: log)
        try Data("Starting import\n".utf8).write(to: logs.appending(path: "import.log"))
        let place = LogPlace(id: "shop.test", siteHost: "shop.test", workspace: nil, kind: .laravel, folder: root + "/public", projectFolder: root, php: nil, hosts: [], otherFolders: [], appLog: nil)
        return Project(place: place, root: root, log: log, paths: NexusPaths(root: folder.appending(path: "nexus")))
    }

    static func json(_ response: PageResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    static func rows(_ answer: [String: Any]) -> [[String: Any]] {
        answer["rows"] as? [[String: Any]] ?? []
    }

    static func file(_ name: String, in answer: [String: Any]) -> [String: Any] {
        (answer["files"] as? [[String: Any]] ?? []).first { $0["name"] as? String == name } ?? [:]
    }

    static func laravelKey(_ answer: [String: Any]) -> String {
        file("laravel.log", in: answer)["key"] as? String ?? ""
    }

    private func entries(_ project: Project, _ store: LogPageStore = LogPageStore(), _ values: [String: String] = [:]) throws -> [String: Any] {
        try Self.json(store.entries(of: project.place, paths: project.paths, request: LogPageQuery(["place": "shop.test"].merging(values) { _, new in new })))
    }

    @Test func theEntriesGroupEqualEntriesAndHideTestRunsAndDebugAsTheLogsScreen() throws {
        let project = try Self.project()

        let answer = try entries(project)
        let rows = Self.rows(answer)

        #expect(rows.map { $0["level"] as? String } == ["warning", "error", "info", ""])
        #expect(rows.map { $0["count"] as? Int } == [1, 2, 1, 1])
        #expect(rows[1]["exception"] as? String == "QueryException")
        #expect(rows[1]["source"] as? String == "app/Models/Order.php")
        #expect(rows[1]["sourceLine"] as? Int == 131)
        #expect(rows[1]["firstTime"] as? Double == 1_795_438_920_000)
        #expect(rows[2]["context"] as? [String] == ["order_id 1042", "trace_id 9f2c41d0"])
        #expect(rows[3]["message"] as? String == "Starting import")
        #expect(answer["total"] as? Int == 7)
        #expect(answer["hiddenTestRuns"] as? Int == 1)
        #expect(answer["levelCounts"] as? [String: Int] == ["error": 2, "warning": 1, "info": 2, "debug": 1])
        #expect((answer["files"] as? [[String: Any]])?.map { $0["name"] as? String } == ["laravel.log", "import.log"])
        #expect((answer["files"] as? [[String: Any]])?.first?["zone"] as? String == "UTC")
        #expect(answer["searchCounts"] == nil)
    }

    @Test func aFilterOfTheLevelsTheFileTheSearchAndTheHiddenEntriesKeepsOnlyTheirEntries() throws {
        let project = try Self.project()
        let store = LogPageStore()
        let all = try entries(project, store)
        let key = Self.laravelKey(all)
        let errorHash = try #require(Self.rows(all)[1]["hash"] as? String)

        let errors = try entries(project, store, ["levels": "error"])
        let searched = try entries(project, store, ["search": "MARKPAID"])
        let tests = try entries(project, store, ["levels": "error", "tests": "shown", "group": "0"])
        let hidden = try entries(project, store, ["hidden": errorHash])
        let oneFile = try entries(project, store, ["file": key, "levels": "info"])
        let unknownFile = try entries(project, store, ["file": "123abc", "levels": "info"])

        let importKey = try #require(Self.file("import.log", in: all)["key"] as? String)

        #expect(Self.rows(errors).map { $0["count"] as? Int } == [2])
        #expect(Self.rows(searched).map { $0["message"] as? String } == ["SQLSTATE[23000]: Duplicate"])
        #expect(searched["searchCounts"] as? [String: Int] == [key: 1, importKey: 0])
        #expect(Self.rows(tests).map { $0["testRun"] as? Bool } == [false, false, true])
        #expect(tests["hiddenTestRuns"] as? Int == 0)
        #expect(Self.rows(hidden).map { $0["level"] as? String } == ["warning", "info", ""])
        #expect(hidden["hiddenByMessage"] as? [String: Int] == [errorHash: 2])
        #expect(oneFile["file"] as? String == key)
        #expect(Self.rows(oneFile).map { $0["message"] as? String } == ["Order 1042 paid."])
        #expect(unknownFile["file"] == nil)
        #expect(Self.rows(unknownFile).count == 2)
    }

    @Test func aPageThatHasTheVersionGetsUnchangedUntilTheLogGrows() throws {
        let project = try Self.project()
        let store = LogPageStore()
        let first = try entries(project, store)
        let version = try #require(first["version"] as? String)

        let same = try entries(project, store, ["known": version])
        let handle = try FileHandle(forWritingTo: project.log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-11-23 13:06:00] local.ERROR: New error.\n".utf8))
        try handle.close()
        let grown = try entries(project, store, ["known": version])

        #expect(same["unchanged"] as? Bool == true)
        #expect(same["rows"] == nil)
        #expect(grown["unchanged"] == nil)
        #expect(Self.rows(grown).first?["message"] as? String == "New error.")
    }

    @Test func theDetailHasTheExceptionTheFramesTheContextAndTheIDs() throws {
        let project = try Self.project()
        let store = LogPageStore()
        let answer = try entries(project, store)
        let error = Self.rows(answer)[1]
        let info = Self.rows(answer)[2]
        let key = Self.laravelKey(answer)

        let detail = try Self.json(store.detail(of: project.place, paths: project.paths, fileKey: key, offset: try #require(error["offset"] as? UInt64)))
        let infoDetail = try Self.json(store.detail(of: project.place, paths: project.paths, fileKey: key, offset: try #require(info["offset"] as? UInt64)))
        let missing = store.detail(of: project.place, paths: project.paths, fileKey: key, offset: 3)

        let exception = try #require((detail["exceptions"] as? [[String: Any]])?.first)
        let frames = exception["frames"] as? [[String: Any]] ?? []
        #expect(detail["message"] as? String == "SQLSTATE[23000]: Duplicate")
        #expect(detail["channel"] as? String == "local")
        #expect(detail["logTime"] as? String == "2026-11-23 13:03:00")
        #expect(exception["namespace"] as? String == "Illuminate\\Database\\")
        #expect(exception["shortName"] as? String == "QueryException")
        #expect(exception["shortFile"] as? String == "app/Models/Order.php")
        #expect(frames.map { $0["vendor"] as? Bool } == [true])
        #expect((detail["text"] as? String)?.hasPrefix("[2026-11-23 13:03:00] local.ERROR:") == true)
        #expect((infoDetail["context"] as? [String: Any])?["children"] as? [[String: Any]] != nil)
        #expect((infoDetail["ids"] as? [[String: String]]) == [["key": "trace_id", "value": "9f2c41d0"]])
        #expect(missing.status == 404)
    }

    @Test func onlyTheLogFileAndTheFilesOfTheProjectOpen() throws {
        let project = try Self.project()
        let store = LogPageStore()
        let answer = try entries(project, store, ["group": "0", "levels": "error"])
        let key = Self.laravelKey(answer)
        let logPath = try #require(Self.file("laravel.log", in: answer)["path"] as? String)
        let offset = try #require(Self.rows(answer).last?["offset"] as? UInt64)

        func target(_ exception: Int?, _ frame: Int? = nil, file: String? = nil, at entry: UInt64? = nil) -> LogPageStore.OpenTarget {
            store.openTarget(of: project.place, paths: project.paths, request: LogPageOpen(place: "shop.test", file: file ?? key, offset: entry ?? offset, exception: exception, frame: frame))
        }

        #expect(target(nil) == .file(path: logPath, line: 3))
        #expect(target(0) == .file(path: "\(project.root)/vendor/laravel/Connection.php", line: 825))
        #expect(target(0, 0) == .file(path: "\(project.root)/app/Models/Order.php", line: 131))
        #expect(status(target(0, 1)) == 403)
        #expect(status(target(0, 2)) == 403)
        #expect(status(target(0, 3)) == 409)
        #expect(status(target(0, 4)) == 404)
        #expect(status(target(0, 9)) == 404)
        #expect(status(target(1)) == 404)
        #expect(status(target(nil, file: "123abc")) == 404)
        #expect(status(target(nil, at: offset + 1)) == 404)
    }

    @Test func aPathOfThePageIsNoKeyOfAFile() throws {
        let project = try Self.project()
        let store = LogPageStore()

        let answer = try entries(project, store, ["file": project.log.path(percentEncoded: false)])
        let target = store.openTarget(of: project.place, paths: project.paths, request: LogPageOpen(place: "shop.test", file: project.log.path(percentEncoded: false), offset: 0))

        #expect(answer["file"] == nil)
        #expect(status(target) == 404)
        #expect(!Self.laravelKey(answer).contains("/"))
    }

    private func status(_ target: LogPageStore.OpenTarget) -> Int? {
        guard case .refused(let response) = target else {
            return nil
        }

        return response.status
    }
}
