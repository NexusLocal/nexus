import Foundation
import NexusCore
import Synchronization
import Testing
@testable import NexusDumps

final class SitePlaces: Sendable {
    private let places = Mutex<[String: DumpPlace]>([:])
    private let calls = Mutex(0)

    func set(_ host: String, _ place: DumpPlace) {
        places.withLock { current in current[host] = place }
    }

    func place(of request: DumpedRequest) -> DumpPlace {
        calls.withLock { count in count += 1 }
        return places.withLock { current in current[request.host ?? ""] ?? DumpPlace() }
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
        let store = DumpStore(file: file) { request in places?.place(of: request) ?? DumpPlace() }
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

    @Test func dumpsAfterASeqGivesOnlyTheNewerDumps() {
        let store = store()

        for seq in 1...4 {
            store.add(dump("a1", seq: seq))
        }

        #expect(store.dumps(request: "a1", after: 2).map(\.seq) == [3, 4])
        #expect(store.dumps(request: "a1", after: 4).isEmpty)
        #expect(store.dumps(request: "a1").map(\.seq) == [1, 2, 3, 4])
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
        #expect(store.takeChanges() == DumpStoreChanges(cleared: true))
        #expect(try fileSize() == 0)
        #expect(reloaded().list().isEmpty)
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

        #expect(store.takeChanges() == DumpStoreChanges(removed: ["a1"]))
    }
}
