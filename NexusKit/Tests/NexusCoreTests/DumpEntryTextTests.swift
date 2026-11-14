import Foundation
import NexusCore
import Testing

struct DumpEntryTextTests {
    private static let started = Date(timeIntervalSince1970: 1_800_000_000)
    private static let english = Locale(identifier: "en_US_POSIX")
    private static let controller = "/Users/tim/Sites/shop/app/Http/Controllers/CheckoutController.php"

    private func request(kind: DumpedRequest.Kind = .http, status: Int? = 200, exitCode: Int? = nil, duration: TimeInterval? = 0.184, dumps: Int = 0, queries: Int = 0, logs: Int = 0, jobs: Int = 0, job: JobRun? = nil) -> DumpedRequest {
        DumpedRequest(id: "a1", kind: kind, method: kind == .http ? "GET" : nil, target: job?.name ?? "/checkout", started: Self.started, status: status, exitCode: exitCode, duration: duration, dumpCount: dumps, queryCount: queries, logCount: logs, jobCount: jobs, job: job)
    }

    private func job(_ system: JobRun.System = .laravel, outcome: JobRun.Outcome? = .done, attempt: Int? = 1, maxTries: Int? = 3) -> JobRun {
        JobRun(system: system, name: "App\\Jobs\\SendOrderMail", queue: "default", connection: "redis", uuid: "9f1c0f6e", attempt: attempt, maxTries: maxTries, outcome: outcome)
    }

    private func query(_ seq: Int, _ text: String, pattern: String? = nil, milliseconds: Double = 1, line: Int = 38) -> CaughtDump {
        CaughtDump(requestID: "a1", seq: seq, time: Self.started, kind: .query, file: Self.controller, line: line, label: "mysql", text: text, milliseconds: milliseconds, pattern: pattern)
    }

    @Test func theSummaryShowsAtMostTwoCountsThatAreNotZeroAndThenTheResult() {
        #expect(DumpEntryText.summary(of: request(dumps: 3, queries: 24, logs: 2, jobs: 2), locale: Self.english) == "3 dumps · 24 queries · 200 · 184 ms")
        #expect(DumpEntryText.summary(of: request(dumps: 1, logs: 1), locale: Self.english) == "1 dump · 1 log line · 200 · 184 ms")
        #expect(DumpEntryText.summary(of: request(queries: 1, logs: 2), locale: Self.english) == "1 query · 2 log lines · 200 · 184 ms")
        #expect(DumpEntryText.summary(of: request(queries: 12, jobs: 2), locale: Self.english) == "12 queries · 200 · 184 ms")
        #expect(DumpEntryText.summary(of: request(kind: .command, status: nil, exitCode: 0, duration: 3.2, dumps: 4), locale: Self.english) == "4 dumps · exit 0 · 3.2 s")
        #expect(DumpEntryText.summary(of: request(status: nil, duration: nil, dumps: 2), locale: Self.english) == "2 dumps")
    }

    @Test func theSummaryOfAJobStartsWithItsOutcome() {
        let done = request(kind: .job, status: nil, duration: 0.22, queries: 4, logs: 1, job: job())
        let failed = request(kind: .job, status: nil, duration: 1.4, logs: 1, job: job(outcome: .failed, attempt: 3))
        let failedCron = request(kind: .job, status: nil, duration: 0.041, queries: 3, job: job(.cron, outcome: .failed, attempt: nil, maxTries: nil))
        let running = request(kind: .job, status: nil, duration: nil, dumps: 1, job: job(outcome: nil))

        #expect(DumpEntryText.summary(of: done, locale: Self.english) == "done · 4 queries · 1 log line · 220 ms")
        #expect(DumpEntryText.summary(of: failed, locale: Self.english) == "try 3 of 3 · 1 log line · 1.4 s")
        #expect(DumpEntryText.summary(of: failedCron, locale: Self.english) == "3 queries · 41 ms")
        #expect(DumpEntryText.summary(of: running, locale: Self.english) == "1 dump")
    }

    @Test func theMethodOfAJobNamesItsSystem() {
        #expect(DumpEntryText.method(of: request(kind: .job, job: job(.laravel))) == "JOB")
        #expect(DumpEntryText.method(of: request(kind: .job, job: job(.cron))) == "CRON")
        #expect(DumpEntryText.method(of: request(kind: .job, job: job(.action))) == "ACTION")
        #expect(DumpEntryText.method(of: request()) == "GET")
        #expect(DumpEntryText.method(of: request(kind: .command)) == "CLI")
    }

    @Test func theHeadOfAJobGivesItsQueueAndItsStatus() {
        let done = request(kind: .job, status: nil, duration: 0.22, job: job())
        let failed = request(kind: .job, status: nil, duration: 1.4, job: job(outcome: .failed, attempt: 3))
        let failedWithoutTries = request(kind: .job, status: nil, duration: 1.4, job: job(outcome: .failed, attempt: nil, maxTries: nil))
        let released = request(kind: .job, status: nil, duration: nil, job: job(outcome: .released))
        let running = request(kind: .job, status: nil, duration: nil, job: job(outcome: nil))

        #expect(DumpEntryText.queue(of: job()) == "default · redis")
        #expect(DumpEntryText.queue(of: JobRun(system: .cron, name: "wp_scheduled_delete")) == nil)
        #expect(DumpEntryText.jobStatus(of: done, locale: Self.english) == "Done · 220 ms")
        #expect(DumpEntryText.jobStatus(of: failed, locale: Self.english) == "Failed on try 3 of 3 · 1.4 s")
        #expect(DumpEntryText.jobStatus(of: failedWithoutTries, locale: Self.english) == "Failed · 1.4 s")
        #expect(DumpEntryText.jobStatus(of: released, locale: Self.english) == "Released")
        #expect(DumpEntryText.jobStatus(of: running, locale: Self.english) == nil)
    }

    @Test func aJobRowLinksToItsRunAndAJobToItsRequest() {
        let done = request(kind: .job, status: nil, job: job())
        let running = request(kind: .job, status: nil, job: job(outcome: nil))

        #expect(DumpEntryText.run(of: done, time: "14:32:10") == "Ran at 14:32:10 · done")
        #expect(DumpEntryText.run(of: running, time: "14:32:10") == "Ran at 14:32:10")
        #expect(DumpEntryText.origin(request(), time: "14:32:08") == "GET /checkout at 14:32:08")
    }

    @Test(arguments: [
        (0.84, "0.84 ms"),
        (0.8, "0.8 ms"),
        (9.6, "9.6 ms"),
        (12, "12 ms"),
        (38.44, "38.4 ms"),
        (142.3, "142 ms"),
        (999.6, "1.0 s"),
        (1400, "1.4 s"),
    ])
    func aTimeInMillisecondsGetsMoreDigitsWhenItIsShort(milliseconds: Double, text: String) {
        #expect(DumpEntryText.milliseconds(milliseconds, locale: Self.english) == text)
    }

    @Test func theTextsOfTheQueriesTab() {
        var checkout = request(queries: 24)
        checkout.queryMilliseconds = 38.4

        #expect(DumpEntryText.queryTotal(of: checkout, locale: Self.english) == "38.4 ms in total")
        #expect(DumpEntryText.groupTag(.nPlusOne, count: 12) == "N+1 · 12×")
        #expect(DumpEntryText.groupTag(.duplicate, count: 2) == "duplicate · 2×")
        #expect(DumpEntryText.groupTag(.single, count: 1) == nil)
        #expect(DumpEntryText.nPlusOneNote(count: 12, isLaravel: false) == "This line runs the same query 12 times with other values. One query for all values is faster.")
        #expect(DumpEntryText.nPlusOneNote(count: 12, isLaravel: true) == "This line runs the same query 12 times with other values. One query for all values is faster. In Laravel, load the relation with with().")
        #expect(DumpEntryText.droppedQueries(1204) == "Nexus did not keep 1204 more queries.")
        #expect(DumpEntryText.droppedQueries(1) == "Nexus did not keep 1 more query.")
    }

    @Test func theTabsAreTheKindsOfTheRequestAndNoneForOnlyDumps() {
        let all = request(dumps: 3, queries: 24, logs: 1, jobs: 2)

        #expect(DumpEntryTab.tabs(of: all) == [.dumps, .queries, .logs, .jobs])
        #expect(DumpEntryTab.tabs(of: all).map { tab in tab.title(in: all) } == ["Dumps (3)", "Queries (24)", "Log lines (1)", "Jobs (2)"])
        #expect(DumpEntryTab.tabs(of: request(dumps: 3)).isEmpty)
        #expect(DumpEntryTab.tabs(of: request(queries: 5)) == [.queries])
        #expect(DumpEntryTab(.dd) == .dumps)
        #expect(DumpEntryTab(.log) == .logs)
    }

    @Test func theToneOfATagFollowsTheLevelOrTheStateOfTheJob() {
        func log(_ level: String, detail: String? = nil) -> CaughtDump {
            CaughtDump(requestID: "a1", seq: 1, time: Self.started, kind: .log, label: level, text: "x", detail: detail)
        }

        func row(_ state: String) -> CaughtDump {
            CaughtDump(requestID: "a1", seq: 1, time: Self.started, kind: .job, label: state, text: "App\\Jobs\\SendOrderMail")
        }

        #expect(DumpEntryText.tone(of: log("critical")) == .error)
        #expect(DumpEntryText.tone(of: log("error")) == .error)
        #expect(DumpEntryText.tone(of: log("warning")) == .warning)
        #expect(DumpEntryText.tone(of: log("deprecated", detail: "PHP deprecated")) == .neutral)
        #expect(DumpEntryText.tone(of: log("notice")) == .neutral)
        #expect(DumpEntryText.tone(of: row("queued")) == .accent)
        #expect(DumpEntryText.tone(of: row("sync")) == .neutral)
        #expect(DumpEntryText.tone(of: row("scheduled")) == .neutral)
    }

    @Test func aTreeBecomesTheTextOfCliDumper() {
        let tree = DumpNode(kind: .array, count: 3, children: [
            DumpNode(kind: .int, key: "order_id", value: "1042"),
            DumpNode(kind: .object, key: "exception", className: "App\\Exceptions\\InvoiceMissing", ref: 412, count: 2, children: [
                DumpNode(kind: .string, key: "message", access: .protected, value: "Order 1042 has no invoice."),
                DumpNode(kind: .array, key: "trace", access: .private, count: 24, cut: 24),
            ]),
            DumpNode(kind: .array, key: "0", index: true, count: 0),
        ])

        #expect(DumpEntryText.text(of: tree) == """
            array:3 [
              "order_id" => 1042
              "exception" => App\\Exceptions\\InvoiceMissing {#412
                #message: "Order 1042 has no invoice."
                -trace: array:24 [ …24]
              }
              0 => []
            ]
            """)
    }

    @Test func aCutStringAndAnObjectThatTheTreeShowsAlready() {
        let tree = DumpNode(kind: .object, className: "App\\Models\\Order", ref: 2210, count: 2, children: [
            DumpNode(kind: .string, key: "note", access: .public, value: "Leave the parcel", cut: 412),
            DumpNode(kind: .object, key: "self", access: .public, className: "App\\Models\\Order", ref: 2210, refersTo: 2210),
        ])

        #expect(DumpEntryText.text(of: tree) == """
            App\\Models\\Order {#2210
              +note: "Leave the parcel"…412
              +self: App\\Models\\Order {#2210}
            }
            """)
    }

    @Test func theCopyTextOfALogLineHasTheMessageAndTheContext() {
        let context = DumpNode(kind: .array, count: 1, children: [DumpNode(kind: .int, key: "order_id", value: "1042")])

        #expect(DumpEntryText.copyText(message: "Order 1042 has no invoice.", context: context) == "Order 1042 has no invoice.\narray:1 [\n  \"order_id\" => 1042\n]")
        #expect(DumpEntryText.copyText(message: "Done.", context: nil) == "Done.")
    }

    @Test func anNPlusOneAndADuplicateBecomeOneGroupAtThePlaceOfTheirFirstQuery() {
        let cart = query(1, "select * from `carts` where `user_id` = 7 limit 1", milliseconds: 0.84)
        let products = (2...13).map { seq in query(seq, "select * from `products` where `id` = \(seq) limit 1", pattern: "select * from `products` where `id` = ? limit 1", milliseconds: 0.8, line: 24) }
        let settings = [14, 15].map { seq in query(seq, "select * from `settings` where `key` = 'currency' limit 1", milliseconds: 0.55, line: 31) }
        let slow = query(16, "select count(*) as aggregate from `orders`", milliseconds: 142, line: 51)
        let all = [cart, products[0], settings[0]] + products.dropFirst() + [settings[1], slow]

        let rows = QueryRow.rows(of: all, marks: QueryMarks(all)) { entry in entry }

        #expect(rows.map(\.kind) == [.single, .nPlusOne, .duplicate, .single])
        #expect(rows.map(\.entries.count) == [1, 12, 2, 1])
        #expect(rows[1].entries.map(\.seq) == Array(2...13))
        #expect(abs(rows[1].milliseconds - 9.6) < 0.0001)
        #expect(rows[2].milliseconds == 1.1)
        #expect(rows[3].entries.first?.seq == 16)
    }

    @Test func aDuplicateWhoseCopyIsInAnNPlusOneStaysASingleRow() {
        let loop = (1...5).map { seq in query(seq, "select * from `users` where `id` = \(seq == 5 ? 1 : seq)", pattern: "select * from `users` where `id` = ?", line: 24) }
        let elsewhere = query(6, "select * from `users` where `id` = 1", pattern: "select * from `users` where `id` = ?", line: 90)
        let log = CaughtDump(requestID: "a1", seq: 7, time: Self.started, kind: .log, label: "info", text: "x")
        let all = loop + [elsewhere, log]

        let rows = QueryRow.rows(of: all, marks: QueryMarks(all)) { entry in entry }

        #expect(rows.map(\.kind) == [.nPlusOne, .single])
        #expect(rows[0].entries.count == 5)
        #expect(rows[1].entries.first?.seq == 6)
    }
}
