import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct DumpListTests {
    private static let started = Date(timeIntervalSince1970: 1_762_850_000)

    private static let list = DumpList(
        requests: [
            DumpedRequest(id: "65f1c2a9e3b1", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", host: "shop.test", site: "shop.test", started: started, status: 200, duration: 0.184, dumpCount: 3, hasDD: true),
            DumpedRequest(id: "a1b2c3", kind: .command, target: "php artisan import:products", site: "shop.test", started: started, exitCode: 0, duration: 3.2, dumpCount: 4),
        ],
        settings: DumpSettings(catchDumps: true, pageMode: .always, commands: false),
        blocked: [DumpBlock(host: "blog.test", reason: .userIni, file: "/Users/x/Sites/blog/.user.ini")],
        receiving: true,
        problem: "nexusd cannot open its dump socket.",
        cursor: cursor
    )

    private static let cursor = DumpCursor(epoch: "4f1c9a0e", number: 12)

    @Test func theDumpCountIsTheSumOfTheRequests() {
        #expect(Self.list.dumpCount == 7)
        #expect(DumpList(requests: [], settings: DumpSettings(), receiving: false).dumpCount == 0)
    }

    @Test func aListGoesThroughTheCoding() throws {
        let decoded = try NexusMessageCoding.decode(DumpList.self, from: NexusMessageCoding.encode(Self.list))

        #expect(decoded == Self.list)
        #expect(decoded.cursor == Self.cursor)
    }

    @Test func aListWithNoDefaultValueKeepsEachField() throws {
        let list = DumpList(
            requests: Self.list.requests,
            settings: DumpSettings(catchDumps: false, pageMode: .never, commands: false),
            blocked: Self.list.blocked,
            receiving: true,
            problem: "A problem.",
            cursor: Self.cursor,
            loaded: false
        )

        #expect(try roundTrip(list) == list)
    }

    @Test func theStateOfAListIsTheListWithoutItsRequests() {
        #expect(Self.list.state == DumpState(settings: Self.list.settings, blocked: Self.list.blocked, receiving: true, problem: "nexusd cannot open its dump socket.", loaded: true))
    }

    @Test func aListOfAnOlderNexusdIsLoadedAndHasNoCursor() throws {
        let json = #"{"requests":[],"settings":{},"blocked":[],"receiving":true}"#

        let list = try NexusMessageCoding.decode(DumpList.self, from: Data(json.utf8))

        #expect(list.loaded)
        #expect(list.cursor == nil)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try NexusMessageCoding.decode(Value.self, from: NexusMessageCoding.encode(value))
    }

    @Test func theRequestsOfTheDumpViewerGoThroughTheCoding() throws {
        let requests: [NexusRequest] = [
            .dumpList(place: nil),
            .dumpList(place: DumpPlace()),
            .dumpList(place: DumpPlace(site: "shop.test", workspace: "fix")),
            .clearCaughtDumps(place: nil),
            .clearCaughtDumps(place: DumpPlace(site: "shop.test")),
            .removeCaughtDump(number: 12),
            .removeDumpedRequest(id: "65f1c2a9e3b1"),
            .openCaughtDumpFile(number: 12),
            .setDumpSettings(DumpSettings(catchDumps: false, pageMode: .never, commands: false)),
            .newDumps(place: nil, after: Self.cursor),
            .newDumps(place: DumpPlace(site: "shop.test", workspace: "fix"), after: Self.cursor),
            .lastDumps(place: DumpPlace(site: "shop.test"), limit: 20, through: Self.cursor),
            .lastDumps(place: nil, limit: 5, through: nil),
            .dumpPlace(host: "fix.shop.test"),
            .dumpState(place: nil),
            .dumpState(place: DumpPlace(site: "shop.test", workspace: "fix")),
            .requestDumps(request: "65f1c2a9e3b1", afterNumber: 12),
            .requestEntries(request: "65f1c2a9e3b1", afterNumber: 12, kinds: [.query, .log]),
            .fromAgent(agent: "Claude Code", request: .dumpList(place: DumpPlace(site: "shop.test"))),
        ]

        for request in requests {
            #expect(try roundTrip(request) == request)
        }

        #expect(NexusRequest.dumpList(place: nil).onlyReads)
        #expect(NexusRequest.newDumps(place: nil, after: Self.cursor).onlyReads)
        #expect(NexusRequest.lastDumps(place: nil, limit: 20, through: nil).onlyReads)
        #expect(NexusRequest.dumpPlace(host: "shop.test").onlyReads)
        #expect(NexusRequest.dumpState(place: nil).onlyReads)
        #expect(NexusRequest.requestDumps(request: "65f1c2a9e3b1", afterNumber: 0).onlyReads)
        #expect(NexusRequest.requestEntries(request: "65f1c2a9e3b1", afterNumber: 0, kinds: [.query]).onlyReads)
        #expect(!NexusRequest.clearCaughtDumps(place: nil).onlyReads)
        #expect(!NexusRequest.removeCaughtDump(number: 12).onlyReads)
        #expect(!NexusRequest.removeDumpedRequest(id: "65f1c2a9e3b1").onlyReads)
        #expect(!NexusRequest.openCaughtDumpFile(number: 12).onlyReads)
        #expect(!NexusRequest.setDumpSettings(DumpSettings()).onlyReads)
    }

    @Test func theResponsesOfTheDumpViewerGoThroughTheCoding() throws {
        let dump = CaughtDump(requestID: "65f1c2a9e3b1", seq: 2, time: Self.started, kind: .dd, file: "/Users/x/Sites/shop/app/Http/Controllers/CheckoutController.php", line: 42, label: "cart", text: "array:1 [\n  \"id\" => 7\n]", treeJSON: #"{"kind":"array","count":1,"children":[{"key":"id","kind":"int","value":"7"}]}"#)
        let responses: [NexusResponse] = [
            .dumpList(Self.list),
            .caughtDumps([dump]),
            .caughtDumps([]),
            .dumpBatch(DumpBatch(dumps: [dump], requests: [Self.list.requests[0]], cursor: Self.cursor)),
            .dumpBatch(DumpBatch(dumps: [dump], requests: [Self.list.requests[0]], cursor: Self.cursor, olderCounts: ["65f1c2a9e3b1": 480])),
            .dumpPlace(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "fix.shop.test"),
            .dumpState(DumpState(settings: DumpSettings(catchDumps: false, pageMode: .never, commands: false), blocked: Self.list.blocked, receiving: true, problem: "A problem.", loaded: false)),
        ]

        for response in responses {
            #expect(try roundTrip(response) == response)
        }
    }

    @Test func theEventsOfTheDumpViewerGoThroughTheCoding() throws {
        let change = DumpChange(changed: [Self.list.requests[0]], removed: ["a1b2c3", "unknown"], cleared: true, removedDumps: [12])
        let events: [NexusEvent] = [.dumpList(Self.list), .dumpChanges(change), .dumpChanges(DumpChange())]

        for event in events {
            #expect(try roundTrip(event) == event)
        }
    }

    @Test func aChangeHoldsOnlyTheHeadersOfTheRequests() throws {
        let change = DumpChange(changed: Self.list.requests)

        let object = try JSONSerialization.jsonObject(with: NexusMessageCoding.encode(NexusEvent.dumpChanges(change))) as? [String: Any]
        let inner = (object?["dumpChanges"] as? [String: Any])?["_0"] as? [String: Any]
        let first = (inner?["changed"] as? [[String: Any]])?.first

        #expect(Set(inner?.keys.map { $0 } ?? []) == ["changed", "removed", "cleared", "removedDumps"])
        #expect(first?["dumpCount"] as? Int == 3)
        #expect(first?["text"] == nil)
        #expect(first?["tree"] == nil)
    }

    @Test func aChangeOfAnOlderNexusdHasNoRemovedDumps() throws {
        let json = #"{"changed":[],"removed":["a1"],"cleared":false}"#

        let change = try NexusMessageCoding.decode(DumpChange.self, from: Data(json.utf8))

        #expect(change == DumpChange(removed: ["a1"]))
    }
}
