import Foundation
import NexusCore
import Testing

struct AppLogsTests {
    static let laravelText = """
        [2026-11-23 13:52:10] local.ERROR: SQLSTATE[23000]: Duplicate entry '1042' {"userId":18,"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE[23000]: Duplicate entry '1042'
        (Connection: mysql, SQL: insert into invoices) at /w/shop/vendor/laravel/framework/src/Illuminate/Database/Connection.php:825)
        [stacktrace]
        #0 /w/shop/app/Models/Order.php(131): Illuminate\\\\Database\\\\Connection->insert()
        #1 /w/shop/app/Http/Controllers/CheckoutController.php(58): App\\\\Models\\\\Order->markPaid()
        #2 {main}
        "}
        [2026-11-23 14:16:55] local.INFO: Order 1042 paid with iDEAL. {"order_id":1042,"trace_id":"9f2c41d0"}
        [2026-11-23 14:17:00] testing.WARNING: A test wrote this.
        [2026-11-23 14:18:31] local.ERROR: SQLSTATE[23000]: Duplicate entry '1042' {"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE at /w/shop/app/Models/Order.php:131)
        [stacktrace]
        #0 {main}
        "}

        """

    private func file(_ text: String, name: String = "laravel.log") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func logFile(_ url: URL, kind: LogFile.Kind = .app, folders: [String] = [], excluded: [String] = []) -> LogFile {
        LogFile(name: url.lastPathComponent, path: url.path(percentEncoded: false), kind: kind, bytes: 0, modified: nil, folders: folders, excludedFolders: excluded)
    }

    @Test func theIndexFindsEachLaravelEntryWithItsLevelLineAndTime() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: TimeZone(identifier: "Europe/Amsterdam")!)

        index.update()
        let entries = index.snapshot.entries

        #expect(entries.map(\.level) == ["error", "info", "warning", "error"])
        #expect(entries.map(\.line) == [1, 8, 9, 10])
        #expect(entries.map(\.isTestRun) == [false, false, true, false])
        #expect(entries[1].date == 1_795_439_815)
        #expect(entries[0].hash == entries[3].hash)
        #expect(entries[0].hash != entries[1].hash)
    }

    @Test func anAppendedEntryGrowsTheIndexAndAShorterFileGivesANewIndex() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: .gmt)
        index.update()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-11-23 15:00:00] local.DEBUG: New line.\n".utf8))
        try handle.close()

        #expect(index.update() == .grew)
        #expect(index.snapshot.count == 5)

        try Data("[2026-11-23 16:00:00] local.INFO: After the clear.\n".utf8).write(to: url)

        #expect(index.update() == .replaced)
        #expect(index.snapshot.entries.map(\.level) == ["info"])
    }

    @Test func phpErrorsKeepOnlyTheLinesOfThePlaceAndNotOfItsWorkspaces() throws {
        let text = """
            [23-Nov-2026 14:24:06] NOTICE: ready to handle connections
            NOTICE: PHP message: PHP Warning:  Undefined array key "price" in /w/shop/wp-content/themes/shop/functions.php on line 212
            NOTICE: PHP message: PHP Warning:  Undefined variable in /w/blog/index.php on line 3
            NOTICE: PHP message: PHP Fatal error:  Uncaught Exception: Boom in /w/shop/.claude/worktrees/fix/index.php:4
            NOTICE: PHP message: PHP Deprecated:  Old function in /w/shop/index.php on line 9

            """
        let url = try file(text, name: "php-8.4.log")
        let index = LogIndex(file: logFile(url, kind: .phpErrors, folders: ["/w/shop/"], excluded: ["/w/shop/.claude/worktrees/fix/"]), zone: .gmt)

        index.update()
        let entries = index.snapshot.entries

        #expect(entries.map(\.level) == ["warning", "deprecated"])
        #expect(entries.allSatisfy { $0.date == nil })
    }

    @Test func aFileWithoutTimesGetsOneEntryForEachLine() throws {
        let url = try file("Starting import\nImported 12 items\n\nDone\n", name: "import.log")
        let index = LogIndex(file: logFile(url), zone: .gmt)

        index.update()

        #expect(index.snapshot.entries.map(\.line) == [1, 2, 4])
        #expect(index.text(of: index.snapshot.entries[1], limit: 100).text == "Imported 12 items")
    }

    @Test func theStatusOfARequestIsItsLevel() throws {
        let text = """
            ::1 - - [08/Nov/2026:21:40:50 +0100] "GET / HTTP/2.0" 302 362 "-" "curl/8.7.1"
            ::1 - - [08/Nov/2026:21:41:48 +0100] "GET /checkout HTTP/2.0" 500 6586 "-" "curl/8.7.1"

            """
        let url = try file(text, name: "shop.test.log")
        let index = LogIndex(file: logFile(url, kind: .requests), zone: .gmt)

        index.update()
        let entries = index.snapshot.entries

        #expect(entries.map(\.level) == ["302", "500"])
        #expect(LogLevelGroup.of(level: entries[1].level) == .error)
        #expect(entries[0].date == 1_794_170_450)
        #expect(LogEntryParser.summary(of: index.text(of: entries[1], limit: 1000).text, kind: .requests).message == "GET /checkout")
    }

    @Test func aSearchFindsTheEntriesWithTheTextInAnyCase() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: .gmt)
        index.update()
        let entries = index.snapshot.entries

        #expect(index.search("markpaid") == [entries[0].offset])
        #expect(index.search("IDEAL") == [entries[1].offset])
        #expect(index.search("duplicate entry")?.count == 2)
        #expect(index.search("not in the log") == [])
    }

    @Test func aLargeFileFirstGetsTheIndexOfItsEnd() throws {
        var text = ""
        let line = "[2026-11-23 14:16:55] local.INFO: " + String(repeating: "x", count: 200) + "\n"

        while text.utf8.count < 9 * 1024 * 1024 {
            text += line
        }

        let url = try file(text)
        let index = LogIndex(file: logFile(url), zone: .gmt)

        index.update()
        let quick = index.snapshot

        #expect(!quick.isComplete)
        #expect(quick.count > 10_000)
        #expect(quick.entries.allSatisfy { $0.line == 0 })

        index.update(progress: { _ in })
        let full = index.snapshot

        #expect(full.isComplete)
        #expect(full.count == text.utf8.count / line.utf8.count)
        #expect(full.entries.last?.line == full.count)
    }

    @Test func theSummaryHasTheShortClassTheSourceAndTheContext() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: .gmt)
        index.update()
        let entries = index.snapshot.entries

        let error = LogEntryParser.summary(of: index.text(of: entries[0], limit: 32_000).text, kind: .app)
        #expect(error.message == "SQLSTATE[23000]: Duplicate entry '1042'")
        #expect(error.exceptionClass == "QueryException")
        #expect(error.sourceFile == "/w/shop/app/Models/Order.php")
        #expect(error.sourceLine == 131)

        let info = LogEntryParser.summary(of: index.text(of: entries[1], limit: 32_000).text, kind: .app)
        #expect(info.message == "Order 1042 paid with iDEAL.")
        #expect(info.context == ["order_id 1042", "trace_id 9f2c41d0"])
    }

    @Test func theDetailHasTheExceptionTheFramesAndTheContextInOrder() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: .gmt)
        index.update()
        let entries = index.snapshot.entries

        let error = LogEntryParser.detail(of: index.text(of: entries[0], limit: 1_000_000).text, kind: .app, isCut: false)
        let exception = try #require(error.exceptions.first)
        #expect(exception.className == "Illuminate\\Database\\QueryException")
        #expect(exception.shortClassName == "QueryException")
        #expect(exception.namespace == "Illuminate\\Database\\")
        #expect(exception.message == "SQLSTATE[23000]: Duplicate entry '1042'\n(Connection: mysql, SQL: insert into invoices)")
        #expect(exception.line == 825)
        #expect(exception.frames.map(\.number) == [0, 1, 2])
        #expect(exception.frames[0].file == "/w/shop/app/Models/Order.php")
        #expect(exception.frames[0].line == 131)
        #expect(!exception.frames[0].isVendor)
        #expect(exception.frames[2].call == "{main}")
        #expect(error.context?.children?.map(\.key) == ["userId"])

        let info = LogEntryParser.detail(of: index.text(of: entries[1], limit: 1_000_000).text, kind: .app, isCut: false)
        #expect(info.message == "Order 1042 paid with iDEAL.")
        #expect(info.context?.children?.map(\.key) == ["order_id", "trace_id"])
        #expect(info.ids == [LogID(key: "trace_id", value: "9f2c41d0")])
    }

    @Test func aMessageWithJSONInItKeepsItsJSONWhenTheContextFollows() {
        let text = #"[2026-11-23 14:16:55] local.INFO: Response {"ok":true} was slow {"seconds":2.4} {"trace_id":"a1"}"#
        let detail = LogEntryParser.detail(of: text, kind: .app, isCut: false)

        #expect(detail.message == #"Response {"ok":true} was slow"#)
        #expect(detail.context?.children?.map(\.key) == ["seconds", "trace_id"])
    }

    // A log can hold any text, also a broken pair of escapes. The reader must not stop nexusd.
    @Test func aHighSurrogateWithoutItsLowSurrogateGivesAQuestionMark() {
        let escape = "\\" + "u"
        let text = #"[2026-11-23 14:16:55] local.INFO: Bad text {"a":"\#(escape)d83d\#(escape)0041","b":"\#(escape)d83d\#(escape)de00"}"#
        let detail = LogEntryParser.detail(of: text, kind: .app, isCut: false)

        #expect(detail.context?.children?.map(\.value) == ["?A", String(Character(Unicode.Scalar(0x1F600)!))])
    }

    @Test func aPHPErrorShowsItsFileAndLine() {
        let summary = LogEntryParser.summary(of: #"NOTICE: PHP message: PHP Warning:  Undefined array key "price" in /w/shop/functions.php on line 212"#, kind: .phpErrors)

        #expect(summary.message == #"Undefined array key "price""#)
        #expect(summary.sourceFile == "/w/shop/functions.php")
        #expect(summary.sourceLine == 212)
    }

    @Test func theBrowserGroupsHidesAndCountsTheEntries() throws {
        let url = try file(Self.laravelText)
        let index = LogIndex(file: logFile(url), zone: .gmt)
        index.update()
        let snapshot = index.snapshot
        let errorHash = snapshot.entries[0].hash

        let grouped = LogBrowser.result(of: [snapshot], query: LogQuery(), searchHits: nil, limit: 100)
        #expect(grouped.rows.map(\.count) == [2, 1])
        #expect(grouped.rows[0].entry.offset == snapshot.entries[3].offset)
        #expect(grouped.rows[0].firstDate == snapshot.entries[0].date)
        #expect(grouped.hiddenTestRuns == 1)
        #expect(grouped.levelCounts == [.error: 2, .info: 1])

        let hidden = LogBrowser.result(of: [snapshot], query: LogQuery(hidesTestRuns: false, hiddenMessages: [errorHash: "SQLSTATE"], groupsEqualEntries: false), searchHits: nil, limit: 100)
        #expect(hidden.rows.map(\.entry.level) == ["warning", "info"])
        #expect(hidden.hiddenByMessage == [errorHash: 2])

        let searched = LogBrowser.result(of: [snapshot], query: LogQuery(search: "ideal"), searchHits: [snapshot.file.id: [snapshot.entries[1].offset]], limit: 100)
        #expect(searched.rows.map(\.entry.level) == ["info"])
    }

    @Test func theLaravelFilesStartWithLaravelLogAndHaveOneLevelOfSubfolders() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: "nexus-logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let logs = project.appending(path: "storage/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs.appending(path: "cronjobs/old"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: logs.appending(path: "browser.log"))
        try Data("a\n".utf8).write(to: logs.appending(path: "laravel.log"))
        try Data("a\n".utf8).write(to: logs.appending(path: "cronjobs/import.log"))
        try Data("a\n".utf8).write(to: logs.appending(path: "cronjobs/old/deep.log"))
        try Data("a\n".utf8).write(to: logs.appending(path: ".gitignore"))
        let place = LogPlace(id: "shop.test", siteHost: "shop.test", workspace: nil, kind: .laravel, folder: project.appending(path: "public").path(percentEncoded: false), projectFolder: project.path(percentEncoded: false), php: nil, hosts: [], otherFolders: [], appLog: nil)

        let names = AppLogFiles.files(of: place, paths: NexusPaths(root: project.appending(path: "nexus"))).map(\.name)

        #expect(names == ["laravel.log", "browser.log", "cronjobs/import.log"])
    }

    // NEXUS_REAL_LOG names a large real log. The test prints the times of the index and a search.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_REAL_LOG"] != nil))
    func aRealLogGetsItsIndexAndASearch() throws {
        let url = URL(filePath: try #require(ProcessInfo.processInfo.environment["NEXUS_REAL_LOG"]))
        let index = LogIndex(file: logFile(url), zone: .gmt)
        let clock = ContinuousClock()

        let quick = clock.measure { index.update() }
        let full = clock.measure { index.update(progress: { _ in }) }
        var found: Set<UInt64>?
        let search = clock.measure { found = index.search("text that is not in the log") }
        let snapshot = index.snapshot
        let browse = clock.measure { _ = LogBrowser.result(of: [snapshot], query: LogQuery(), searchHits: nil, limit: 1000) }

        print("entries \(snapshot.count), quick \(quick), full \(full), search \(search), result \(browse)")
        #expect(snapshot.isComplete)
        #expect(found == [])
    }

    @Test func wpDebugLogCanNameAPath() {
        let folder = URL(filePath: "/w/blog", directoryHint: .isDirectory)

        #expect(AppLogFiles.debugLogPath(in: "define( 'WP_DEBUG_LOG', '/w/logs/wp.log' );", configFolder: folder)?.path == "/w/logs/wp.log")
        #expect(AppLogFiles.debugLogPath(in: "define('WP_DEBUG_LOG', __DIR__ . '/logs/debug.log');", configFolder: folder)?.path == "/w/blog/logs/debug.log")
        #expect(AppLogFiles.debugLogPath(in: "define( 'WP_DEBUG_LOG', true );", configFolder: folder) == nil)
    }
}
