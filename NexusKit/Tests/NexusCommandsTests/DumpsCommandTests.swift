import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusMCP
import Testing
@testable import NexusCommands

// The tags of the entries that a test shows, as KnownQueries gives them when the batch holds all
// queries of each request.
private extension DumpPrinter {
    @discardableResult
    mutating func show(_ entries: [CaughtDump], of request: DumpedRequest, now: Date) -> Bool {
        show(entries, of: request, now: now, tags: QueryTags(entries))
    }

    @discardableResult
    mutating func show(latest batch: DumpBatch, now: Date) -> Bool {
        show(latest: batch, now: now, tags: Self.tags(of: batch))
    }

    mutating func show(_ batch: DumpBatch, now: Date) {
        show(batch, now: now, tags: Self.tags(of: batch))
    }

    static func tags(of batch: DumpBatch) -> [String: QueryTags] {
        Dictionary(uniqueKeysWithValues: batch.requests.map { request in (request.id, QueryTags(batch.dumps.filter { $0.requestID == request.id })) })
    }
}

struct DumpsCommandTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let now = Date(timeIntervalSince1970: 1_762_850_100)
    private static let started = Date(timeIntervalSince1970: 1_762_850_000)
    private static let shop = DumpPlace(site: "shop.test")
    private static let epoch = "4f1c9a0e"

    private static func cursor(_ number: Int, epoch: String = epoch) -> DumpCursor {
        DumpCursor(epoch: epoch, number: number)
    }

    private static func request(_ id: String, site: String? = "shop.test", workspace: String? = nil, lastSeq: Int = 1) -> DumpedRequest {
        DumpedRequest(id: id, kind: .http, method: "GET", target: "/\(id)", url: "https://shop.test/\(id)", host: "shop.test", site: site, workspace: workspace, started: started, dumpCount: lastSeq, lastSeq: lastSeq)
    }

    private static func dump(_ seq: Int, of request: String, text: String? = nil) -> CaughtDump {
        CaughtDump(requestID: request, seq: seq, time: started, text: text ?? "\(request) \(seq)")
    }

    private static func list(_ requests: [DumpedRequest], cursor: DumpCursor? = cursor(0), settings: DumpSettings = DumpSettings(), blocked: [DumpBlock] = []) -> DumpList {
        DumpList(requests: requests, settings: settings, blocked: blocked, receiving: true, cursor: cursor, loaded: cursor != nil)
    }

    private final class Output {
        var lines: [String] = []
        var errors: [String] = []

        func write(_ written: [String], _ toErrors: Bool) {
            if toErrors {
                errors += written
            } else {
                lines += written
            }
        }
    }

    private func printer(json: Bool = false, into output: Output) -> DumpPrinter {
        DumpPrinter(json: json, timeZone: Self.utc, locale: Locale(identifier: "en_US_POSIX"), write: output.write)
    }

    private func parse(_ arguments: [String]) throws -> any ParsableCommand {
        try NexusCommand.parseAsRoot(arguments)
    }

    private func follower(_ place: DumpPlace? = nil, at cursor: DumpCursor = cursor(0)) -> DumpFollower {
        var follower = DumpFollower(place: place)
        follower.begin(at: cursor)
        return follower
    }

    @Test func nexusDumpsListsTheNewestRequestsOfAllSites() throws {
        let list = try #require(try parse(["dumps"]) as? DumpsCommand.List)

        #expect(list.site == nil)
        #expect(list.limit == nil)
        #expect(!list.follow)
        #expect(!list.json)
        #expect(!list.clear)
    }

    @Test func theOptionsOfTheListParse() throws {
        let list = try #require(try parse(["dumps", "--site", "fix.shop.test", "--limit", "3", "--follow", "--json"]) as? DumpsCommand.List)

        #expect(list.site == "fix.shop.test")
        #expect(list.limit == 3)
        #expect(list.follow)
        #expect(list.json)
    }

    @Test func followTakesALimitOfZero() throws {
        let list = try #require(try parse(["dumps", "--follow", "--limit", "0"]) as? DumpsCommand.List)

        #expect(list.limit == 0)
    }

    @Test(arguments: [
        (["dumps", "--clear", "--follow"], "Use --clear alone or with --site."),
        (["dumps", "--clear", "--json"], "Use --clear alone or with --site."),
        (["dumps", "--clear", "--limit", "5"], "Use --clear alone or with --site."),
        (["dumps", "--limit=-1"], "Give a limit of 0 or more."),
        (["dumps", "--limit", "0"], "Give a limit of 1 or more. Only --follow takes 0."),
    ])
    func aWrongCombinationSaysWhy(_ arguments: [String], message: String) throws {
        let error = try #require(#expect(throws: (any Error).self) { try parse(arguments) })

        #expect(NexusCommand.message(for: error) == message)
    }

    @Test(arguments: [
        ["dumps", "settings", "--page", "sometimes"],
        ["dumps", "settings", "--catch-dumps", "yes"],
    ])
    func aWrongValueIsRefused(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    @Test func clearTakesASite() throws {
        let list = try #require(try parse(["dumps", "--clear", "--site", "shop.test"]) as? DumpsCommand.List)

        #expect(list.clear)
        #expect(list.site == "shop.test")
    }

    @Test func theSettingsParse() throws {
        let settings = try #require(try parse(["dumps", "settings", "--catch-dumps", "off", "--page", "never", "--commands", "on"]) as? DumpsCommand.Settings)

        #expect(settings.catchDumps == .off)
        #expect(settings.page == .never)
        #expect(settings.commands == .on)
    }

    @Test func theNewSwitchesParse() throws {
        let settings = try #require(try parse(["dumps", "settings", "--catch-queries", "on", "--catch-logs", "off", "--catch-jobs", "on"]) as? DumpsCommand.Settings)
        let none = try #require(try parse(["dumps", "settings"]) as? DumpsCommand.Settings)

        #expect(settings.catchQueries == .on)
        #expect(settings.catchLogs == .off)
        #expect(settings.catchJobs == .on)
        #expect(settings.catchDumps == nil)
        #expect(none.catchQueries == nil)
        #expect(none.catchLogs == nil)
        #expect(none.catchJobs == nil)
    }

    @Test(arguments: [["dumps", "settings", "--catch-queries", "yes"], ["dumps", "settings", "--catch-jobs"]])
    func aWrongSwitchIsRefused(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    private static let controller = "/w/shop/app/Http/Controllers/CheckoutController.php"

    private static func query(_ seq: Int, of request: String = "checkout", _ text: String, pattern: String? = nil, file: String = controller, line: Int = 38, milliseconds: Double = 0.84) -> CaughtDump {
        CaughtDump(requestID: request, seq: seq, time: started, kind: .query, file: file, line: line, label: "mysql", text: text, milliseconds: milliseconds, pattern: pattern, number: seq)
    }

    private static func productQueries(_ seqs: ClosedRange<Int>, of request: String = "checkout") -> [CaughtDump] {
        seqs.map { seq in query(seq, of: request, "select * from `products` where `id` = \(seq) limit 1", pattern: "select * from `products` where `id` = ? limit 1", file: "/w/shop/app/Models/CartItem.php", line: 24) }
    }

    @Test func aRequestShowsItsEntriesOfAllKindsInTheirOrder() {
        let output = Output()
        var printer = printer(into: output)
        let request = DumpedRequest(id: "checkout", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", host: "shop.test", site: "shop.test", started: Self.started, status: 200, duration: 0.184, dumpCount: 1, lastSeq: 9, queryCount: 6, queryMilliseconds: 146.2, logCount: 1, jobCount: 1, marks: [.nPlusOne, .slow], droppedQueries: 1204)
        let tree = #"{"kind":"array","count":1,"children":[{"kind":"int","key":"order_id","value":"1042"}]}"#
        let entries = [CaughtDump(requestID: "checkout", seq: 1, time: Self.started, file: Self.controller, line: 42, text: "\"EUR\"")]
            + Self.productQueries(2...6)
            + [
                Self.query(7, "select count(*)\n  from `orders`", line: 51, milliseconds: 142),
                CaughtDump(requestID: "checkout", seq: 8, time: Self.started, kind: .log, file: "/w/shop/app/Http/Controllers/OrderController.php", line: 77, label: "error", text: "Order 1042 has no invoice.", treeJSON: tree, detail: "stack"),
                CaughtDump(requestID: "checkout", seq: 9, time: Self.started, kind: .job, file: Self.controller, line: 63, label: "queued", text: "App\\Jobs\\SendOrderMail", detail: "redis · default", ref: "9f1c"),
            ]

        let showed = printer.show(entries, of: request, now: Self.now)

        #expect(showed)
        #expect(output.lines == [
            "08:33:20  GET  https://shop.test/checkout  200  184 ms",
            "  1 dump · 6 queries in 146 ms · 1 log line · 1 job · N+1",
            "  Nexus did not keep 1204 more queries.",
            "  dump at \(Self.controller):42",
            "    \"EUR\"",
            "  query  0.84 ms  N+1 · 5×  select * from `products` where `id` = 2 limit 1  at /w/shop/app/Models/CartItem.php:24",
            "    This line runs the same query 5 times with other values. One query for all values is faster. In Laravel, load the relation with with().",
            "  query  0.84 ms  N+1 · 5×  select * from `products` where `id` = 3 limit 1  at /w/shop/app/Models/CartItem.php:24",
            "  query  0.84 ms  N+1 · 5×  select * from `products` where `id` = 4 limit 1  at /w/shop/app/Models/CartItem.php:24",
            "  query  0.84 ms  N+1 · 5×  select * from `products` where `id` = 5 limit 1  at /w/shop/app/Models/CartItem.php:24",
            "  query  0.84 ms  N+1 · 5×  select * from `products` where `id` = 6 limit 1  at /w/shop/app/Models/CartItem.php:24",
            "  query  142 ms  slow  select count(*) from `orders`  at \(Self.controller):51",
            "  log  error (stack)  Order 1042 has no invoice.  at /w/shop/app/Http/Controllers/OrderController.php:77",
            "    array:1 [",
            "      \"order_id\" => 1042",
            "    ]",
            "  job  queued  App\\Jobs\\SendOrderMail  redis · default  at \(Self.controller):63",
        ])
    }

    @Test func theTagsOfAQueryCountAllQueriesOfItsRequest() async {
        let output = Output()
        var printer = printer(into: output)
        var request = Self.request("checkout")
        request.queryCount = 6
        let all = Self.productQueries(1...6)
        let latest = DumpBatch(dumps: Array(all.suffix(2)), requests: [request], cursor: Self.cursor(6), olderCounts: ["checkout": 4])
        var queries = KnownQueries()
        var reads: [String] = []

        let tags = await queries.tags(for: latest) { id, after in
            reads.append("\(id) after \(after)")
            return all
        }
        printer.show(latest: latest, now: Self.now, tags: tags)

        #expect(reads == ["checkout after 0"])
        #expect(output.lines.filter { $0.hasPrefix("  query") }.allSatisfy { $0.contains("  N+1 · 6×  ") })
        #expect(!output.lines.contains { $0.hasPrefix("    This line") })
    }

    @Test func aBatchWithAllQueriesOfItsRequestReadsNothing() async {
        var request = Self.request("checkout")
        request.queryCount = 5
        let batch = DumpBatch(dumps: Self.productQueries(1...5) + [Self.dump(6, of: "other")], requests: [request, Self.request("other")], cursor: Self.cursor(6))
        var queries = KnownQueries()
        var reads: [String] = []

        let tags = await queries.tags(for: batch) { id, _ in
            reads.append(id)
            return []
        }

        #expect(reads.isEmpty)
        #expect(tags["checkout"]?.texts(of: batch.dumps[0]) == ["N+1 · 5×"])
        #expect(tags["other"]?.texts(of: batch.dumps[0]) == [])
    }

    @Test func aKnownRequestAsksOnlyAfterItsHighestQueryAndForgetsTheQueriesThatTheStoreRemoved() async {
        var request = Self.request("checkout")
        request.queryCount = 5
        let all = Self.productQueries(1...7)
        var queries = KnownQueries()
        var reads: [String] = []
        let read: (String, Int) async throws -> [CaughtDump] = { id, after in
            reads.append("\(id) after \(after)")
            return all.filter { query in query.number > after }
        }

        _ = await queries.tags(for: DumpBatch(dumps: Array(all[0..<5]), requests: [request], cursor: Self.cursor(5)), readRequest: read)
        request.queryCount = 7
        let second = await queries.tags(for: DumpBatch(dumps: [], requests: [request], cursor: Self.cursor(7)), readRequest: read)
        request.queryCount = 4
        request.firstNumber = 4
        let third = await queries.tags(for: DumpBatch(dumps: [], requests: [request], cursor: Self.cursor(7)), readRequest: read)

        #expect(reads == ["checkout after 5"])
        #expect(second["checkout"]?.texts(of: all[0]) == ["N+1 · 7×"])
        #expect(third["checkout"]?.texts(of: all[3]) == [])
        #expect(third["checkout"]?.texts(of: all[0]) == [])
    }

    @Test func aQueryThatTheUserRemovedNoLongerCountsInTheTags() async {
        var request = Self.request("checkout")
        request.queryCount = 5
        let all = Self.productQueries(1...5)
        var queries = KnownQueries()
        var reads: [String] = []
        let read: (String, Int) async throws -> [CaughtDump] = { id, _ in
            reads.append(id)
            return []
        }

        let before = await queries.tags(for: DumpBatch(dumps: all, requests: [request], cursor: Self.cursor(5)), readRequest: read)
        queries.forget(DumpChange(changed: [request], removedDumps: [5]))
        request.queryCount = 4
        let after = await queries.tags(for: DumpBatch(dumps: [], requests: [request], cursor: Self.cursor(5)), readRequest: read)

        #expect(before["checkout"]?.texts(of: all[0]) == ["N+1 · 5×"])
        #expect(after["checkout"]?.texts(of: all[0]) == [])
        #expect(reads.isEmpty)
    }

    @Test func jsonGivesEachEntryWithTheMarksOfAQuery() throws {
        let output = Output()
        var printer = printer(json: true, into: output)
        let entries = [Self.query(1, "select 1"), Self.query(2, "select 1"), Self.query(3, "select 2", milliseconds: 150), CaughtDump(requestID: "checkout", seq: 4, time: Self.started, kind: .log, label: "info", text: "Paid.")]

        printer.show(entries, of: Self.request("checkout"), now: Self.now)

        let lines = try output.lines.map { line in try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) }
        #expect(lines.count == 4)
        #expect(lines.map { ($0["dump"] as? [String: Any])?["kind"] as? String } == ["query", "query", "query", "log"])
        #expect(lines.map { $0["marks"] as? [String] } == [["duplicate"], ["duplicate"], ["slow"], nil])
        #expect((lines[0]["dump"] as? [String: Any])?["ms"] as? Double == 0.84)
        #expect(!output.lines.contains { $0.contains("umber") })
    }

    @Test func aRequestShowsItsLineOnceAboveItsDumps() {
        let output = Output()
        var printer = printer(into: output)

        printer.show([Self.dump(1, of: "first")], of: Self.request("first"), now: Self.now)
        printer.show([Self.dump(2, of: "first")], of: Self.request("first"), now: Self.now)
        printer.show([Self.dump(1, of: "second")], of: Self.request("second"), now: Self.now)
        let showedNothing = !printer.show([], of: Self.request("first"), now: Self.now)

        #expect(showedNothing)
        #expect(output.lines == [
            "08:33:20  GET  https://shop.test/first",
            "  dump",
            "    first 1",
            "  dump",
            "    first 2",
            "",
            "08:33:20  GET  https://shop.test/second",
            "  dump",
            "    second 1",
        ])
    }

    @Test func aMessageBetweenTheDumpsShowsTheRequestAgain() {
        let output = Output()
        var printer = printer(into: output)

        printer.show([Self.dump(1, of: "worker")], of: Self.request("worker"), now: Self.now)
        printer.say([DumpFollowLoop.waitText])
        printer.show([Self.dump(2, of: "worker")], of: Self.request("worker"), now: Self.now)

        #expect(output.lines == [
            "08:33:20  GET  https://shop.test/worker",
            "  dump",
            "    worker 1",
            "",
            DumpFollowLoop.waitText,
            "",
            "08:33:20  GET  https://shop.test/worker",
            "  dump",
            "    worker 2",
        ])
    }

    @Test func theNewestDumpsShowUnderTheLineOfTheirRequestWithTheCountOfTheOlderDumps() {
        let output = Output()
        var printer = printer(into: output)
        var finished = Self.request("page")
        finished.status = 200
        let latest = DumpBatch(
            dumps: [Self.dump(481, of: "worker"), Self.dump(1, of: "page"), Self.dump(482, of: "worker"), Self.dump(2, of: "page")],
            requests: [Self.request("worker"), finished],
            cursor: Self.cursor(9),
            olderCounts: ["worker": 480, "page": 1]
        )

        let showed = printer.show(latest: latest, now: Self.now)

        #expect(showed)
        #expect(output.lines == [
            "08:33:20  GET  https://shop.test/worker",
            "  480 older entries of this request are not shown. Use --limit to see more.",
            "  dump",
            "    worker 481",
            "  dump",
            "    worker 482",
            "",
            "08:33:20  GET  https://shop.test/page  200",
            "  1 older entry of this request is not shown. Use --limit to see more.",
            "  dump",
            "    page 1",
            "  dump",
            "    page 2",
        ])
    }

    @Test func noNewestDumpsShowNothing() {
        let output = Output()
        var printer = printer(into: output)

        let showed = printer.show(latest: DumpBatch(dumps: [], requests: [], cursor: Self.cursor(0)), now: Self.now)
        let withoutHeader = printer.show(latest: DumpBatch(dumps: [Self.dump(1, of: "gone")], requests: [], cursor: Self.cursor(1)), now: Self.now)

        #expect(!showed)
        #expect(!withoutHeader)
        #expect(output.lines.isEmpty)
    }

    @Test func jsonWritesTheCountOfTheOlderDumpsToTheErrors() {
        let output = Output()
        var printer = printer(json: true, into: output)
        let latest = DumpBatch(dumps: [Self.dump(5, of: "worker")], requests: [Self.request("worker")], cursor: Self.cursor(5), olderCounts: ["worker": 4])

        printer.show(latest: latest, now: Self.now)

        #expect(output.lines.count == 1)
        #expect(output.errors == ["Request worker: 4 older entries of this request are not shown. Use --limit to see more."])
    }

    @Test func aBatchShowsTheDumpsInTheOrderInWhichTheyArrived() {
        let output = Output()
        var printer = printer(into: output)

        printer.show(DumpBatch(dumps: [Self.dump(1, of: "a"), Self.dump(1, of: "b"), Self.dump(2, of: "a")], requests: [Self.request("a"), Self.request("b")], cursor: Self.cursor(3)), now: Self.now)

        #expect(output.lines == [
            "08:33:20  GET  https://shop.test/a",
            "  dump",
            "    a 1",
            "",
            "08:33:20  GET  https://shop.test/b",
            "  dump",
            "    b 1",
            "",
            "08:33:20  GET  https://shop.test/a",
            "  dump",
            "    a 2",
        ])
    }

    @Test func jsonGivesOneLineForEachDumpAndAShortErrorForADumpThatDoesNotEncode() {
        let output = Output()
        var printer = printer(json: true, into: output)
        var broken = Self.request("broken")
        broken.duration = .nan

        printer.show([Self.dump(1, of: "page"), Self.dump(2, of: "page")], of: Self.request("page"), now: Self.now)
        printer.show([Self.dump(1, of: "broken")], of: broken, now: Self.now)
        printer.show([Self.dump(3, of: "page")], of: Self.request("page"), now: Self.now)

        #expect(output.lines.count == 3)
        #expect(output.lines.allSatisfy { $0.hasPrefix("{\"dump\":{") && !$0.contains("\n") })
        #expect(output.errors == ["Nexus cannot write the entry broken-1 as JSON."])
    }

    @Test func theFollowerStartsAtTheCursorOfTheList() {
        var follower = DumpFollower(place: Self.shop)

        #expect(follower.cursor == nil)
        #expect(follower.startsAgain(at: Self.cursor(7)))
        #expect(!follower.reads(after: DumpChange(changed: [Self.request("r1")])))

        follower.begin(at: Self.cursor(7))
        #expect(follower.cursor == Self.cursor(7))
        #expect(!follower.startsAgain(at: Self.cursor(1007)))
        #expect(follower.startsAgain(at: Self.cursor(0, epoch: "new")))

        follower.move(to: DumpBatch(dumps: [], requests: [], cursor: Self.cursor(9)))
        #expect(follower.cursor == Self.cursor(9))
    }

    @Test func onlyAChangedHeaderOfThePlaceIsRead() {
        let follower = follower(DumpPlace(site: "shop.test", workspace: "fix"))

        #expect(follower.reads(after: DumpChange(changed: [Self.request("fix", workspace: "fix")])))
        #expect(!follower.reads(after: DumpChange(changed: [Self.request("main")])))
        #expect(!follower.reads(after: DumpChange(removed: ["fix"], cleared: true)))
    }

    private final class FakeNexusd {
        var epoch = DumpsCommandTests.epoch
        var dumps: [(number: Int, dump: CaughtDump)] = []
        var headers: [String: DumpedRequest] = [:]
        var reads: [String] = []
        var failures = 0
        let output = Output()

        var cursor: DumpCursor {
            DumpCursor(epoch: epoch, number: dumps.map(\.number).max() ?? 0)
        }

        func batch(_ numbered: [(number: Int, dump: CaughtDump)]) -> DumpBatch {
            let ids = numbered.map(\.dump.requestID).reduce(into: [String]()) { ids, id in
                if !ids.contains(id) {
                    ids.append(id)
                }
            }

            return DumpBatch(dumps: numbered.map(\.dump), requests: ids.compactMap { headers[$0] }, cursor: cursor)
        }

        func latest(place: DumpPlace?, limit: Int, through listCursor: DumpCursor?) -> DumpBatch {
            let through = listCursor ?? cursor
            reads.append("latest \(limit) through \(through.number)")

            guard through.epoch == epoch else {
                return batch([])
            }

            return batch(Array(dumps.filter { $0.number <= through.number && place.includes(headers[$0.dump.requestID]?.place ?? DumpPlace()) }.suffix(limit)))
        }

        func newDumps(place: DumpPlace?, after: DumpCursor) throws -> DumpBatch {
            reads.append("new after \(after.number)")

            if failures > 0 {
                failures -= 1
                throw ExitCode.failure
            }

            guard after.epoch == epoch else {
                return batch([])
            }

            return batch(dumps.filter { $0.number > after.number && place.includes(headers[$0.dump.requestID]?.place ?? DumpPlace()) })
        }

        func entries(of request: String, after number: Int) -> [CaughtDump] {
            reads.append("request \(request) after \(number)")
            return dumps.filter { $0.number > number && $0.dump.requestID == request }.map(\.dump)
        }
    }

    private func loop(_ nexusd: FakeNexusd, limit: Int = 10, json: Bool = false, place: DumpPlace? = nil) -> DumpFollowLoop {
        DumpFollowLoop(
            place: place,
            limit: limit,
            json: json,
            timeZone: Self.utc,
            readLatest: nexusd.latest(place:limit:through:),
            readNew: nexusd.newDumps(place:after:),
            readRequest: nexusd.entries(of:after:),
            write: nexusd.output.write,
            now: { Self.now }
        )
    }

    private func updates(_ updates: [NexusFeedUpdate]) -> AsyncStream<NexusFeedUpdate> {
        AsyncStream { continuation in
            updates.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    @Test func followShowsTheNewestDumpsAndThenEachDumpAfterTheCursorOnce() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page", lastSeq: 3), "worker": Self.request("worker", lastSeq: 2), "blog": Self.request("blog", site: "blog.test")]
        nexusd.dumps = [
            (1, Self.dump(1, of: "worker")),
            (2, Self.dump(2, of: "page")),
            (3, Self.dump(1, of: "blog")),
            (4, Self.dump(1, of: "page")),
            (5, Self.dump(2, of: "worker")),
            (6, Self.dump(3, of: "page")),
        ]
        let block = DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "/w/shop/.env", place: Self.shop)
        let notLoaded = Self.list([], cursor: nil)
        let first = Self.list([Self.request("blog", site: "blog.test"), Self.request("page", lastSeq: 2), Self.request("worker")], cursor: Self.cursor(3), blocked: [block])
        let later = Self.list([Self.request("page", lastSeq: 3), Self.request("worker", lastSeq: 2)], cursor: Self.cursor(1006), blocked: [block])
        var follow = loop(nexusd, limit: 1, place: Self.shop)

        try await follow.run(updates([
            .event(.dumpChanges(DumpChange(changed: [Self.request("page")]))),
            .event(.dumpList(notLoaded)),
            .event(.dumpList(first)),
            .event(.dumpChanges(DumpChange(changed: [Self.request("blog", site: "blog.test")]))),
            .event(.dumpChanges(DumpChange(changed: [Self.request("page", lastSeq: 3), Self.request("worker", lastSeq: 2)]))),
            .unreachable("nexusd stopped."),
            .unreachable("nexusd stopped."),
            .event(.dumpList(later)),
        ]))

        #expect(nexusd.output.lines == [
            "Warning: \(block.title). \(block.message)",
            "",
            "08:33:20  GET  https://shop.test/page",
            "  dump",
            "    page 2",
            "",
            DumpFollowLoop.waitText,
            "",
            "08:33:20  GET  https://shop.test/page",
            "  dump",
            "    page 1",
            "",
            "08:33:20  GET  https://shop.test/worker",
            "  dump",
            "    worker 2",
            "",
            "08:33:20  GET  https://shop.test/page",
            "  dump",
            "    page 3",
        ])
        #expect(nexusd.output.errors == ["nexusd stopped. The command waits until nexusd answers again."])
        #expect(nexusd.reads == ["latest 1 through 3", "new after 3", "new after 6"])
    }

    @Test func aRestartOfNexusdWithItsFileGoesOnAfterTheCursor() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page")]
        nexusd.dumps = [(1, Self.dump(1, of: "page")), (2, Self.dump(2, of: "page"))]
        var follow = loop(nexusd, limit: 0)

        try await follow.run(updates([
            .event(.dumpList(Self.list([Self.request("page")], cursor: Self.cursor(1)))),
            .unreachable("nexusd stopped."),
            .event(.dumpList(Self.list([], cursor: nil))),
            .event(.dumpList(Self.list([Self.request("page", lastSeq: 2)], cursor: Self.cursor(1002)))),
        ]))

        #expect(nexusd.reads == ["new after 1"])
        #expect(nexusd.output.lines.suffix(3) == ["08:33:20  GET  https://shop.test/page", "  dump", "    page 2"])
    }

    @Test func aListOfAnotherEpochStartsAgainWithTheNewestDumps() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["old": Self.request("old"), "new": Self.request("new")]
        nexusd.dumps = [(1, Self.dump(1, of: "old"))]
        var follow = loop(nexusd, limit: 1)
        let first = Self.list([Self.request("old")], cursor: Self.cursor(1))

        nexusd.epoch = "a1b2c3d4"
        nexusd.dumps = [(1, Self.dump(1, of: "new"))]
        let afterAStartWithoutTheFile = Self.list([Self.request("new")], cursor: Self.cursor(1, epoch: "a1b2c3d4"))

        try await follow.run(updates([.event(.dumpList(first)), .event(.dumpList(afterAStartWithoutTheFile))]))

        #expect(nexusd.reads == ["latest 1 through 1", "latest 1 through 1"])
        #expect(nexusd.output.lines.contains(DumpFollowLoop.againText))
        #expect(nexusd.output.lines.last == "    new 1")
        #expect(nexusd.output.lines.filter { $0 == DumpFollowLoop.waitText }.count == 1)
    }

    @Test func aReadOfAnotherEpochAfterAClearStartsAgainAtTheCursorOfTheAnswer() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page"), "after": Self.request("after")]
        nexusd.dumps = [(1, Self.dump(1, of: "page"))]
        var follow = loop(nexusd, limit: 5)
        let first = Self.list([Self.request("page")], cursor: Self.cursor(1))

        nexusd.epoch = "c1e4a2ed"
        nexusd.dumps = [(2, Self.dump(1, of: "after"))]
        let change = DumpChange(changed: [Self.request("after")], cleared: true)

        try await follow.run(updates([.event(.dumpList(first)), .event(.dumpChanges(change)), .event(.dumpChanges(change))]))

        #expect(nexusd.reads == ["latest 5 through 1", "new after 1", "latest 5 through 2", "new after 2"])
        #expect(nexusd.output.lines.contains(DumpFollowLoop.againText))
        #expect(nexusd.output.lines.filter { $0 == "    after 1" }.count == 1)
    }

    @Test func followWithALimitShowsOnlyTheNewestDumpsOfALoop() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["worker": Self.request("worker", lastSeq: 5)]
        nexusd.dumps = (1...5).map { seq in (seq, Self.dump(seq, of: "worker")) }
        var follow = loop(nexusd, limit: 2)

        try await follow.run(updates([.event(.dumpList(Self.list([Self.request("worker", lastSeq: 5)], cursor: Self.cursor(5))))]))

        #expect(nexusd.output.lines.filter { $0.hasPrefix("    worker") } == ["    worker 4", "    worker 5"])
    }

    @Test func followReadsTheWholeRequestForTheTagsOfNewQueries() async throws {
        let nexusd = FakeNexusd()
        var page = Self.request("page")
        page.queryCount = 6
        nexusd.headers = ["page": page]
        nexusd.dumps = Self.productQueries(1...6, of: "page").enumerated().map { index, query in (index + 1, query) }
        var follow = loop(nexusd, limit: 0)

        try await follow.run(updates([.event(.dumpList(Self.list([page], cursor: Self.cursor(3)))), .event(.dumpChanges(DumpChange(changed: [page])))]))

        #expect(nexusd.reads == ["new after 3", "request page after 0"])
        #expect(nexusd.output.lines.filter { $0.hasPrefix("  query") }.count == 3)
        #expect(nexusd.output.lines.filter { $0.contains("  N+1 · 6×  ") }.count == 3)
    }

    @Test func aDumpWithALowerSeqAfterTheListShowsOnce() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page", lastSeq: 2)]
        nexusd.dumps = [(1, Self.dump(2, of: "page")), (2, Self.dump(1, of: "page"))]
        var follow = loop(nexusd)
        let change = DumpChange(changed: [Self.request("page", lastSeq: 2)])

        try await follow.run(updates([.event(.dumpList(Self.list([Self.request("page", lastSeq: 2)], cursor: Self.cursor(1)))), .event(.dumpChanges(change))]))

        #expect(nexusd.output.lines.filter { $0.hasPrefix("    page") } == ["    page 2", "    page 1"])
    }

    @Test func aFailedReadKeepsTheCursorForTheNextEvent() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page")]
        nexusd.dumps = [(1, Self.dump(1, of: "page"))]
        nexusd.failures = 1
        var follow = loop(nexusd, limit: 0)
        let change = DumpChange(changed: [Self.request("page")])

        try await follow.run(updates([.event(.dumpList(Self.list([]))), .event(.dumpChanges(change)), .event(.dumpChanges(change))]))

        #expect(nexusd.reads == ["new after 0", "new after 0"])
        #expect(nexusd.output.lines.contains("    page 1"))
    }

    @Test func anUnreadableEventShowsItsTextOnceUntilAReadableEventOrANewConnection() async throws {
        let nexusd = FakeNexusd()
        var follow = loop(nexusd)

        try await follow.run(updates([
            .event(.dumpList(Self.list([]))),
            .unreadable("other version"),
            .unreadable("other version"),
            .event(.dumpChanges(DumpChange())),
            .unreadable("other version"),
            .unreachable("nexusd stopped."),
            .unreadable("other version"),
        ]))

        #expect(nexusd.output.errors.filter { $0 == "other version" }.count == 3)
    }

    @Test func followWithoutNexusdEndsWithTheReason() async {
        let nexusd = FakeNexusd()
        var follow = loop(nexusd)

        await #expect(throws: ExitCode.failure) {
            try await follow.run(updates([.unreachable("Nexus cannot connect to nexusd.")]))
        }
        #expect(nexusd.output.errors == [ErrorText.plain(NexusClientError.daemonNotRunning("Nexus cannot connect to nexusd."))])
        #expect(nexusd.output.lines.isEmpty)
    }

    @Test func followWithJSONWritesOnlyTheDumpsToTheOutput() async throws {
        let nexusd = FakeNexusd()
        nexusd.headers = ["page": Self.request("page")]
        nexusd.dumps = [(1, Self.dump(1, of: "page"))]
        let list = Self.list([Self.request("page")], cursor: Self.cursor(1), settings: DumpSettings(catchDumps: false, pageMode: .automatic, commands: true))
        var follow = loop(nexusd, json: true)

        try await follow.run(updates([.event(.dumpList(list))]))

        #expect(nexusd.output.lines.count == 1)
        #expect(nexusd.output.lines[0].hasPrefix("{\"dump\":{"))
        #expect(nexusd.output.errors == [
            "Catch dumps is off. So Nexus catches no new dumps. Turn it on with: nexus dumps settings --catch-dumps on",
            DumpFollowLoop.waitText,
        ])
    }
}
