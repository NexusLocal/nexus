import Foundation
import JavaScriptCore
import NexusCore
import Testing
@testable import NexusDumps

// The page computes the marks and the texts itself. These tests run its script in JavaScriptCore
// and compare it with QueryMarks and DumpEntryText, as the app uses them.
struct DumpPageScriptTests {
    private static let started = Date(timeIntervalSince1970: 1_762_850_000)
    private static let controller = "/w/shop/app/Http/Controllers/CheckoutController.php"
    private static let english = Locale(identifier: "en_US")

    private static func query(_ seq: Int, _ text: String, pattern: String? = nil, file: String? = controller, line: Int? = 38, milliseconds: Double? = 0.84) -> CaughtDump {
        CaughtDump(requestID: "r1", seq: seq, time: started, kind: .query, file: file, line: line, label: "mysql", text: text, milliseconds: milliseconds, pattern: pattern, number: seq)
    }

    private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(DumpPage.logicScript)
        #expect(context.exception == nil)
        return context
    }

    // The value goes in as the JSON that the page gets from nexusd.
    private func run(_ expression: String, with value: some Encodable, in context: JSContext) throws -> String {
        let json = String(decoding: try #require(PageResponse.encodedJSON(value)), as: UTF8.self)
        context.setObject(json, forKeyedSubscript: "input" as NSString)
        let result = context.evaluateScript("(() => { const value = JSON.parse(input); return \(expression); })()")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return result?.toString() ?? ""
    }

    @Test func theWholeScriptOfThePageCompiles() throws {
        let context = try #require(JSContext())
        let html = DumpPage.html(token: "t", nonce: "n", title: "Nexus Dumps")
        let start = try #require(html.range(of: "<script nonce=\"n\">\n"))
        let end = try #require(html.range(of: "</script>", options: .backwards))
        context.setObject(String(html[start.upperBound..<end.lowerBound]), forKeyedSubscript: "source" as NSString)

        let result = context.evaluateScript("new Function(source); 'compiles'")

        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        #expect(result?.toString() == "compiles")
    }

    @Test(arguments: [
        "select * from `carts` where `user_id` = 7 limit 1",
        "select * from wp_2_posts where ID = 12 and post_status = 'publish'",
        "select 'it''s', \"a\\\"b\", 3.14, 2fa_codes, x1, -5 from t",
        "select `a``b`, `c\\` from t where d = 'x\\' y' and e = 0.5e3",
        "select 12.5.3, 1.x, a.1, 7. from t",
        "select é1, ü 2, '😀', 5 from t",
        "select 'no end",
        "select 'ends with a backslash \\",
        "update `posts` set `views` = `views` + 1 where `id` in (1, 2, 3)",
        "",
    ])
    func thePatternOfThePageIsThePatternOfQueryMarks(_ sql: String) throws {
        let context = try page()

        #expect(try run("sqlPattern(value)", with: sql, in: context) == QueryMarks.pattern(of: sql))
    }

    @Test func theMarksOfThePageAreTheMarksOfQueryMarks() throws {
        let laravel = (1...6).map { seq in Self.query(seq, "select * from `products` where `id` = \(seq) limit 1", pattern: "select * from `products` where `id` = ? limit 1", file: "/w/shop/app/Models/CartItem.php", line: 24) }
        let wordPress = (7...11).map { seq in Self.query(seq, "SELECT * FROM wp_postmeta WHERE post_id = \(seq * 10)", file: "/w/blog/wp-content/plugins/shop/shop.php", line: 88) }
        let sameText = (12...16).map { seq in Self.query(seq, "select * from `settings` where `key` = 'currency' limit 1", line: 31) }
        let fourOnly = (17...20).map { seq in Self.query(seq, "select * from `tags` where `id` = \(seq)", line: 40) }
        let withoutSource = [Self.query(21, "select 1", file: nil, line: nil), Self.query(22, "select 1", file: nil, line: nil, milliseconds: nil)]
        let slow = [Self.query(23, "select count(*) from `orders`", line: 51, milliseconds: 142), Self.query(24, "select count(*) from `orders` where 1", line: 52, milliseconds: 99.99)]
        let log = CaughtDump(requestID: "r1", seq: 25, time: Self.started, kind: .log, label: "error", text: "select 1", number: 25)
        let entries = laravel + wordPress + sameText + fourOnly + withoutSource + slow + [log]
        let context = try page()

        let marks = try run("JSON.stringify(Object.fromEntries(queryMarks(value)))", with: entries, in: context)
        let decoded = try JSONDecoder().decode([String: [String]].self, from: Data(marks.utf8))
        let expected = QueryMarks(entries).entries.mapValues { marks in marks.sorted().map(\.rawValue) }

        #expect(decoded == expected)
        #expect(decoded["r1-1"] == ["n_plus_one"])
        #expect(decoded["r1-7"] == ["n_plus_one"])
        #expect(decoded["r1-12"] == ["duplicate"])
        #expect(decoded["r1-17"] == nil)
        #expect(decoded["r1-21"] == ["duplicate"])
        #expect(decoded["r1-23"] == ["slow"])
        #expect(decoded["r1-24"] == nil)
    }

    @Test func theQueriesTabGroupsAnNPlusOneLineAndTheSameTextAtTheirFirstQuery() throws {
        let first = Self.query(1, "select * from `carts` where `user_id` = 7 limit 1")
        let items = (2...13).map { seq in Self.query(seq, "select * from `products` where `id` = \(seq) limit 1", pattern: "select * from `products` where `id` = ? limit 1", file: "/w/shop/app/Models/CartItem.php", line: 24, milliseconds: 0.8) }
        let settings = [Self.query(14, "select * from `settings` where `key` = 'currency' limit 1", line: 31, milliseconds: 0.5), Self.query(16, "select * from `settings` where `key` = 'currency' limit 1", line: 31, milliseconds: 0.6)]
        let slow = Self.query(15, "select count(*) from `orders`", line: 51, milliseconds: 142)
        let entries = [first] + items + [settings[0], slow, settings[1]]
        let context = try page()

        let rows = try run("JSON.stringify(queryRows(value).map((row) => [row.queries.map((query) => query.seq), row.tags, row.slow, row.milliseconds == null ? null : millisecondsText(row.milliseconds, 'en-US'), row.text, row.hint]))", with: entries, in: context)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(rows.utf8)) as? [[Any]])
        let app = QueryRow.rows(of: entries, marks: QueryMarks(entries)) { entry in entry }

        #expect(decoded.map { row in row[0] as? [Int] ?? [] } == app.map { row in row.entries.map(\.seq) })
        #expect(decoded.map { row in row[3] as? String } == app.map { row in DumpEntryText.milliseconds(row.milliseconds, locale: Self.english) })
        let nPlusOneTag = try #require(DumpEntryText.groupTag(.nPlusOne, count: 12))
        let duplicateTag = try #require(DumpEntryText.groupTag(.duplicate, count: 2))

        #expect(decoded[1][1] as? [String] == [nPlusOneTag])
        #expect(decoded[1][4] as? String == "select * from `products` where `id` = ? limit 1")
        #expect(decoded[1][5] as? String == DumpEntryText.nPlusOneNote(count: 12, isLaravel: true))
        #expect(decoded[2][1] as? [String] == [duplicateTag])
        #expect(decoded[2][5] is NSNull)
        #expect(decoded[3][1] as? [String] == ["slow"])
        #expect(decoded[3][2] as? Bool == true)
        #expect(decoded[3][3] as? String == "142 ms")
    }

    @Test func aDuplicateWhoseCopyIsInAnNPlusOneGroupIsASingleRowWithItsTag() throws {
        let items = (1...5).map { seq in Self.query(seq, "select * from `items` where `id` = \(seq)", pattern: "select * from `items` where `id` = ?", line: 24) }
        let again = Self.query(6, "select * from `items` where `id` = 1", pattern: "select * from `items` where `id` = ?", line: 90)
        let entries = items + [again]
        let context = try page()

        let rows = try run("JSON.stringify(queryRows(value).map((row) => [row.queries.map((query) => query.seq), row.tags]))", with: entries, in: context)
        let app = QueryRow.rows(of: entries, marks: QueryMarks(entries)) { entry in entry }

        #expect(rows == #"[[[1,2,3,4,5],["N+1 · 5×"]],[[6],["duplicate"]]]"#)
        #expect(app.map { row in row.entries.map(\.seq) } == [[1, 2, 3, 4, 5], [6]])
        #expect(app.map(\.kind) == [.nPlusOne, .single])
    }

    @Test func anNPlusOneLineWithoutAPatternHasNoLaravelHint() throws {
        let entries = (1...5).map { seq in Self.query(seq, "SELECT * FROM wp_postmeta WHERE post_id = \(seq)", file: "/w/blog/wp-content/themes/shop/functions.php", line: 12) }
        let context = try page()

        #expect(try run("queryRows(value)[0].hint", with: entries, in: context) == "This line runs the same query 5 times with other values. One query for all values is faster.")
        #expect(try run("queryRows(value)[0].text", with: entries, in: context) == "SELECT * FROM wp_postmeta WHERE post_id = ?")
    }

    @Test(arguments: [0.084, 0.125, 0.84, 0.994, 0.996, 2.25, 9.6, 9.65, 38.44, 99.94, 99.96, 142.4, 142.5, 999.4, 999.6, 1450])
    func theTimeOfAQueryIsTheTimeOfTheApp(milliseconds: Double) throws {
        #expect(try run("millisecondsText(value, 'en-US')", with: milliseconds, in: try page()) == DumpEntryText.milliseconds(milliseconds, locale: Self.english))
    }

    @Test func theInfoLineIsTheInfoLineOfTheApp() throws {
        let requests = [
            DumpedRequest(id: "r1", kind: .http, method: "GET", target: "/checkout", started: Self.started, status: 200, duration: 0.184, dumpCount: 3, queryCount: 24, logCount: 2, jobCount: 2),
            DumpedRequest(id: "r2", kind: .http, method: "GET", target: "/api/orders", started: Self.started, status: 200, duration: 0.061, queryCount: 3, jobCount: 1),
            DumpedRequest(id: "r3", kind: .command, target: "php artisan import:products", started: Self.started, exitCode: 0, duration: 3.2, dumpCount: 4),
            DumpedRequest(id: "j1", kind: .job, target: "App\\Jobs\\SendOrderMail", started: Self.started, duration: 0.22, queryCount: 4, job: JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail", queue: "default", connection: "redis", outcome: .done)),
            DumpedRequest(id: "j2", kind: .job, target: "App\\Jobs\\SyncStock", started: Self.started, duration: 1.4, logCount: 1, job: JobRun(system: .laravel, name: "App\\Jobs\\SyncStock", attempt: 3, maxTries: 3, outcome: .failed)),
            DumpedRequest(id: "j3", kind: .job, target: "App\\Jobs\\Retry", started: Self.started, duration: 65.2, job: JobRun(system: .laravel, name: "App\\Jobs\\Retry", outcome: .released)),
            DumpedRequest(id: "j4", kind: .job, target: "woocommerce_cleanup_draft_orders", started: Self.started, dumpCount: 1, job: JobRun(system: .action, name: "woocommerce_cleanup_draft_orders")),
            DumpedRequest(id: "j5", kind: .job, target: "wp_scheduled_delete", started: Self.started, duration: 0.3, job: JobRun(system: .cron, name: "wp_scheduled_delete", outcome: .failed)),
            DumpedRequest(id: "j6", kind: .job, target: "App\\Jobs\\Import", started: Self.started, job: JobRun(system: .laravel, name: "App\\Jobs\\Import", attempt: 2, outcome: .failed)),
        ]
        let context = try page()

        for request in requests {
            #expect(try run("summary(value)", with: request, in: context) == DumpEntryText.summary(of: request, locale: Self.english))
            #expect(try run("String(jobStatusText(value))", with: request, in: context) == DumpEntryText.jobStatus(of: request, locale: Self.english) ?? "null")
            #expect(try run("displayMethod(value)", with: request, in: context) == request.displayMethod)
            #expect(try run("String(statusText(value))", with: request, in: context) == request.statusText ?? "null")
        }

        #expect(try run("summary(value)", with: requests[0], in: context) == "3 dumps · 24 queries · 200 · 184 ms")
        #expect(try run("summary(value)", with: requests[4], in: context) == "try 3 of 3 · 1 log line · 1.4 s")
        #expect(try run("presentKinds(value).join()", with: requests[0], in: context) == "dump,query,log,job")
    }

    @Test func theTagOfALogLineOrAJobRowHasTheToneOfTheApp() throws {
        let levels = ["emergency", "alert", "critical", "error", "ERROR", "warning", "notice", "info", "debug", "deprecated"]
        let logs = levels.map { level in CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .log, label: level, text: "Message.") }
        let phpErrors = ["PHP error", "PHP fatal error", "PHP warning"].map { detail in CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .log, label: "notice", text: "Message.", detail: detail) }
        let jobs = ["queued", "sync", "scheduled", "failed"].map { label in CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .job, label: label, text: "App\\Jobs\\SendOrderMail", milliseconds: 12) }
        let names: [DumpTagTone: String] = [.error: "red", .warning: "warning", .accent: "accent", .neutral: "gray"]
        let context = try page()

        for entry in logs + phpErrors + jobs {
            #expect(try run("tone(value)", with: entry, in: context) == names[DumpEntryText.tone(of: entry)])
            #expect(try run("ranInRequest(value)", with: entry, in: context) == String(entry.ranInRequest))
        }

        #expect(DumpEntryText.tone(of: jobs[3]) == .error)
        #expect(jobs[3].ranInRequest)

        #expect(try run("droppedText(value)", with: 1204, in: context) == DumpEntryText.droppedQueries(1204))
        #expect(try run("nPlusOneHint(5, false)", with: 0, in: context) == DumpEntryText.nPlusOneNote(count: 5, isLaravel: false))
    }

    @Test func aBlockHasTheTitleAndTheMessageOfTheApp() throws {
        let blocks = [
            DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "/w/shop/.env"),
            DumpBlock(host: "fix.shop.test", reason: .varDumperFormat),
            DumpBlock(host: "blog.test", reason: .userIni, file: "/w/blog/.user.ini"),
            DumpBlock(host: "blog.test", reason: .userIni),
            DumpBlock(host: "blog.test", reason: .savequeries, file: "/w/blog/wp-config.php"),
            DumpBlock(host: "blog.test", reason: .savequeries),
        ]
        let context = try page()

        for block in blocks {
            #expect(try run("[blockTitle(value), blockMessage(value)].join('|')", with: block, in: context) == "\(block.title)|\(block.message)")
        }
    }

    @Test(arguments: [
        DumpSettings(),
        DumpSettings(catchDumps: false, pageMode: .automatic, commands: true),
        DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true),
        DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: true, pageMode: .automatic, commands: true),
        DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true),
    ])
    func aBlockShowsOnlyWhileAKindThatItStopsIsOn(settings: DumpSettings) throws {
        let context = try page()

        for reason in [DumpBlock.Reason.varDumperFormat, .savequeries, .userIni] {
            let block = DumpBlock(host: "shop.test", reason: reason)
            let shown = try run("blockIsShown(value.block, value.settings)", with: ["block": AnyEncodable(block), "settings": AnyEncodable(settings)], in: context)

            #expect(shown == String(block.isShown(for: settings)), "\(reason)")
        }
    }

    @Test func theContextOfALogLineCopiesAsTheTextOfTheApp() throws {
        let tree = DumpNode(kind: .array, count: 5, children: [
            DumpNode(kind: .string, key: "note", value: "Leave it", cut: 12),
            DumpNode(kind: .object, key: "exception", className: "App\\Exceptions\\InvoiceMissing", ref: 412, cut: 2, children: [
                DumpNode(kind: .string, key: "message", access: .protected, value: "No invoice."),
                DumpNode(kind: .array, key: "trace", access: .private, count: 0),
                DumpNode(kind: .array, key: "lines", access: .dynamic, count: 3, cut: -1),
            ]),
            DumpNode(kind: .object, key: "0", index: true, className: "App\\Models\\Order", ref: 7, refersTo: 7),
            DumpNode(kind: .resource, key: "file", className: "stream", ref: 12),
            DumpNode(kind: .null, key: "coupon"),
        ])
        let context = try page()

        #expect(try run("treeText(value).join('\\n')", with: tree, in: context) == DumpEntryText.text(of: tree))
    }
}

// Two values of other types in one JSON object for the page.
private struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
