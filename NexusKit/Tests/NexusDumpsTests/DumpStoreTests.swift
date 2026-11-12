import Foundation
import NexusCore
import Synchronization
import Testing
@testable import NexusDumps

final class SitePlaces: Sendable {
    private let locations = Mutex<[String: DumpLocation]>([:])
    private let calls = Mutex(0)

    func set(_ host: String, _ place: DumpPlace, projectFolder: String? = nil) {
        locations.withLock { current in current[host] = DumpLocation(place: place, host: host, projectFolder: projectFolder) }
    }

    func location(of request: DumpedRequest) -> DumpLocation {
        calls.withLock { count in count += 1 }
        return locations.withLock { current in current[request.host ?? ""] ?? DumpLocation() }
    }

    var callCount: Int {
        calls.withLock { count in count }
    }
}

@Suite(.timeLimit(.minutes(1)))
final class DumpStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus Dumps \(UUID().uuidString)", directoryHint: .isDirectory)
    private let started = Date(timeIntervalSince1970: 1_800_000_000)
    private let megabyte = String(repeating: "x", count: 1_000_000)
    private var stores: [DumpStore] = []

    deinit {
        for store in stores {
            store.waitForWrites()
        }

        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL {
        folder.appending(path: "logs/dumps.jsonl", directoryHint: .notDirectory)
    }

    private func store(places: SitePlaces? = nil) -> DumpStore {
        let store = DumpStore(file: file) { request in places?.location(of: request) ?? DumpLocation() }
        stores.append(store)
        return store
    }

    private func reloaded() -> DumpStore {
        for store in stores {
            store.waitForWrites()
        }

        let store = store()
        store.load()
        return store
    }

    private func envelope(_ id: String, host: String = "shop.test") -> DumpEnvelope {
        DumpEnvelope(id: id, kind: .http, method: "GET", url: "https://\(host)/orders/\(id)", host: host, root: "/Users/tim/Sites/\(host)/public", started: started, pid: 4512)
    }

    private func dump(_ id: String, seq: Int, kind: CaughtDump.Kind = .dump, text: String = "\"x\"", host: String = "shop.test") -> DumpEvent {
        .dump(request: envelope(id, host: host), dump: CaughtDump(requestID: id, seq: seq, time: started.addingTimeInterval(Double(seq)), kind: kind, text: text, treeJSON: #"{"kind":"string","value":"x"}"#))
    }

    private func end(_ id: String, status: Int?, host: String = "shop.test") -> DumpEvent {
        .end(request: envelope(id, host: host), status: status, exitCode: nil, duration: 0.25)
    }

    private func attributes() throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
    }

    private func fileSize() throws -> Int {
        try #require(attributes()[.size] as? Int)
    }

    private func allDumps(of store: DumpStore) -> [CaughtDump] {
        store.list().reversed().flatMap { request in store.dumps(request: request.id) }
    }

    @Test func theRealLinesOfPHPMakeTheListAndTheDumps() throws {
        let store = store()

        try WireLines.events(WireLines.all).forEach(store.add)

        let list = store.list()
        let page = try #require(list.first { request in request.id == "18cffb9d2606" })
        let pageDD = try #require(list.first { request in request.id == "cf20f53412b7" })
        let command = try #require(list.first { request in request.id == "cc870a6df341" })
        #expect(list.map(\.id) == ["cf20f53412b7", "18cffb9d2606", "cc870a6df341", "7fc34bcf0060"])
        #expect(page.target == "/index.php?action=twice")
        #expect(page.status == 200)
        #expect(page.duration == 0.006379)
        #expect(page.dumpCount == 3)
        #expect(!page.hasDD)
        #expect(pageDD.status == 500)
        #expect(pageDD.hasDD)
        #expect(command.exitCode == 1)
        #expect(command.hasDD)
        #expect(store.dumps(request: "18cffb9d2606").map(\.seq) == [1, 2, 3])
        #expect(store.dumps(request: "18cffb9d2606").first?.treeJSON == #"{"kind":"array","count":1,"children":[{"key":"order","kind":"int","value":"7"}]}"#)
    }

    @Test func theHeaderKeepsTheHostAndTheRoot() throws {
        let store = store()

        try WireLines.events([WireLines.pageDD]).forEach(store.add)

        #expect(store.list().first?.host == "127.0.0.1")
        #expect(store.list().first?.root == "/Users/tim/Sites/shop/public")
        #expect(reloaded().list().first?.root == "/Users/tim/Sites/shop/public")
    }

    @Test func aBlockedEventAddsNoRequest() throws {
        let store = store()

        try WireLines.events([WireLines.blocked]).forEach(store.add)

        #expect(store.list().isEmpty)
        #expect(store.takeChanges().isEmpty)
    }

    @Test func anEndBeforeItsDumpWaitsForTheDump() {
        let store = store()

        store.add(end("a1", status: 404))
        let beforeTheDump = store.list()
        store.add(dump("a1", seq: 1))

        #expect(beforeTheDump.isEmpty)
        #expect(store.list().map(\.status) == [404])
        #expect(store.list().map(\.dumpCount) == [1])
    }

    @Test func aDumpAfterItsEndJoinsTheRequest() {
        let store = store()

        store.add(dump("a1", seq: 1))
        store.add(end("a1", status: 200))
        store.add(dump("a1", seq: 2, kind: .dd))

        let request = store.list().first
        #expect(request?.status == 200)
        #expect(request?.dumpCount == 2)
        #expect(request?.hasDD == true)
        #expect(store.dumps(request: "a1").map(\.seq) == [1, 2])
    }

    @Test func aRequestWithoutAnEndShowsItsDumps() {
        let store = store()

        store.add(dump("a1", seq: 1))

        #expect(store.list().map(\.id) == ["a1"])
        #expect(store.list().first?.status == nil)
    }

    @Test func aDumpThatTheStoreHasIsNotAddedAgain() {
        let store = store()

        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 1))

        #expect(store.dumps(request: "a1").count == 1)
        #expect(store.list().first?.dumpCount == 1)
    }

    @Test func dumpsAfterANumberGivesOnlyTheNewerDumps() {
        let store = loadedStore()

        for seq in 1...4 {
            store.add(dump("a1", seq: seq))
        }

        #expect(store.dumps(request: "a1", afterNumber: 2).map(\.seq) == [3, 4])
        #expect(store.dumps(request: "a1", afterNumber: 4).isEmpty)
        #expect(store.dumps(request: "a1").map(\.seq) == [1, 2, 3, 4])
    }

    @Test func firstNumberIsTheLowestNumberThatTheStoreKeepsOfTheRequest() throws {
        let store = loadedStore()
        store.add(dump("old", seq: 1))
        store.add(dump("a1", seq: 2))
        store.add(dump("a1", seq: 1))
        let before = try #require(store.list().first { $0.id == "a1" })

        for seq in 3...DumpStore.dumpLimit {
            store.add(dump("a1", seq: seq))
        }

        let afterTheOldRequestWent = try #require(store.list().first)
        store.add(dump("a1", seq: DumpStore.dumpLimit + 1))
        let afterItsOwnDumpWent = try #require(store.list().first)

        #expect(before.firstNumber == 2)
        #expect(before.lastNumber == 3)
        #expect(afterTheOldRequestWent.id == "a1")
        #expect(afterTheOldRequestWent.firstNumber == 2)
        #expect(afterItsOwnDumpWent.firstNumber == 3)
        #expect(store.dumps(request: "a1").first?.number == 3)
        #expect(reloaded().list().first?.firstNumber == 3)
    }

    @Test func theStoreKeepsTheNewest1000Dumps() {
        let store = store()
        store.add(dump("old", seq: 1, kind: .dd))
        _ = store.takeChanges()

        for seq in 1...DumpStore.dumpLimit {
            store.add(dump("new", seq: seq))
        }

        let changes = store.takeChanges()
        #expect(store.list().map(\.id) == ["new"])
        #expect(store.list().first?.dumpCount == 1000)
        #expect(store.dumps(request: "old").isEmpty)
        #expect(changes.removed == ["old"])
        #expect(changes.changed.map(\.id) == ["new"])
    }

    @Test func aRequestLosesItsOldestDumpsFirst() {
        let store = store()

        for seq in 1...(DumpStore.dumpLimit + 2) {
            store.add(dump("a1", seq: seq))
        }

        #expect(store.dumps(request: "a1").first?.seq == 3)
        #expect(store.list().first?.dumpCount == 1000)
    }

    @Test func theStoreKeepsAtMost10MB() {
        let store = store()

        for seq in 1...11 {
            store.add(dump("a1", seq: seq, text: megabyte))
        }

        #expect(store.dumps(request: "a1").map(\.seq) == Array(2...11))
        #expect(store.list().first?.dumpCount == 10)
    }

    @Test func aReloadGivesTheSameStore() throws {
        let store = store()
        try WireLines.events(WireLines.all).forEach(store.add)
        store.add(end("waits", status: 200))

        let loaded = reloaded()

        #expect(loaded.list() == store.list())
        #expect(allDumps(of: loaded) == allDumps(of: store))
        #expect(loaded.takeChanges().isEmpty)
    }

    @Test func aReloadRemovesTheSameOldDumps() {
        let store = store()
        store.add(dump("old", seq: 1))
        store.add(end("old", status: 200))

        for seq in 1...(DumpStore.dumpLimit + 5) {
            store.add(dump("new", seq: seq))
        }

        let loaded = reloaded()

        #expect(loaded.list() == store.list())
        #expect(loaded.dumps(request: "new") == store.dumps(request: "new"))
        #expect(loaded.dumps(request: "new").first?.seq == 6)
    }

    @Test func aCutLastLineOfTheFileIsSkipped() throws {
        let store = store()
        try WireLines.events(WireLines.all).forEach(store.add)
        store.waitForWrites()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"dump":{"requestID":"18cf"#.utf8))
        try handle.close()

        let loaded = reloaded()
        loaded.add(dump("after", seq: 1))

        #expect(Array(loaded.list().dropFirst()) == store.list())
        #expect(reloaded().list() == loaded.list())
    }

    @Test func theFileIsOnlyForTheUser() throws {
        let store = store()
        store.add(dump("a1", seq: 1))
        store.waitForWrites()
        let afterAnAppend = try attributes()[.posixPermissions] as? Int

        store.add(dump("b1", seq: 1))
        store.clear(place: DumpPlace())
        store.waitForWrites()

        #expect(afterAnAppend == 0o600)
        #expect(try attributes()[.posixPermissions] as? Int == 0o600)
    }

    @Test func aClearOfASiteKeepsTheOtherSites() {
        let places = SitePlaces()
        places.set("shop.test", DumpPlace(site: "shop.test"))
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = store(places: places)
        store.add(dump("s1", seq: 1, host: "shop.test"))
        store.add(dump("s1", seq: 2, host: "shop.test"))
        store.add(dump("b1", seq: 1, host: "blog.test"))
        store.add(dump("s2", seq: 1, host: "shop.test"))
        _ = store.takeChanges()

        let removed = store.clear(place: DumpPlace(site: "shop.test"))

        let changes = store.takeChanges()
        #expect(removed == 3)
        #expect(store.list().map(\.id) == ["b1"])
        #expect(store.list(place: DumpPlace(site: "shop.test")).isEmpty)
        #expect(changes.removed == ["s1", "s2"])
        #expect(!changes.cleared)
        #expect(reloaded().list().map(\.id) == ["b1"])
    }

    @Test func listAndClearTellASiteFromItsWorkspace() {
        let places = SitePlaces()
        places.set("shop.test", DumpPlace(site: "shop.test"))
        places.set("fix.shop.test", DumpPlace(site: "shop.test", workspace: "fix"))
        let store = store(places: places)
        store.add(dump("s1", seq: 1, host: "shop.test"))
        store.add(dump("w1", seq: 1, host: "fix.shop.test"))
        store.add(dump("x1", seq: 1, host: "other.test"))

        let site = store.list(place: DumpPlace(site: "shop.test"))
        let workspace = store.list(place: DumpPlace(site: "shop.test", workspace: "fix"))
        let removed = store.clear(place: DumpPlace(site: "shop.test", workspace: "fix"))

        #expect(site.map(\.id) == ["s1"])
        #expect(workspace.map(\.id) == ["w1"])
        #expect(store.list(place: DumpPlace()).map(\.id) == ["x1"])
        #expect(removed == 1)
        #expect(store.list().map(\.id) == ["x1", "s1"])
    }

    @Test func aClearWithoutAPlaceRemovesEverything() throws {
        let store = store()
        try WireLines.events(WireLines.all).forEach(store.add)

        let removed = store.clear()

        store.waitForWrites()
        #expect(removed == 8)
        #expect(store.list().isEmpty)
        #expect(store.takeChanges() == DumpChange(cleared: true))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.hasPrefix("{\"epoch\":\""))
        #expect(content.hasSuffix(",\"number\":8}\n"))
        #expect(content.split(separator: "\n").count == 1)
        #expect(reloaded().list().isEmpty)
    }

    @Test func aReadAfterANumberGivesALowerSeqThatArrivesLater() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 3))
        let header = store.list().first
        let read = store.dumps(request: "a1", afterNumber: 0)
        store.add(dump("a1", seq: 2))

        let later = try #require(store.list().first)
        let new = store.dumps(request: "a1", afterNumber: header?.lastNumber ?? 0)
        let loaded = reloaded()

        #expect(read.map(\.seq) == [1, 3])
        #expect(read.map(\.number) == [1, 2])
        #expect(header?.lastNumber == 2)
        #expect(header?.lastSeq == 3)
        #expect(later.lastNumber == 3)
        #expect(later.lastSeq == 3)
        #expect(new.map(\.seq) == [2])
        #expect(new.map(\.number) == [3])
        #expect(loaded.dumps(request: "a1", afterNumber: 0).map(\.number) == [1, 2, 3])
        #expect(loaded.list().first?.lastNumber == 3)
    }

    @Test func theFileHoldsTheNumberOfADumpOnceOnItsLine() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        store.waitForWrites()

        let line = try #require(String(contentsOf: file, encoding: .utf8).split(separator: "\n").last)

        #expect(line.hasSuffix(",\"number\":1}"))
        #expect(line.components(separatedBy: "\"number\"").count == 2)
    }

    @Test func firstSeqIsTheLowestSeqThatTheStoreKeeps() {
        let store = store()
        store.add(dump("a1", seq: 3))
        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 2))
        let lowerSeqLater = store.list().first?.firstSeq

        for seq in 4...(DumpStore.dumpLimit + 1) {
            store.add(dump("a1", seq: seq))
        }

        let afterTheFirstArrivedWent = store.list().first?.firstSeq
        store.add(dump("a1", seq: DumpStore.dumpLimit + 2))

        #expect(lowerSeqLater == 1)
        #expect(afterTheFirstArrivedWent == 1)
        #expect(store.list().first?.firstSeq == 2)
        #expect(store.dumps(request: "a1").map(\.seq).min() == 2)
        #expect(reloaded().list().first?.firstSeq == 2)
    }

    @Test func locateGivesThePlaceItsFirstHostAndTheProjectFolderAndRelocateChangesThem() {
        let places = SitePlaces()
        places.set("shop.test", DumpPlace(site: "shop.test"), projectFolder: "/Users/tim/Sites/shop")
        let store = store(places: places)
        store.add(dump("a1", seq: 1))
        let first = store.list().first?.location
        _ = store.takeChanges()

        places.set("shop.test", DumpPlace(site: "shop.test", workspace: "fix"), projectFolder: "/Users/tim/Sites/shop-fix")
        store.relocate()

        let moved = DumpLocation(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "shop.test", projectFolder: "/Users/tim/Sites/shop-fix")
        #expect(first == DumpLocation(place: DumpPlace(site: "shop.test"), host: "shop.test", projectFolder: "/Users/tim/Sites/shop"))
        #expect(store.list().first?.location == moved)
        #expect(store.takeChanges().changed.map(\.location) == [moved])
        #expect(reloaded().list().first?.location == moved)
    }

    @Test func theChangesGiveTheListTheOrderOfTheStore() {
        let places = SitePlaces()
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = store(places: places)
        var mirror: [DumpedRequest] = []
        var rounds: [Bool] = []

        func takeTheChanges() {
            store.takeChanges().apply(to: &mirror)
            rounds.append(mirror == store.list())
        }

        store.add(dump("a", seq: 1))
        store.add(dump("b", seq: 1))
        takeTheChanges()

        store.add(dump("a", seq: 2))
        store.add(end("b", status: 200))
        store.add(dump("c", seq: 1, host: "blog.test"))
        takeTheChanges()

        store.clear(place: DumpPlace(site: "blog.test"))
        store.add(dump("d", seq: 1))
        takeTheChanges()

        for seq in 1...DumpStore.dumpLimit {
            store.add(dump("e", seq: seq))
        }

        store.add(dump("a", seq: 3))
        takeTheChanges()

        store.clear()
        store.add(dump("f", seq: 1))
        store.add(dump("g", seq: 1))
        takeTheChanges()

        #expect(rounds == [true, true, true, true, true])
        #expect(mirror.map(\.id) == ["g", "f"])
    }

    @Test func applyRemovesBeforeItAddsAndPutsANewRequestAtTheTop() {
        let old = DumpedRequest(id: "old", kind: .http, target: "/", started: started, dumpCount: 1)
        let kept = DumpedRequest(id: "kept", kind: .http, target: "/", started: started, dumpCount: 1)
        var ended = kept
        ended.status = 200
        let back = DumpedRequest(id: "old", kind: .http, target: "/", started: started, dumpCount: 1, lastSeq: 9)
        var requests = [kept, old]

        DumpChange(changed: [ended, back], removed: ["old", "unknown"]).apply(to: &requests)

        #expect(requests == [back, ended])
    }

    @Test func lastSeqIsTheNewestSeqAlsoWhenTheOldDumpsGo() {
        let store = store()

        for seq in 1...(DumpStore.dumpLimit + 2) {
            store.add(dump("a1", seq: seq))
        }

        store.add(end("a1", status: 200))

        #expect(store.dumps(request: "a1").first?.seq == 3)
        #expect(store.list().first?.lastSeq == 1002)
        #expect(reloaded().list().first?.lastSeq == 1002)
    }

    private func loadedStore(places: SitePlaces? = nil) -> DumpStore {
        let store = store(places: places)
        store.load()
        return store
    }

    private func cursor(of store: DumpStore) throws -> DumpCursor {
        try #require(store.listAndCursor().cursor)
    }

    @Test func aStoreBeforeItsLoadHasNoCursorAndGivesNoDumps() throws {
        let store = store()
        store.add(dump("a1", seq: 1))
        let anyCursor = DumpCursor(epoch: "old", number: 0)

        #expect(!store.isLoaded)
        #expect(store.listAndCursor().cursor == nil)
        #expect(store.newDumps(place: nil, after: anyCursor) == nil)
        #expect(store.lastDumps(place: nil, limit: 20) == nil)

        store.load()

        #expect(store.isLoaded)
        #expect(store.newDumps(place: nil, after: try cursor(of: store)) != nil)
    }

    @Test func newDumpsGivesTheDumpsOfAPlaceAfterTheCursor() throws {
        let places = SitePlaces()
        places.set("shop.test", DumpPlace(site: "shop.test"))
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = loadedStore(places: places)
        store.add(dump("a1", seq: 1))
        store.add(dump("b1", seq: 1, host: "blog.test"))
        store.add(dump("a1", seq: 2))

        let listed = store.listAndCursor()
        let listCursor = try #require(listed.cursor)
        store.add(dump("b1", seq: 2, host: "blog.test"))
        store.add(dump("a2", seq: 1))
        store.add(end("a2", status: 200))

        let ofShop = try #require(store.newDumps(place: DumpPlace(site: "shop.test"), after: listCursor))
        let ofAll = try #require(store.newDumps(place: nil, after: listCursor))
        let fromTheStart = try #require(store.newDumps(place: DumpPlace(site: "shop.test"), after: DumpCursor(epoch: listCursor.epoch, number: 0)))

        #expect(listCursor.number == 3)
        #expect(listed.requests.map(\.lastSeq) == [1, 2])
        #expect(ofShop.dumps.map(\.id) == ["a2-1"])
        #expect(ofShop.requests.map(\.id) == ["a2"])
        #expect(ofShop.requests.first?.status == 200)
        #expect(ofShop.cursor == DumpCursor(epoch: listCursor.epoch, number: 5))
        #expect(ofAll.dumps.map(\.id) == ["b1-2", "a2-1"])
        #expect(ofAll.requests.map(\.id) == ["b1", "a2"])
        #expect(fromTheStart.dumps.map(\.id) == ["a1-1", "a1-2", "a2-1"])
        #expect(fromTheStart.requests.map(\.id) == ["a1", "a2"])
        #expect(store.newDumps(place: nil, after: ofShop.cursor)?.dumps.isEmpty == true)
    }

    @Test func theNewestDumpsStopAtTheCursorOfTheListAndNewDumpsGivesTheRestOnce() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 2))
        store.add(dump("b1", seq: 1))
        let listed = store.listAndCursor()
        let listCursor = try #require(listed.cursor)
        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 3))

        let latest = try #require(store.lastDumps(place: nil, limit: 20, through: listCursor))
        let new = try #require(store.newDumps(place: nil, after: listCursor))

        #expect(latest.dumps.map(\.id) == ["a1-2", "b1-1"])
        #expect(latest.requests.map(\.id) == ["a1", "b1"])
        #expect(latest.requests.first?.lastSeq == 3)
        #expect(latest.cursor.number == 4)
        #expect(latest.olderCounts.isEmpty)
        #expect(new.dumps.map(\.id) == ["a1-1", "a1-3"])
        #expect(store.lastDumps(place: nil, limit: 1, through: listCursor)?.dumps.map(\.id) == ["b1-1"])
        #expect(store.lastDumps(place: nil, limit: 1)?.dumps.map(\.id) == ["a1-3"])
        #expect(store.lastDumps(place: nil, limit: 1)?.olderCounts == ["a1": 2])
    }

    @Test func lastDumpsGivesTheNewestDumpsOfAPlaceAndCountsTheOlderDumpsOfTheirRequests() throws {
        let places = SitePlaces()
        places.set("shop.test", DumpPlace(site: "shop.test"))
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = loadedStore(places: places)

        for seq in 1...5 {
            store.add(dump("worker", seq: seq))
        }

        store.add(dump("page", seq: 1))
        store.add(dump("blog", seq: 1, host: "blog.test"))
        store.add(dump("worker", seq: 6))

        let ofShop = try #require(store.lastDumps(place: DumpPlace(site: "shop.test"), limit: 3))
        let ofAll = try #require(store.lastDumps(place: nil, limit: 2))
        let everything = try #require(store.lastDumps(place: nil, limit: 100))

        #expect(ofShop.dumps.map(\.id) == ["worker-5", "page-1", "worker-6"])
        #expect(ofShop.requests.map(\.id) == ["worker", "page"])
        #expect(ofShop.olderCounts == ["worker": 4])
        #expect(ofAll.dumps.map(\.id) == ["blog-1", "worker-6"])
        #expect(ofAll.olderCounts == ["worker": 5])
        #expect(everything.dumps.count == 8)
        #expect(everything.olderCounts.isEmpty)
        #expect(store.lastDumps(place: nil, limit: 0)?.dumps.isEmpty == true)
    }

    @Test func aCursorOfAnotherEpochGivesNoDumpsAndTheCurrentCursor() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        let current = try cursor(of: store)
        let other = DumpCursor(epoch: "other", number: 0)

        #expect(store.newDumps(place: nil, after: other) == DumpBatch(dumps: [], requests: [], cursor: current))
        #expect(store.lastDumps(place: nil, limit: 20, through: other) == DumpBatch(dumps: [], requests: [], cursor: current))
    }

    @Test func aDumpLineHoldsItsNumberAsAnEncodeOfTheRecordDoes() throws {
        let caught = CaughtDump(requestID: "a1", seq: 1, time: started, file: "/Users/tim/Sites/shop/index.php", line: 3, text: "\"x\"", treeJSON: #"{"kind":"string","value":"x"}"#)
        var line = try #require(Record.openLine(dump: caught))

        Record.close(&line, number: 42)

        #expect(line == Record.line(dump: caught, number: 42))
    }

    @Test func aStartKeepsTheEpochAndGivesNumbersAboveAGap() throws {
        let store = loadedStore()

        for seq in 1...3 {
            store.add(dump("a1", seq: seq))
        }

        let before = try cursor(of: store)
        let loaded = reloaded()
        let after = try cursor(of: loaded)
        loaded.add(dump("a1", seq: 4))

        #expect(after == DumpCursor(epoch: before.epoch, number: 3 + DumpStore.numberGap))
        #expect(loaded.newDumps(place: nil, after: before)?.dumps.map(\.id) == ["a1-4"])
        #expect(try cursor(of: loaded).number == 4 + DumpStore.numberGap)
    }

    @Test func aCrashThatLosesTheLastLineNeverGivesItsNumberAgain() throws {
        let store = loadedStore()

        for seq in 1...3 {
            store.add(dump("a1", seq: seq))
        }

        let seen = try cursor(of: store)
        store.waitForWrites()
        let lines = try Data(contentsOf: file).split(separator: UInt8(ascii: "\n"))
        try lines.dropLast().map { Data($0) + Data("\n".utf8) }.reduce(Data(), +).write(to: file)

        let loaded = reloaded()
        loaded.add(dump("a1", seq: 4))

        #expect(loaded.dumps(request: "a1").map(\.seq) == [1, 2, 4])
        #expect(loaded.newDumps(place: nil, after: seen)?.dumps.map(\.id) == ["a1-4"])
        #expect(try cursor(of: loaded).number == 3 + DumpStore.numberGap)
    }

    @Test func aClearOfAllGivesANewEpochThatStaysAfterAStart() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        let before = try cursor(of: store)

        store.clear()

        let cleared = try cursor(of: store)
        let loaded = reloaded()

        #expect(cleared.epoch != before.epoch)
        #expect(store.newDumps(place: nil, after: before)?.cursor == cleared)
        #expect(try cursor(of: loaded).epoch == cleared.epoch)
    }

    @Test func aClearOfAllThatRemovesNothingKeepsTheEpoch() throws {
        let store = loadedStore()
        let before = try cursor(of: store)

        store.clear()

        #expect(try cursor(of: store).epoch == before.epoch)
    }

    @Test func aStartWithoutTheFileGivesANewEpoch() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        let first = try cursor(of: store)
        let again = try cursor(of: reloaded())

        try FileManager.default.removeItem(at: file)

        #expect(again.epoch == first.epoch)
        #expect(try cursor(of: reloaded()).epoch != first.epoch)
    }

    @Test func theNumbersStayAfterAClearOfAPlaceAndAStart() throws {
        let places = SitePlaces()
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = loadedStore(places: places)
        store.add(dump("a1", seq: 1))
        store.add(dump("b1", seq: 1, host: "blog.test"))
        let beforeTheClear = try cursor(of: store)
        store.clear(place: DumpPlace(site: "blog.test"))
        store.add(dump("a1", seq: 2))

        let loaded = reloaded()

        #expect(loaded.newDumps(place: nil, after: beforeTheClear)?.dumps.map(\.id) == ["a1-2"])
        #expect(try cursor(of: loaded).number == 3 + DumpStore.numberGap)
    }

    @Test func aClearThatRemovesNothingKeepsTheFile() throws {
        let store = store()
        store.add(dump("a1", seq: 1))
        store.waitForWrites()
        let before = try #require(attributes()[.systemFileNumber] as? Int)

        let removed = store.clear(place: DumpPlace(site: "blog.test"))

        store.waitForWrites()
        #expect(removed == 0)
        #expect(try attributes()[.systemFileNumber] as? Int == before)
    }

    @Test func aClearThatRemovesDumpsWritesANewFile() throws {
        let store = store()
        store.add(dump("a1", seq: 1))
        store.waitForWrites()
        let before = try #require(attributes()[.systemFileNumber] as? Int)

        store.clear()

        store.waitForWrites()
        #expect(try attributes()[.systemFileNumber] as? Int != before)
    }

    @Test func theFileGetsOnlyTheKeptRecordsWhenItIsLarge() throws {
        let store = store()

        for seq in 1...15 {
            store.add(dump("a1", seq: seq, text: megabyte))
        }

        store.waitForWrites()
        let beforeTheRewrite = try fileSize()

        for seq in 16...21 {
            store.add(dump("a1", seq: seq, text: megabyte))
        }

        store.waitForWrites()
        #expect(beforeTheRewrite > 15_000_000)
        #expect(try fileSize() < 11_000_000)
        #expect(reloaded().dumps(request: "a1") == store.dumps(request: "a1"))
        #expect(store.dumps(request: "a1").map(\.seq) == Array(12...21))
    }

    @Test func aRewriteKeepsTheOrderOfTheRequests() {
        let places = SitePlaces()
        places.set("blog.test", DumpPlace(site: "blog.test"))
        let store = store(places: places)
        store.add(dump("a", seq: 1, text: megabyte))
        store.add(dump("b", seq: 1))

        for seq in 2...11 {
            store.add(dump("a", seq: seq, text: megabyte))
        }

        store.add(dump("c", seq: 1, host: "blog.test"))
        store.clear(place: DumpPlace(site: "blog.test"))

        #expect(store.dumps(request: "a").first?.seq == 2)
        #expect(store.list().map(\.id) == ["b", "a"])
        #expect(reloaded().list().map(\.id) == ["b", "a"])
    }

    @Test func listAndDumpsDoNotWaitForTheFile() {
        let store = store()
        let diskIsBusy = DispatchSemaphore(value: 0)
        store.add(dump("a1", seq: 1))
        store.add(dump("b1", seq: 1, host: "blog.test"))
        store.writer.queue.async { diskIsBusy.wait() }

        store.add(dump("a1", seq: 2))
        store.clear(place: DumpPlace(site: "none"))
        store.clear()
        let list = store.list()
        let dumps = store.dumps(request: "a1")
        diskIsBusy.signal()

        #expect(list.isEmpty)
        #expect(dumps.isEmpty)
    }

    @Test func locateRunsOnlyForANewRequest() {
        let places = SitePlaces()
        let store = store(places: places)

        store.add(end("a1", status: 200))
        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 2))
        store.add(dump("b1", seq: 1))

        #expect(places.callCount == 2)
    }

    @Test func relocateGivesEachRequestItsNewPlace() {
        let places = SitePlaces()
        let store = store(places: places)
        store.add(dump("a1", seq: 1))
        store.add(end("waits", status: 200))
        _ = store.takeChanges()

        places.set("shop.test", DumpPlace(site: "shop.test"))
        store.relocate()
        store.add(dump("waits", seq: 1))

        let changes = store.takeChanges()
        #expect(store.list(place: DumpPlace(site: "shop.test")).map(\.id) == ["waits", "a1"])
        #expect(changes.changed.map(\.id) == ["a1", "waits"])
        #expect(reloaded().list(place: DumpPlace(site: "shop.test")).map(\.id) == ["waits", "a1"])
    }

    @Test func theChangesNameEachRequestOnce() {
        let store = store()

        store.add(dump("a1", seq: 1))
        store.add(dump("a1", seq: 2))
        store.add(end("a1", status: 200))
        store.add(dump("b1", seq: 1))
        let first = store.takeChanges()
        let second = store.takeChanges()

        #expect(first.changed.map(\.id) == ["a1", "b1"])
        #expect(first.changed.first?.dumpCount == 2)
        #expect(first.changed.first?.status == 200)
        #expect(second.isEmpty)
    }

    @Test func aRequestThatCameAndWentIsReportedAsRemoved() {
        let store = store()
        _ = store.takeChanges()

        store.add(dump("a1", seq: 1))
        store.clear(place: DumpPlace())

        #expect(store.takeChanges() == DumpChange(removed: ["a1"]))
    }

    @Test func aRemovedDumpLeavesItsRequestWithTheCountsOfTheOtherDumps() throws {
        let store = loadedStore()
        store.add(dump("a1", seq: 1, kind: .dd))
        store.add(dump("a1", seq: 2))
        store.add(dump("a1", seq: 3))
        _ = store.takeChanges()

        let removedFirst = store.remove(dump: 1)
        let removedLast = store.remove(dump: 3)

        let changes = store.takeChanges()
        let request = try #require(store.list().first)
        #expect(removedFirst)
        #expect(removedLast)
        #expect(store.dumps(request: "a1").map(\.seq) == [2])
        #expect(request.dumpCount == 1)
        #expect(request.firstSeq == 2)
        #expect(request.firstNumber == 2)
        #expect(request.lastNumber == 2)
        #expect(!request.hasDD)
        #expect(changes.changed.map(\.id) == ["a1"])
        #expect(changes.removedDumps == [1, 3])
        #expect(reloaded().dumps(request: "a1").map(\.seq) == [2])
    }

    @Test func theLastRemovedDumpOfARequestRemovesTheRequest() {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        store.add(dump("b1", seq: 1))
        _ = store.takeChanges()

        store.remove(dump: 1)

        #expect(store.list().map(\.id) == ["b1"])
        #expect(store.takeChanges() == DumpChange(removed: ["a1"], removedDumps: [1]))
        #expect(reloaded().list().map(\.id) == ["b1"])
    }

    @Test func aRemovedRequestTakesAllItsDumpsAndKeepsTheOtherRequests() {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        store.add(dump("b1", seq: 1))
        store.add(dump("a1", seq: 2))
        _ = store.takeChanges()

        let removed = store.remove(request: "a1")

        #expect(removed == 2)
        #expect(store.list().map(\.id) == ["b1"])
        #expect(store.dumps(request: "a1").isEmpty)
        #expect(store.takeChanges() == DumpChange(removed: ["a1"]))
        #expect(reloaded().list().map(\.id) == ["b1"])
    }

    @Test func aRemoveOfAnUnknownDumpOrRequestChangesNothing() {
        let store = loadedStore()
        store.add(dump("a1", seq: 1))
        _ = store.takeChanges()

        let removedDump = store.remove(dump: 42)
        let removedDumps = store.remove(request: "x1")

        #expect(!removedDump)
        #expect(removedDumps == nil)
        #expect(store.list().map(\.id) == ["a1"])
        #expect(store.takeChanges().isEmpty)
    }
}
