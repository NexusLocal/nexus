import Foundation
import JavaScriptCore
import NexusCore
import Testing
@testable import NexusDumps

// The page of the logs makes its times and texts itself. These tests run its script in
// JavaScriptCore. JavaScriptCore has the time zone of this Mac, as the browser has.
struct LogPageScriptTests {
    private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(LogPage.logicScript)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return context
    }

    private func run(_ expression: String, with json: String = "null", in context: JSContext) -> String {
        context.setObject(json, forKeyedSubscript: "input" as NSString)
        let result = context.evaluateScript("(() => { const value = JSON.parse(input); return \(expression); })()")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return result?.toString() ?? ""
    }

    private static func milliseconds(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Int {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
        return Int(date.timeIntervalSince1970 * 1000)
    }

    @Test func theWholeScriptOfThePageCompiles() throws {
        let context = try #require(JSContext())
        let html = LogPage.html(token: "t", nonce: "n", title: "Nexus Logs")
        let start = try #require(html.range(of: "<script nonce=\"n\">\n"))
        let end = try #require(html.range(of: "</script>", options: .backwards))
        context.setObject(String(html[start.upperBound..<end.lowerBound]), forKeyedSubscript: "source" as NSString)

        let result = context.evaluateScript("new Function(source); 'compiles'")

        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        #expect(result?.toString() == "compiles")
    }

    @Test func thePageHasItsTokenItsNonceAndNoPlaceholder() {
        let html = LogPage.html(token: "abc123", nonce: "n0nce", title: "Nexus <Logs>")

        #expect(html.contains(#"<meta name="nexus-token" content="abc123">"#))
        #expect(html.contains(#"<script nonce="n0nce">"#))
        #expect(html.contains(#"<style nonce="n0nce">"#))
        #expect(html.contains("<title>Nexus &lt;Logs&gt;</title>"))
        #expect(html.contains(#"<a class="segment" href="/logs" aria-current="page">Logs</a>"#))
        #expect(html.contains("It only reads the logs. Clear a log in the app."))
        #expect(html.hasSuffix("</script>\n</body>\n</html>\n"))
        #expect(!html.contains("{{"))
        #expect(!html.contains("innerHTML"))
        #expect(!html.contains("Clear…"))
    }

    @Test func theTimesAreInTheZoneOfTheMacAsOnTheLogsScreen() throws {
        let context = try page()
        let now = Self.milliseconds(2026, 11, 23, 15)
        let today = Self.milliseconds(2026, 11, 23, 9, 5, 7)
        let yesterday = Self.milliseconds(2026, 11, 22, 23, 59, 59)
        let friday = Self.milliseconds(2026, 11, 20, 0, 0, 1)
        let lastYear = Self.milliseconds(2025, 12, 31, 12)

        #expect(run("clockText(\(today))", in: context) == "09:05:07")
        #expect(run("dayTitle(\(today), \(now))", in: context) == "Today · Monday 23 November")
        #expect(run("dayTitle(\(yesterday), \(now))", in: context) == "Yesterday · Sunday 22 November")
        #expect(run("dayTitle(\(friday), \(now))", in: context) == "Friday 20 November")
        #expect(run("dayTitle(\(lastYear), \(now))", in: context) == "Wednesday 31 December 2025")
        #expect(run("fullTime(\(today), \(now))", in: context) == "Today at 09:05:07")
        #expect(run("fullTime(\(yesterday), \(now))", in: context) == "Yesterday at 23:59:59")
        #expect(run("fullTime(\(friday), \(now))", in: context) == "Friday 20 November at 00:00:01")
        #expect(run("sinceText(\(friday), \(now))", in: context) == "on Friday 20 November at 00:00:01")
        #expect(run("sinceText(\(yesterday), \(now))", in: context) == "yesterday at 23:59:59")
        #expect(run("rowDay({ time: null, sortTime: \(friday) }, \(now))", in: context) == "Friday 20 November")
        #expect(run("rowDay({ time: null, sortTime: 0 }, \(now))", in: context) == "No time in the log")
    }

    @Test func theCountLineNamesTheFirstEntryOfTheGroup() throws {
        let context = try page()
        let now = Self.milliseconds(2026, 11, 23, 15)
        let newest = Self.milliseconds(2026, 11, 23, 14, 18, 31)
        let sameDay = Self.milliseconds(2026, 11, 23, 13, 52, 10)
        let yesterday = Self.milliseconds(2026, 11, 22, 14, 18, 31)

        #expect(run("countText({ count: 12, time: \(newest), firstTime: \(sameDay) }, \(now))", in: context) == "12 times, the first at 13:52:10")
        #expect(run("countText({ count: 3, time: \(newest), firstTime: \(yesterday) }, \(now))", in: context) == "3 times, the first yesterday at 14:18:31")
        #expect(run("countText({ count: 2, time: null, firstTime: null }, \(now))", in: context) == "2 times")
    }

    @Test func theSecondLineOfARowIsTheLineOfTheApp() throws {
        let context = try page()
        let laravel = #"{"name":"laravel.log","kind":"app"}"#

        #expect(run("rowInfo(value.row, value.file)", with: #"{"row":{"exception":"QueryException","source":"app/Models/Order.php","sourceLine":131,"context":[]},"file":\#(laravel)}"#, in: context) == "QueryException · app/Models/Order.php:131")
        #expect(run("rowInfo(value.row, value.file)", with: #"{"row":{"exception":"RedisException","context":["user_id 18"]},"file":\#(laravel)}"#, in: context) == "RedisException · laravel.log · user_id 18")
        #expect(run("rowInfo(value.row, value.file)", with: #"{"row":{"context":["order_id 1042","trace_id 9f2c41d0"]},"file":\#(laravel)}"#, in: context) == "laravel.log · order_id 1042 · trace_id 9f2c41d0")
        #expect(run("rowInfo(value.row, value.file)", with: #"{"row":{"level":"500","context":[]},"file":{"name":"Requests","kind":"requests"}}"#, in: context) == "Requests · status 500")
        #expect(run("rowInfo(value.row, value.file)", with: #"{"row":{"source":"functions.php","sourceLine":212},"file":{"name":"PHP errors","kind":"phpErrors"}}"#, in: context) == "PHP errors · functions.php:212")
    }

    @Test func theTagsTheChipsAndTheTimeOfTheLogFollowTheApp() throws {
        let context = try page()
        let file = #"{"kind":"app","zone":"UTC","zoneOffset":0}"#

        #expect(run("[levelTone('error'), levelTone('warning'), levelTone('info'), levelTone('debug')].join()", in: context) == "red,warning,gray,gray")
        #expect(run("hiddenText(value)", with: #""\#(String(repeating: "é", count: 45))""#, in: context) == String(repeating: "é", count: 40) + "…")
        #expect(run("hiddenText('Short.')", in: context) == "Short.")
        #expect(run("logTimeNote({ logTime: '2026-11-23 13:18:31' }, value, 3600)", with: file, in: context) == "13:18:31 UTC in the log")
        #expect(run("logTimeNote({ logTime: '2026-11-23T13:18:31.123456+00:00' }, value, 3600)", with: file, in: context) == "13:18:31 UTC in the log")
        #expect(run("String(logTimeNote({ logTime: '2026-11-23 13:18:31' }, value, 0))", with: file, in: context) == "null")
        #expect(run("String(logTimeNote({ logTime: '[23-Nov-2026 13:18:31]' }, { kind: 'phpErrors', zone: 'UTC', zoneOffset: 0 }, 3600))", in: context) == "null")
    }

    @Test func theFramesInVendorFormOneRowUntilAClick() throws {
        let context = try page()
        let frames = #"[{"file":"/w/app/Order.php","vendor":false},{"file":"/w/vendor/a.php","vendor":true},{"file":"/w/vendor/b.php","vendor":true},{"file":null,"vendor":true}]"#

        #expect(run("JSON.stringify(frameGroups(value, false).map((group) => group.frame ? group.index : `v${group.vendor}@${group.first}`))", with: frames, in: context) == #"[0,"v2@1",3]"#)
        #expect(run("frameGroups(value, true).length", with: frames, in: context) == "4")
        #expect(run("stackText(value)", with: frames, in: context) == "2 frames of the app, 2 in vendor/")
    }

    // The Markdown of the page is the Markdown of the app for the same entry.
    @Test(arguments: [0, 1, 2, 3])
    func theMarkdownOfThePageIsTheMarkdownOfTheApp(row: Int) throws {
        let project = try LogPageStoreTests.project()
        let store = LogPageStore()
        let answer = try LogPageStoreTests.json(store.entries(of: project.place, paths: project.paths, request: LogPageQuery(["place": "shop.test", "group": "0", "levels": "error,warning,info"])))
        let entry = LogPageStoreTests.rows(answer)[row]
        let detailResponse = store.detail(of: project.place, paths: project.paths, fileKey: LogPageStoreTests.laravelKey(answer), offset: try #require(entry["offset"] as? UInt64))
        let detailJSON = String(decoding: detailResponse.body, as: UTF8.self)
        let text = try #require(try LogPageStoreTests.json(detailResponse)["text"] as? String)
        let level = try #require(entry["level"] as? String)
        let expected = LogEntryParser.detail(of: text, kind: .app, isCut: false).markdown(level: level, time: "Today at 14:02:00", file: "laravel.log", project: project.root)

        let markdown = run("entryMarkdown(value, 'Today at 14:02:00', 'laravel.log')", with: detailJSON, in: try page())

        #expect(markdown == expected)
        #expect(markdown.contains("**\(level)** Today at 14:02:00 in `laravel.log`"))
    }
}
