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

    @Test func theNotesShowCatchDumpsTheProblemAndTheBlocksOfTheSite() {
        let list = DumpList(
            requests: [],
            settings: DumpSettings(catchDumps: false, pageMode: .automatic, commands: true),
            blocked: [
                DumpBlock(host: "blog.test", reason: .userIni, file: "/w/blog/.user.ini", place: DumpPlace(site: "blog.test")),
                DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "/w/shop/.env", place: DumpPlace(site: "shop.test")),
                DumpBlock(host: "fix.shop.test", reason: .varDumperFormat, place: DumpPlace(site: "shop.test", workspace: "fix")),
            ],
            receiving: true,
            problem: "Nexus catches no dumps, because nexusd cannot listen on its socket.\nThe second line."
        )

        #expect(DumpText.notes(of: list.state, place: DumpPlace(site: "shop.test")) == [
            "Catch dumps is off. So Nexus catches no new dumps. Turn it on with: nexus dumps settings --catch-dumps on",
            "Warning: Nexus catches no dumps, because nexusd cannot listen on its socket.",
            "Warning: The second line.",
            "Warning: Nexus catches no dumps of shop.test, because /w/shop/.env sets VAR_DUMPER_FORMAT. Remove that key to catch them.",
        ])
        #expect(DumpText.notes(of: list.state, place: DumpPlace(site: "shop.test", workspace: "fix")).last == "Warning: Nexus catches no dumps of fix.shop.test, because the environment of PHP sets VAR_DUMPER_FORMAT. Remove that key to catch them.")
        #expect(DumpText.notes(of: list.state, place: nil).contains("Warning: Nexus catches no dumps of blog.test, because /w/blog/.user.ini sets its own auto_prepend_file."))
        #expect(DumpText.notes(of: list.state, place: nil).count == 6)
    }

    @Test func aListThatCatchesHasNoNotes() {
        let list = DumpList(requests: [Self.request("r1")], settings: DumpSettings(), receiving: true)

        #expect(DumpText.notes(of: list.state, place: nil).isEmpty)
    }

    @Test func anEmptyListSaysSo() {
        #expect(DumpText.noDumps(of: nil) == "Nexus has no dumps.")
        #expect(DumpText.noDumps(of: "fix.shop.test") == "Nexus has no dumps of fix.shop.test.")
    }

    @Test func theSettingsShowOnEachLine() {
        #expect(DumpText.lines(of: DumpSettings(catchDumps: false, pageMode: .always, commands: true)) == [
            "Catch dumps  off",
            "Page         always (All requests)",
            "Commands     on",
        ])
    }
}
