import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusMCP

struct DumpTextTests {
    private static let utc = DumpTimeText(timeZone: TimeZone(identifier: "UTC")!)
    private static let now = Date(timeIntervalSince1970: 1_762_850_100)
    private static let started = Date(timeIntervalSince1970: 1_762_850_000)

    private static func request(_ id: String) -> DumpedRequest {
        DumpedRequest(id: id, kind: .http, method: "GET", target: "/\(id)", url: "https://shop.test/\(id)", host: "shop.test", site: "shop.test", started: started, dumpCount: 1, lastSeq: 1)
    }

    @Test func aWebRequestShowsItsURLStatusAndDuration() {
        var request = Self.request("checkout")
        request.status = 200
        request.duration = 0.184

        #expect(DumpText.header(of: request, now: Self.now, times: Self.utc) == "08:33:20  GET  https://shop.test/checkout  200  184 ms")
    }

    @Test func aRequestThatRunsHasNoStatus() {
        #expect(DumpText.header(of: Self.request("checkout"), now: Self.now, times: Self.utc) == "08:33:20  GET  https://shop.test/checkout")
    }

    @Test func aCommandShowsItsExitCodeAndItsPlace() {
        let command = DumpedRequest(id: "c1", kind: .command, target: "php artisan migrate", site: "shop.test", workspace: "fix", started: Self.started, exitCode: 0, duration: 65.2, dumpCount: 1)

        #expect(DumpText.header(of: command, now: Self.now, times: Self.utc) == "08:33:20  CLI  php artisan migrate  exit 0  1 min 5 s  workspace fix of shop.test")
    }

    @Test func aRequestOfAnEarlierDayShowsItsDate() {
        let tomorrow = Self.now.addingTimeInterval(86_400)

        #expect(DumpText.header(of: Self.request("checkout"), now: tomorrow, times: Self.utc).hasPrefix("2025-11-11 08:33:20  GET"))
    }

    @Test func theTimeFollowsTheTimeZone() {
        let amsterdam = DumpTimeText(timeZone: TimeZone(identifier: "Europe/Amsterdam")!)

        #expect(amsterdam.text(Self.started, now: Self.now) == "09:33:20")
    }

    @Test func aDumpShowsItsSourceAndItsText() {
        let dump = CaughtDump(requestID: "r1", seq: 1, time: Self.started, file: "/w/shop/app/Http/Controllers/CheckoutController.php", line: 42, text: "array:1 [\n  \"id\" => 7\n]\n")

        #expect(DumpText.lines(of: dump) == [
            "  dump at /w/shop/app/Http/Controllers/CheckoutController.php:42",
            "    array:1 [",
            "      \"id\" => 7",
            "    ]",
        ])
    }

    @Test func aDDWithALabelAndACutTextSaysSo() {
        let dump = CaughtDump(requestID: "r1", seq: 2, time: Self.started, kind: .dd, file: "/w/shop/resources/views/cart.blade.php", label: "cart", text: "\"a\"\n\n\"b\"", truncated: true)

        #expect(DumpText.lines(of: dump) == [
            "  dd \"cart\" at /w/shop/resources/views/cart.blade.php",
            "    \"a\"",
            "",
            "    \"b\"",
            "    [The text stops here, because the dump is larger than 64 KB.]",
        ])
    }

    @Test func aDumpWithoutASourceShowsOnlyItsKind() {
        #expect(DumpText.lines(of: CaughtDump(requestID: "r1", seq: 1, time: Self.started, text: "1")) == ["  dump", "    1"])
    }

    @Test func theJSONLineHoldsTheDumpAndItsRequestWithoutTheNumbersOfTheStore() throws {
        let dump = CaughtDump(requestID: "checkout", seq: 1, time: Self.started, text: "array:1 [\n  0 => 1\n]", number: 41)
        var request = Self.request("checkout")
        request.lastNumber = 41
        request.firstNumber = 40

        let line = try DumpText.json(request: request, dump: dump)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let caught = try #require(object["dump"] as? [String: Any])
        let header = try #require(object["request"] as? [String: Any])

        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("{\"dump\":{"))
        #expect(line.contains("\"url\":\"https://shop.test/checkout\""))
        #expect(Set(object.keys) == ["dump", "request"])
        #expect(caught["text"] as? String == "array:1 [\n  0 => 1\n]")
        #expect(caught["seq"] as? Int == 1)
        #expect(caught["time"] as? String == "2025-11-11T08:33:20Z")
        #expect(header["site"] as? String == "shop.test")
        #expect(header["lastSeq"] as? Int == 1)
        #expect(!line.contains("umber"))
        #expect(CaughtDumpLine(request: request, dump: dump).dump.number == 0)
    }

    // The texts of a block are DumpBlock.title and DumpBlock.message. A block of a kind that is
    // switched off does not show.
    @Test func theNotesShowCatchDumpsTheProblemAndTheBlocksOfTheSite() {
        let blog = DumpBlock(host: "blog.test", reason: .userIni, file: "/w/blog/.user.ini", place: DumpPlace(site: "blog.test"))
        let shop = DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "/w/shop/.env", place: DumpPlace(site: "shop.test"))
        let fix = DumpBlock(host: "fix.shop.test", reason: .varDumperFormat, place: DumpPlace(site: "shop.test", workspace: "fix"))
        let list = DumpList(
            requests: [],
            settings: DumpSettings(catchDumps: false, pageMode: .automatic, commands: true),
            blocked: [blog, shop, fix],
            receiving: true,
            problem: "Nexus catches no dumps, because nexusd cannot listen on its socket.\nThe second line."
        )

        let catching = DumpList(requests: [], settings: DumpSettings(), blocked: [blog, shop, fix], receiving: true)

        #expect(DumpText.notes(of: list.state, place: DumpPlace(site: "shop.test")) == [
            "Catch dumps is off. So Nexus catches no new dumps. Turn it on with: nexus dumps settings --catch-dumps on",
            "Warning: Nexus catches no dumps, because nexusd cannot listen on its socket.",
            "Warning: The second line.",
        ])
        #expect(DumpText.notes(of: list.state, place: nil).last == "Warning: \(blog.title). \(blog.message)")
        #expect(DumpText.notes(of: list.state, place: nil).count == 4)
        #expect(DumpText.notes(of: catching.state, place: DumpPlace(site: "shop.test")) == ["Warning: \(shop.title). \(shop.message)"])
        #expect(DumpText.notes(of: catching.state, place: DumpPlace(site: "shop.test", workspace: "fix")) == ["Warning: \(fix.title). \(fix.message)"])
        #expect(DumpText.notes(of: catching.state, place: nil).count == 3)
    }

    @Test func aListThatCatchesHasNoNotes() {
        let list = DumpList(requests: [Self.request("r1")], settings: DumpSettings(), receiving: true)

        #expect(DumpText.notes(of: list.state, place: nil).isEmpty)
    }

    @Test func anEmptyListSaysSo() {
        #expect(DumpText.noRequests(of: nil) == "Nexus has no requests.")
        #expect(DumpText.noRequests(of: "fix.shop.test") == "Nexus has no requests of fix.shop.test.")
    }

    @Test func theSettingsShowOnEachLine() {
        #expect(DumpText.lines(of: DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: true, pageMode: .always, commands: true)) == [
            "Catch dumps       off",
            "Catch queries     on",
            "Catch log lines   off",
            "Catch queue jobs  on",
            "Page              always (All requests)",
            "Commands          on",
        ])
    }

    @Test func aJobOfAWorkerShowsItsTryItsQueueItsWorkerAndItsRequest() {
        let job = JobRun(system: .laravel, name: "App\\Jobs\\SyncStock", queue: "default", connection: "redis", attempt: 3, maxTries: 3, outcome: .failed, command: "php artisan queue:work", queuedBy: "checkout")
        let request = DumpedRequest(id: "j1", kind: .job, target: "App\\Jobs\\SyncStock", site: "shop.test", started: Self.started, duration: 0.22, logCount: 1, job: job)

        #expect(DumpText.header(of: request, now: Self.now, times: Self.utc) == "08:33:20  JOB  App\\Jobs\\SyncStock  try 3 of 3  220 ms  shop.test")
        #expect(DumpText.details(of: request) == [
            "  Queue   default · redis",
            "  Worker  php artisan queue:work",
            "  From    request checkout",
            "  1 log line",
        ])
    }

    @Test func aWordPressJobShowsItsSystem() {
        let cron = DumpedRequest(id: "c1", kind: .job, target: "wp_scheduled_delete", started: Self.started, job: JobRun(system: .cron, name: "wp_scheduled_delete"))

        #expect(DumpText.header(of: cron, now: Self.now, times: Self.utc) == "08:33:20  CRON  wp_scheduled_delete")
    }

    @Test func onlyARequestWithOtherKindsGetsItsCountsAndReadDumpsAlwaysGetsTheID() {
        var request = Self.request("checkout")

        #expect(DumpText.details(of: request).isEmpty)
        #expect(DumpText.details(of: request, id: true) == ["  request checkout · 1 dump"])

        request.dumpCount = 0
        request.queryCount = 1
        request.queryMilliseconds = 0.84
        request.droppedQueries = 1

        #expect(DumpText.details(of: request, locale: Locale(identifier: "en_US_POSIX")) == ["  1 query in 0.84 ms", "  Nexus did not keep 1 more query."])
    }

    @Test func eachQueryGetsTheTagOfItsGroupAsTheAppShowsIt() {
        let duplicates = (1...3).map { seq in CaughtDump(requestID: "r1", seq: seq, time: Self.started, kind: .query, file: "/w/a.php", line: seq, text: "select 1", milliseconds: 120) }
        let posts = (4...8).map { seq in CaughtDump(requestID: "r1", seq: seq, time: Self.started, kind: .query, file: "/w/b.php", line: 9, text: "SELECT * FROM wp_posts WHERE ID = \(seq % 7)", milliseconds: 0.2) }
        let copy = CaughtDump(requestID: "r1", seq: 9, time: Self.started, kind: .query, file: "/w/c.php", line: 3, text: "SELECT * FROM wp_posts WHERE ID = 4", milliseconds: 0.2)
        let tags = QueryTags(duplicates + posts + [copy])

        #expect(tags.texts(of: duplicates[0]) == ["duplicate · 3×", "slow"])
        #expect(tags.texts(of: posts[0]) == ["N+1 · 5×"])
        #expect(tags.texts(of: posts[1]) == ["N+1 · 5×"])
        #expect(tags.texts(of: copy) == ["duplicate"])
        #expect(tags.note(after: posts[0]) == "This line runs the same query 5 times with other values. One query for all values is faster.")
        #expect(tags.note(after: posts[1]) == nil)
        #expect(tags.note(after: duplicates[0]) == nil)
    }

    @Test func aLogLineShowsItsLevelItsChannelAndItsContextAsText() {
        let tree = #"""
        {"kind":"array","count":4,"children":[
          {"kind":"string","key":"note","value":"Leave it","cut":12},
          {"kind":"object","key":"exception","class":"App\\Exceptions\\InvoiceMissing","ref":412,"cut":2,"children":[
            {"kind":"string","key":"message","access":"protected","value":"No invoice."},
            {"kind":"array","key":"trace","access":"private","count":0}
          ]},
          {"kind":"object","key":"0","index":true,"class":"App\\Models\\Order","ref":7,"refersTo":7},
          {"kind":"null","key":"coupon"}
        ]}
        """#
        let log = CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .log, file: "/w/shop/app/Services/PriceApi.php", line: 58, label: "warning", text: "The price API answered slowly.\nIt took 1.24 s.", treeJSON: tree, detail: "PHP warning", truncated: true)

        #expect(DumpText.lines(of: log) == [
            "  log  warning (PHP warning)  The price API answered slowly.  at /w/shop/app/Services/PriceApi.php:58",
            "    It took 1.24 s.",
            "    [The message stops here, because it is larger than 64 KB.]",
            "    array:4 [",
            "      \"note\" => \"Leave it\"…12",
            "      \"exception\" => App\\Exceptions\\InvoiceMissing {#412",
            "        #message: \"No invoice.\"",
            "        -trace: []",
            "        …2",
            "      }",
            "      0 => App\\Models\\Order {#7}",
            "      \"coupon\" => null",
            "    ]",
        ])
    }

    @Test func aJobRowShowsItsLabelItsClassItsTimeAndItsQueue() {
        let sync = CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .job, file: "/w/shop/app/Http/Controllers/CheckoutController.php", line: 61, label: "sync", text: "App\\Jobs\\UpdateStock", milliseconds: 12, detail: "sync")

        #expect(DumpText.lines(of: sync) == ["  job  sync  App\\Jobs\\UpdateStock  12 ms  sync  at /w/shop/app/Http/Controllers/CheckoutController.php:61"])
    }

    @Test func aSyncJobThatThrewShowsAsFailed() {
        let failed = CaughtDump(requestID: "r1", seq: 1, time: Self.started, kind: .job, file: "/w/shop/app/Http/Controllers/CheckoutController.php", line: 61, label: "failed", text: "App\\Jobs\\UpdateStock", milliseconds: 12, detail: "sync")

        #expect(DumpText.lines(of: failed) == ["  job  failed  App\\Jobs\\UpdateStock  12 ms  sync  at /w/shop/app/Http/Controllers/CheckoutController.php:61"])
    }

    @Test func aBlockForSaveQueriesNamesItsFile() {
        let block = DumpBlock(host: "blog.test", reason: .savequeries, file: "/w/blog/wp-config.php", place: DumpPlace(site: "blog.test"))
        let list = DumpList(requests: [], settings: DumpSettings(catchDumps: true, catchQueries: true, pageMode: .automatic, commands: true), blocked: [block], receiving: true)
        let withoutQueries = DumpList(requests: [], settings: DumpSettings(), blocked: [block], receiving: true)

        #expect(DumpText.notes(of: list.state, place: nil) == ["Warning: \(block.title). \(block.message)"])
        #expect(DumpText.notes(of: withoutQueries.state, place: nil).isEmpty)
        #expect(block.message.hasPrefix("The wp-config.php of blog.test sets SAVEQUERIES to false."))
    }
}

private extension DumpText {
    static func lines(of entry: CaughtDump) -> [String] {
        lines(of: entry, tags: QueryTags([entry]))
    }
}
