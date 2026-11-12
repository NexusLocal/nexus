import Foundation
import NexusCore
import NexusDumps
import NexusIPC
import NexusTestSupport
import Testing
@testable import NexusEngine

private enum DumpWire {
    static let started = 1_794_414_394.0

    static func envelope(_ id: String, host: String?, root: String?, started: Double) -> [String: Any] {
        var envelope: [String: Any] = ["id": id, "started": started, "pid": 4512]

        if let host {
            envelope.merge(["kind": "http", "method": "GET", "url": "https://\(host)/checkout?step=2", "host": host]) { _, new in new }
        } else {
            envelope.merge(["kind": "command", "command": "php artisan import:products", "cwd": root ?? "/"]) { _, new in new }
        }

        if let root {
            envelope["root"] = root
        }

        return envelope
    }

    static func dump(_ id: String, host: String? = nil, root: String?, seq: Int = 1, text: String = "\"Nexus\"", started: Double = started) -> String {
        line([
            "v": 1,
            "type": "dump",
            "request": envelope(id, host: host, root: root, started: started),
            "dump": ["seq": seq, "time": started + Double(seq) / 1000, "kind": "dump", "text": text, "tree": #"{"kind":"string","value":"Nexus"}"#, "truncated": false],
        ])
    }

    static func end(_ id: String, host: String? = nil, root: String?, status: Int) -> String {
        line(["v": 1, "type": "end", "request": envelope(id, host: host, root: root, started: started), "status": status, "duration": 0.184])
    }

    static func blocked(_ id: String, host: String? = nil, root: String?) -> String {
        line(["v": 1, "type": "blocked", "request": envelope(id, host: host, root: root, started: started), "reason": "var_dumper_format", "detail": "server"])
    }

    static func send(_ lines: [String], to engine: NexusEngine) async throws {
        try DumpSocketClient.send(lines.map { "\($0)\n" }.joined(), to: await engine.paths.dumpSocket)
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension NexusEngineTests {
    private static let realPHP = "\(NSHomeDirectory())/Library/Application Support/Nexus Dev/runtimes/php/8.5/bin/php"

    private func folder(_ name: String, in root: URL) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func twoSiteEngine(in root: URL) throws -> (engine: NexusEngine, shop: URL, blog: URL) {
        let shop = try folder("shop", in: root)
        let blog = try folder("blog", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5"), Site(host: "blog.test", folder: blog, php: "8.5")]
        return (try makeSiteEngine(root: root, state: state), shop, blog)
    }

    private func dumpEvents(of engine: NexusEngine) async -> EventRecorder<NexusEvent> {
        let recorder = EventRecorder<NexusEvent> { event in
            if event.dumpList != nil {
                return event
            }

            return event.dumpChanges.map { _ in event }
        }
        recorder.record(await engine.events())
        return recorder
    }

    private func places(of engine: NexusEngine) async -> [String: DumpPlace] {
        Dictionary(uniqueKeysWithValues: await engine.dumpStore.list().map { ($0.id, $0.place) })
    }

    @Test func theReceiverStartsWithNexusdAndStopsAtItsShutdown() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let paths = await engine.paths
        let paused = paths.dumpFolder.appending(path: "paused")
        try FileManager.default.createDirectory(at: paths.dumpFolder, withIntermediateDirectories: true)
        try Data().write(to: paused)

        await engine.startEnabledServices()
        let running = await engine.dumpList(place: nil)
        let socketWhileRunning = exists(paths.dumpSocket)
        let pausedWhileRunning = exists(paused)
        await engine.shutdown()
        let stopped = await engine.dumpList(place: nil)

        #expect(running.receiving)
        #expect(socketWhileRunning)
        #expect(!pausedWhileRunning)
        #expect(!stopped.receiving)
        #expect(!exists(paths.dumpSocket))
    }

    @Test func atTheStartTheStoreLoadsItsFileAndTheWatchersGetTheListWithItsBlocks() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        let earlierRun = DumpStore(file: await engine.paths.dumpLog)
        earlierRun.add(try DumpLine.decode(Data(DumpWire.dump("s1", root: RealPath.of(shop)).utf8)))
        earlierRun.waitForWrites()
        try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: shop.appending(path: ".env"))

        try await whileRunning(engine) {
            let events = await dumpEvents(of: engine)
            let before = await events.next { $0.dumpList != nil }?.dumpList
            await engine.startEnabledServices()
            let after = await events.next { $0.dumpList?.receiving == true }?.dumpList

            #expect(earlierRun.list().first?.site == nil)
            #expect(before?.requests.isEmpty == true)
            #expect(after?.requests.map(\.id) == ["s1"])
            #expect(after?.requests.first?.place == DumpPlace(site: "shop.test"))
            #expect(after?.blocked.map(\.host) == ["shop.test"])
        }
    }

    @Test func aReceiverThatCannotStartGoesIntoTheActivityLogAndTheListAndNexusdGoesOn() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let engine = try makeSiteEngine(root: root, activity: activity)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let list = await engine.dumpList(place: nil)
            let status = await engine.handle(.status)
            activity.waitForWrites()
            let log = try String(contentsOf: logFile, encoding: .utf8)

            #expect(!list.receiving)
            #expect(list.problem?.hasPrefix("Nexus catches no dumps, because nexusd cannot listen on its socket. The socket path ") == true)
            #expect(list.problem?.contains("is longer than the 103 bytes that macOS permits.") == true)
            #expect(log.contains("dumps: Nexus catches no dumps, because nexusd cannot listen on its socket."))
            if case .services = status {} else { Issue.record("nexusd did not answer: \(status)") }
        }
    }

    @Test func aRequestFindsItsSiteOrWorkspaceFromItsHostFirstAndItsRootSecond() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        let blog = try folder("blog", in: root)
        let fix = try folder("shop-fix", in: root)
        let elsewhere = try folder("elsewhere", in: root)
        let shopSite = Site(host: "shop.test", folder: shop, php: "8.5")
        var state = EngineState()
        state.sites = [shopSite, Site(host: "blog.test", folder: blog, php: "8.5")]
        state.worktrees[ProjectFolder.workspaceKey(of: shopSite)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: fix.path(percentEncoded: false), folder: fix.path(percentEncoded: false))])
        let engine = try makeSiteEngine(root: root, state: state)
        let fixHost = HostName.workspaceHost("shop.test", workspace: "fix", tld: state.tld)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("host-before-root", host: "shop.test", root: RealPath.of(blog)),
                DumpWire.dump("unknown-host", host: "news.blog.test", root: RealPath.of(blog)),
                DumpWire.dump("command", root: RealPath.of(blog)),
                DumpWire.dump("workspace-host", host: fixHost, root: RealPath.of(fix)),
                DumpWire.dump("workspace-command", root: "\(RealPath.of(fix))/app"),
                DumpWire.dump("outside", root: RealPath.of(elsewhere)),
            ], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().count == 6 }
            let places = await places(of: engine)

            #expect(arrived)
            #expect(places["host-before-root"] == DumpPlace(site: "shop.test"))
            #expect(places["unknown-host"] == DumpPlace(site: "blog.test"))
            #expect(places["command"] == DumpPlace(site: "blog.test"))
            #expect(places["workspace-host"] == DumpPlace(site: "shop.test", workspace: "fix"))
            #expect(places["workspace-command"] == DumpPlace(site: "shop.test", workspace: "fix"))
            #expect(places["outside"] == DumpPlace())

            let locations = Dictionary(uniqueKeysWithValues: await engine.dumpStore.list().map { ($0.id, $0.location) })
            #expect(locations["host-before-root"] == DumpLocation(place: DumpPlace(site: "shop.test"), host: "shop.test", projectFolder: RealPath.of(shop)))
            #expect(locations["workspace-command"] == DumpLocation(place: DumpPlace(site: "shop.test", workspace: "fix"), host: fixHost, projectFolder: RealPath.of(fix)))
            #expect(locations["outside"] == DumpLocation())
        }
    }

    @Test func aNewSiteGivesItsCaughtRequestsTheirPlaceAndTheAppGetsTheChangedHeader() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        let blog = try folder("blog", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let events = await dumpEvents(of: engine)
            try await DumpWire.send([DumpWire.dump("b1", root: RealPath.of(blog))], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().count == 1 }
            let before = await places(of: engine)["b1"]

            try await engine.stateStore.update { $0.sites.append(Site(host: "blog.test", folder: blog, php: "8.5")) }
            await engine.publishSites()
            let moved = await eventually { await places(of: engine)["b1"] == DumpPlace(site: "blog.test") }
            let change = await events.next { $0.dumpChanges?.changed.first?.site == "blog.test" }

            #expect(arrived)
            #expect(before == DumpPlace())
            #expect(moved)
            #expect(change != nil)
        }
    }

    @Test func aEnvWithVarDumperFormatAndAUserIniWithAPrependFileBlockTheirSite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        let blog = try folder("blog", in: root)
        let news = try folder("news", in: root)
        let app = try folder("app", in: root)
        let blogPublic = try folder("public", in: blog)
        try Data("APP_NAME=Shop\nVAR_DUMPER_FORMAT=server\n".utf8).write(to: shop.appending(path: ".env"))
        try Data("auto_prepend_file = '/Sites/blog/wordfence-waf.php'\n".utf8).write(to: blogPublic.appending(path: ".user.ini"))
        try Data("; auto_prepend_file = '/Sites/news/waf.php'\n".utf8).write(to: news.appending(path: ".user.ini"))
        try Data("VAR_DUMPER_FORMAT=cli\n".utf8).write(to: app.appending(path: ".env"))
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, php: "8.5"),
            Site(host: "blog.test", folder: blog, php: "8.5"),
            Site(host: "news.test", folder: news, php: "8.5"),
            Site(host: "app.test", folder: app, php: "8.5", runsAs: .node),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        let shopBlock = DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "\(RealPath.of(shop))/.env", place: DumpPlace(site: "shop.test"))
        let blogBlock = DumpBlock(host: "blog.test", reason: .userIni, file: "\(RealPath.of(blogPublic))/.user.ini", place: DumpPlace(site: "blog.test"))

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let all = await engine.dumpList(place: nil)
            let ofShop = await engine.dumpList(place: DumpPlace(site: "shop.test"))
            let ofBlog = await engine.handle(.dumpList(place: DumpPlace(site: "blog.test")))

            #expect(all.blocked == [blogBlock, shopBlock])
            #expect(ofShop.blocked == [shopBlock])
            if case .dumpList(let list) = ofBlog {
                #expect(list.blocked == [blogBlock])
            } else {
                Issue.record("no dump list: \(ofBlog)")
            }
        }
    }

    @Test func aFixedEnvRemovesTheBlockAtTheNextList() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: shop.appending(path: ".env"))

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let events = await dumpEvents(of: engine)
            let blocked = await events.next { $0.dumpList != nil }?.dumpList?.blocked
            try Data("APP_NAME=Shop\n".utf8).write(to: shop.appending(path: ".env"))
            let request = await engine.dumpList(place: DumpPlace(site: "shop.test")).blocked
            await engine.publishDumpList()
            let published = await events.next { $0.dumpList?.blocked.isEmpty == true }

            #expect(blocked?.map(\.host) == ["shop.test"])
            #expect(request.isEmpty)
            #expect(published != nil)
        }
    }

    @Test func aBlockedEventBlocksItsSiteUntilANewerRequestOfThatSiteSendsADump() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, blog) = try twoSiteEngine(in: root)
        let elsewhere = try folder("elsewhere", in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let events = await dumpEvents(of: engine)
            try await DumpWire.send([
                DumpWire.blocked("web", host: "shop.test", root: RealPath.of(shop)),
                DumpWire.blocked("command", root: RealPath.of(blog)),
                DumpWire.blocked("outside", root: RealPath.of(elsewhere)),
            ], to: engine)
            let blocked = await events.next { $0.dumpList?.blocked.count == 2 }?.dumpList?.blocked

            try await DumpWire.send([DumpWire.dump("later", host: "shop.test", root: RealPath.of(shop), started: DumpWire.started + 5)], to: engine)
            let answered = await events.next { $0.dumpList?.blocked.map(\.host) == ["blog.test"] }

            try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: blog.appending(path: ".env"))
            let fromTheFile = await engine.dumpList(place: nil).blocked

            #expect(blocked == [DumpBlock(host: "blog.test", reason: .varDumperFormat, place: DumpPlace(site: "blog.test")), DumpBlock(host: "shop.test", reason: .varDumperFormat, place: DumpPlace(site: "shop.test"))])
            #expect(answered != nil)
            #expect(fromTheFile == [DumpBlock(host: "blog.test", reason: .varDumperFormat, file: "\(RealPath.of(blog))/.env", place: DumpPlace(site: "blog.test"))])
        }
    }

    @Test func theRequestsListGiveAndClearTheCaughtDumps() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, blog) = try twoSiteEngine(in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 1, text: "\"one\""),
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 2, text: "\"two\""),
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 3, text: "\"three\""),
                DumpWire.dump("b1", root: RealPath.of(blog)),
            ], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().map(\.dumpCount).reduce(0, +) == 4 }

            let ofShop = await engine.handle(.dumpList(place: DumpPlace(site: "shop.test")))
            let withoutASite = await engine.handle(.dumpList(place: DumpPlace()))
            let newer = await engine.handle(.requestDumps(request: "s1", afterNumber: 1))
            let cleared = await engine.handle(.clearCaughtDumps(place: DumpPlace(site: "shop.test")))
            let clearedAgain = await engine.handle(.clearCaughtDumps(place: DumpPlace(site: "shop.test")))
            let left = await engine.handle(.dumpList(place: nil))

            #expect(arrived)
            guard case .dumpList(let shopList) = ofShop, case .dumpList(let emptyList) = withoutASite, case .caughtDumps(let dumps) = newer, case .dumpList(let leftList) = left else {
                Issue.record("wrong answers: \(ofShop) \(newer) \(left)")
                return
            }

            #expect(shopList.requests.map(\.id) == ["s1"])
            #expect(shopList.requests.first?.dumpCount == 3)
            #expect(shopList.receiving)
            #expect(shopList.dumpCount == 3)
            #expect(emptyList.requests.isEmpty)
            #expect(dumps.map(\.text) == ["\"two\"", "\"three\""])
            #expect(cleared == .done(message: "Nexus removed 3 dumps."))
            #expect(clearedAgain == .done(message: "The list has no dumps to remove."))
            #expect(leftList.requests.map(\.id) == ["b1"])
        }
    }

    @Test func theCursorOfTheListGivesTheNewDumpsOfAPlaceAndABatchGivesSeveralRequests() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, blog) = try twoSiteEngine(in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 1),
                DumpWire.dump("b1", host: "blog.test", root: RealPath.of(blog), seq: 1),
            ], to: engine)
            let first = await eventually { await engine.dumpStore.list().count == 2 }
            let listed = await engine.handle(.dumpList(place: nil))

            try await DumpWire.send([
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 2),
                DumpWire.dump("b1", host: "blog.test", root: RealPath.of(blog), seq: 2),
            ], to: engine)
            let second = await eventually { await engine.dumpStore.list().map(\.dumpCount).reduce(0, +) == 4 }

            #expect(first)
            #expect(second)
            guard case .dumpList(let list) = listed, let listCursor = list.cursor else {
                Issue.record("wrong answer: \(listed)")
                return
            }

            let ofShop = await engine.handle(.newDumps(place: DumpPlace(site: "shop.test"), after: listCursor))
            let latest = await engine.handle(.lastDumps(place: nil, limit: 20, through: listCursor))
            let latestOfShop = await engine.handle(.lastDumps(place: DumpPlace(site: "shop.test"), limit: 1, through: nil))

            guard case .dumpBatch(let newOfShop) = ofShop, case .dumpBatch(let both) = latest, case .dumpBatch(let oneOfShop) = latestOfShop else {
                Issue.record("wrong answers: \(ofShop) \(latest) \(latestOfShop)")
                return
            }

            #expect(list.loaded)
            #expect(listCursor.number == 2)
            #expect(list.requests.map(\.lastSeq) == [1, 1])
            #expect(newOfShop.dumps.map(\.id) == ["s1-2"])
            #expect(newOfShop.requests.map(\.lastSeq) == [2])
            #expect(newOfShop.cursor == DumpCursor(epoch: listCursor.epoch, number: 4))
            #expect(Set(both.dumps.map(\.id)) == ["s1-1", "b1-1"])
            #expect(Set(both.requests.map(\.id)) == ["s1", "b1"])
            #expect(oneOfShop.dumps.map(\.id) == ["s1-2"])
            #expect(oneOfShop.olderCounts == ["s1": 1])
        }
    }

    @Test func beforeTheLoadOfTheStoreTheListSaysSoAndTheReadsWait() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, _, _) = try twoSiteEngine(in: root)
        let anyCursor = DumpCursor(epoch: "old", number: 0)
        let notLoaded = NexusResponse.failure(message: DumpList.notLoadedText)

        try await whileRunning(engine) {
            let events = await dumpEvents(of: engine)
            let firstEvent = await events.next { $0.dumpList != nil }?.dumpList
            let before = await engine.handle(.dumpList(place: nil))
            let newDumps = await engine.handle(.newDumps(place: nil, after: anyCursor))
            let batch = await engine.handle(.lastDumps(place: nil, limit: 20, through: anyCursor))
            let clear = await engine.handle(.clearCaughtDumps(place: nil))
            await engine.startEnabledServices()
            let loadedEvent = await events.next { $0.dumpList?.loaded == true }?.dumpList

            guard case .dumpList(let list) = before else {
                Issue.record("wrong answer: \(before)")
                return
            }

            #expect(!list.loaded)
            #expect(list.cursor == nil)
            #expect(firstEvent?.loaded == false)
            #expect(newDumps == notLoaded)
            #expect(batch == notLoaded)
            #expect(clear == notLoaded)
            #expect(loadedEvent?.cursor != nil)
        }
    }

    @Test func aReadAfterANumberGivesTheDumpsOfARequestInTheOrderInWhichTheyArrived() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 1),
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 3),
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 2),
            ], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().first?.dumpCount == 3 }
            let all = await engine.handle(.requestDumps(request: "s1", afterNumber: 0))
            let afterTwo = await engine.handle(.requestDumps(request: "s1", afterNumber: 2))

            #expect(arrived)
            #expect(await engine.dumpStore.list().first?.lastNumber == 3)

            guard case .caughtDumps(let dumps) = all, case .caughtDumps(let later) = afterTwo else {
                Issue.record("wrong answers: \(all) \(afterTwo)")
                return
            }

            #expect(dumps.map(\.seq) == [1, 3, 2])
            #expect(dumps.map(\.number) == [1, 2, 3])
            #expect(later.map(\.seq) == [2])
        }
    }

    @Test func aWatcherBeforeTheLoadGetsTheLoadedListBeforeTheServicesStart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        let earlierRun = DumpStore(file: await engine.paths.dumpLog)
        earlierRun.add(try DumpLine.decode(Data(DumpWire.dump("s1", root: RealPath.of(shop)).utf8)))
        earlierRun.waitForWrites()

        try await whileRunning(engine) {
            let events = await dumpEvents(of: engine)
            let before = await events.next { $0.dumpList != nil }?.dumpList
            await engine.startDumpReceiver()
            let loaded = await events.next { $0.dumpList?.loaded == true }?.dumpList

            #expect(before?.loaded == false)
            #expect(loaded?.requests.map(\.id) == ["s1"])
            #expect(loaded?.requests.first?.place == DumpPlace(site: "shop.test"))
        }
    }

    @Test func theStateGivesTheSettingsAndTheBlocksOfAPlaceWithoutTheRequests() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: shop.appending(path: ".env"))
        let shopBlock = DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "\(RealPath.of(shop))/.env", place: DumpPlace(site: "shop.test"))

        try await whileRunning(engine) {
            let beforeTheLoad = await engine.handle(.dumpState(place: nil))
            await engine.startDumpReceiver()
            try await DumpWire.send([DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop))], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().count == 1 }
            let all = await engine.handle(.dumpState(place: nil))
            let ofBlog = await engine.handle(.dumpState(place: DumpPlace(site: "blog.test")))
            let list = await engine.dumpList(place: nil)

            #expect(arrived)

            if case .dumpState(let state) = beforeTheLoad {
                #expect(!state.loaded)
                #expect(!state.receiving)
            } else {
                Issue.record("no dump state: \(beforeTheLoad)")
            }

            #expect(all == .dumpState(DumpState(settings: DumpSettings(), blocked: [shopBlock], receiving: true, loaded: true)))
            #expect(ofBlog == .dumpState(DumpState(settings: DumpSettings(), blocked: [], receiving: true, loaded: true)))
            #expect(all == .dumpState(list.state))
        }
    }

    @Test func nexusdGivesThePlaceOfAHostOfASiteAnAliasAndAWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        let fix = try folder("shop-fix", in: root)
        let shopSite = Site(host: "shop.test", folder: shop, aliases: ["www.shop.test"], php: "8.5")
        var state = EngineState()
        state.sites = [shopSite]
        state.worktrees[ProjectFolder.workspaceKey(of: shopSite)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: fix.path(percentEncoded: false), folder: fix.path(percentEncoded: false))])
        let engine = try makeSiteEngine(root: root, state: state)
        let fixHost = HostName.workspaceHost("shop.test", workspace: "fix", tld: state.tld)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()

            #expect(await engine.handle(.dumpPlace(host: "shop.test")) == .dumpPlace(place: DumpPlace(site: "shop.test"), host: "shop.test"))
            #expect(await engine.handle(.dumpPlace(host: "www.shop.test")) == .dumpPlace(place: DumpPlace(site: "shop.test"), host: "shop.test"))
            #expect(await engine.handle(.dumpPlace(host: fixHost)) == .dumpPlace(place: DumpPlace(site: "shop.test", workspace: "fix"), host: fixHost))
            #expect(await engine.handle(.dumpPlace(host: "Shop.test")) == .dumpPlace(place: DumpPlace(site: "shop.test"), host: "shop.test"))
            #expect(await engine.handle(.dumpPlace(host: "https://shop.test/")) == .dumpPlace(place: DumpPlace(site: "shop.test"), host: "shop.test"))
            #expect(await engine.handle(.dumpPlace(host: "shop.test:443")) == .dumpPlace(place: DumpPlace(site: "shop.test"), host: "shop.test"))
            #expect(await engine.handle(.dumpPlace(host: "nope.test")) == .failure(message: "Nexus has no site or workspace nope.test. See: nexus site list"))
        }
    }

    @Test func aWatcherGetsTheListAndThenOnlyTheChangedHeadersWithoutTheDumps() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, blog) = try twoSiteEngine(in: root)
        let shopRoot = RealPath.of(shop)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([DumpWire.dump("s1", host: "shop.test", root: shopRoot, text: "\"the first secret\"")], to: engine)
            _ = await eventually { await engine.dumpStore.list().count == 1 }
            let events = await dumpEvents(of: engine)
            let list = await events.next { $0.dumpList != nil }

            try await DumpWire.send([DumpWire.dump("b1", root: RealPath.of(blog), text: "\"the second secret\"")], to: engine)
            let blogOnly = await events.next { $0.dumpChanges?.changed.map(\.id) == ["b1"] }
            try await DumpWire.send([DumpWire.end("s1", host: "shop.test", root: shopRoot, status: 201)], to: engine)
            let ended = await events.next { $0.dumpChanges?.changed.first?.status == 201 }
            try await DumpWire.send((1...50).map { DumpWire.dump("s1", host: "shop.test", root: shopRoot, seq: $0 + 1) }, to: engine)
            let burst = await eventually { events.all.contains { $0.dumpChanges?.changed.first?.dumpCount == 51 } }
            let changesOfTheBurst = events.all.filter { $0.dumpChanges != nil }.count
            _ = await engine.handle(.clearCaughtDumps(place: nil))
            let cleared = await events.next { $0.dumpChanges?.cleared == true }
            let encoded = try [list, blogOnly, ended, cleared].compactMap { $0 }.map { String(decoding: try NexusMessageCoding.encode($0), as: UTF8.self) }

            #expect(list?.dumpList?.requests.map(\.id) == ["s1"])
            #expect(list?.dumpList?.receiving == true)
            #expect(blogOnly?.dumpChanges?.changed.first?.site == "blog.test")
            #expect(ended != nil)
            #expect(burst)
            #expect(changesOfTheBurst < 10)
            #expect(cleared != nil)
            #expect(encoded.count == 4)
            #expect(!encoded.contains { $0.contains("secret") })
            #expect(!encoded.contains { $0.contains("\"text\"") })
        }
    }

    @Test func aNewWatcherGetsItsOwnDumpListAndTheOtherWatchersGetNoneAgain() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, _, _) = try twoSiteEngine(in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let first = await dumpEvents(of: engine)
            let firstList = await first.next { $0.dumpList != nil }
            try await Task.sleep(for: .milliseconds(300))
            let second = await dumpEvents(of: engine)
            let secondList = await second.next { $0.dumpList != nil }
            try await Task.sleep(for: .milliseconds(300))

            #expect(firstList != nil)
            #expect(secondList != nil)
            #expect(first.all.isEmpty)
            #expect(second.all.isEmpty)
        }
    }

    @Test func newDumpSettingsWaitForTheChangeBeforeThemAndReachTheWatchers() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        let settings = DumpSettings(catchDumps: true, pageMode: .never, commands: true)

        try await whileRunning(engine) {
            let events = await dumpEvents(of: engine)
            let (gate, opener) = AsyncStream.makeStream(of: Void.self)
            let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
            let change = Task {
                try await engine.serialWeb {
                    startedSignal.yield()
                    for await _ in gate {}
                }
            }
            var startedChange = started.makeAsyncIterator()
            _ = await startedChange.next()

            let request = Task { await engine.handle(.setDumpSettings(settings)) }
            try await Task.sleep(for: .milliseconds(300))
            let whileTheChangeRuns = await engine.stateStore.current().dumpSettings
            opener.finish()
            try await change.value
            let response = await request.value
            await engine.syncBackgroundProcesses().value
            let published = await events.next { $0.dumpList?.settings == settings }

            #expect(whileTheChangeRuns == DumpSettings())
            #expect(await engine.stateStore.current().dumpSettings == settings)
            if case .done(let message) = response {
                #expect(message.hasPrefix("The settings of the dump viewer are changed."))
            } else {
                Issue.record("the settings did not change: \(response)")
            }
            #expect(published != nil)
        }
    }

    @Test func aCommandInTheFolderOfASiteGetsThatSiteAndNotTheSiteOnItsPublicFolder() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try folder("p", in: root)
        let publicFolder = try folder("public", in: project)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [Site(host: "a.test", folder: publicFolder, php: "8.5"), Site(host: "b.test", folder: project, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("in-public", root: RealPath.of(publicFolder)),
                DumpWire.dump("in-project", root: RealPath.of(project)),
            ], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().count == 2 }
            let places = await places(of: engine)

            #expect(arrived)
            #expect(places["in-public"] == DumpPlace(site: "a.test"))
            #expect(places["in-project"] == DumpPlace(site: "b.test"))
        }
    }

    @Test func aWatcherWithAnOlderListGetsTheNextListAlsoWhenItMatchesTheListOfAnotherWatcher() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        let env = shop.appending(path: ".env")
        try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: env)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let first = await dumpEvents(of: engine)
            let firstList = await first.next { $0.dumpList != nil }
            try Data("APP_NAME=Shop\n".utf8).write(to: env)
            let second = await dumpEvents(of: engine)
            let secondList = await second.next { $0.dumpList != nil }
            try Data("VAR_DUMPER_FORMAT=server\n".utf8).write(to: env)
            await engine.publishDumpList()
            let again = await second.next { $0.dumpList != nil }

            #expect(firstList?.dumpList?.blocked.map(\.host) == ["shop.test"])
            #expect(secondList?.dumpList?.blocked.isEmpty == true)
            #expect(again?.dumpList?.blocked.map(\.host) == ["shop.test"])
        }
    }

    @Test func aBlockOfACommandStaysAfterADumpOfAWebRequest() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let events = await dumpEvents(of: engine)
            try await DumpWire.send([DumpWire.blocked("command", root: RealPath.of(shop))], to: engine)
            let blocked = await events.next { $0.dumpList?.blocked.isEmpty == false }
            try await DumpWire.send([DumpWire.dump("later", host: "shop.test", root: RealPath.of(shop), started: DumpWire.started + 5)], to: engine)
            let dumped = await events.next { $0.dumpChanges?.changed.first?.id == "later" }
            try await Task.sleep(for: .milliseconds(300))
            let blocks = await engine.dumpList(place: nil).blocked

            #expect(blocked != nil)
            #expect(dumped != nil)
            #expect(blocks == [DumpBlock(host: "shop.test", reason: .varDumperFormat, place: DumpPlace(site: "shop.test"))])
        }
    }

    @Test func aRequestAfterNewDumpSettingsSendsNoSecondList() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, _, _) = try twoSiteEngine(in: root)
        let settings = DumpSettings(catchDumps: false, pageMode: .always, commands: false)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let events = await dumpEvents(of: engine)
            _ = await events.next { $0.dumpList != nil }

            _ = await engine.handle(.setDumpSettings(settings))
            await engine.syncBackgroundProcesses().value
            let published = await events.next { $0.dumpList?.settings == settings }
            try await Task.sleep(for: .milliseconds(300))

            #expect(published != nil)
            #expect(events.all.allSatisfy { $0.dumpList == nil })
        }
    }

    @Test func theDumpListCopiesNoLibraryAndAtTheLimitTheFirstBlockGoes() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("library", in: root)
        let engine = try makeSiteEngine(root: root, dumpLibrarySource: library)
        let entries = (0...NexusEngine.dumpEventBlockLimit).map { number in
            SiteMap.Entry(place: DumpPlace(site: "site\(number).test"), host: "site\(number).test")
        }
        await engine.siteMap.set(SiteMap(hosts: Dictionary(uniqueKeysWithValues: entries.map { ($0.host, $0) })))

        let list = await engine.dumpList(place: nil)

        for (number, entry) in entries.enumerated() {
            let started = Date(timeIntervalSince1970: DumpWire.started - Double(number))
            await engine.dumpBlocked(DumpedRequest(id: "r\(number)", kind: .http, target: "/", host: entry.host, started: started), reason: .varDumperFormat)
        }

        let hosts = Set(await engine.dumpEventBlocks.keys.map(\.block.host))

        #expect(list.problem == nil)
        #expect(await engine.installedDumpLibrary == nil)
        #expect(await engine.dumpLibraryFailed == false)
        #expect(hosts.count == NexusEngine.dumpEventBlockLimit)
        #expect(!hosts.contains("site0.test"))
        #expect(hosts.contains("site\(NexusEngine.dumpEventBlockLimit).test"))
    }

    @Test func theStopOfTheReceiverForgetsTheBlocksAndTheProblemOfThisRun() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        await engine.startDumpReceiver()
        await engine.siteMap.set(SiteMap(hosts: ["shop.test": SiteMap.Entry(place: DumpPlace(site: "shop.test"), host: "shop.test")]))
        await engine.dumpBlocked(DumpedRequest(id: "r1", kind: .http, target: "/", host: "shop.test", started: .now), reason: .varDumperFormat)
        await engine.dumpsChanged()
        let problemWhileRunning = await engine.dumpReceiverProblem
        let blocksWhileRunning = await engine.dumpEventBlocks.count
        await engine.shutdown()

        #expect(problemWhileRunning != nil)
        #expect(blocksWhileRunning == 1)
        #expect(await engine.dumpReceiverProblem == nil)
        #expect(await engine.dumpEventBlocks.isEmpty)
        #expect(await engine.dumpTicker == nil)
    }

    @Test func aEnvWithAnEmptyVarDumperFormatStillBlocksTheSite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try twoSiteEngine(in: root)
        try Data("VAR_DUMPER_FORMAT=\n".utf8).write(to: shop.appending(path: ".env"))

        try await whileRunning(engine) {
            await engine.startDumpReceiver()

            #expect(await engine.dumpList(place: nil).blocked.map(\.host) == ["shop.test"])
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realPHP)), .timeLimit(.minutes(1)))
    func aDumpOfARealPHPWithTheStubOfTheEngineReachesTheStoreWithItsSite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        try Data("<?php\n\ndump(['order' => 7]);\n".utf8).write(to: shop.appending(path: "dump.php"))
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: repository.appending(path: "NexusPHP/dumps", directoryHint: .isDirectory), to: library)
        try Data("0123456789ab\n".utf8).write(to: library.appending(path: NexusEngine.dumpLibraryHashFile))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")], dumpLibrarySource: library)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let written = await engine.writeDumpFiles(line: "8.5", state: await engine.stateStore.current(), keepingStub: false)
            let stub = try #require(written.stub)
            let php = Process()
            php.executableURL = URL(filePath: Self.realPHP)
            php.arguments = ["-n", "-d", "auto_prepend_file=\(stub.path(percentEncoded: false))", "dump.php"]
            php.currentDirectoryURL = shop
            php.environment = ["PATH": "/usr/bin:/bin"]
            php.standardOutput = FileHandle.nullDevice
            php.standardError = FileHandle.nullDevice
            try php.run()

            while php.isRunning {
                try await Task.sleep(for: .milliseconds(20))
            }

            let arrived = await eventually { await engine.dumpStore.list().first?.dumpCount == 1 }
            let request = try #require(await engine.dumpStore.list().first)
            let dumps = await engine.dumpStore.dumps(request: request.id)

            #expect(php.terminationStatus == 0)
            #expect(arrived)
            #expect(request.kind == .command)
            #expect(request.site == "shop.test")
            #expect(request.workspace == nil)
            #expect(dumps.first?.text.contains("\"order\" => 7") == true)
            #expect(dumps.first?.file == "\(RealPath.of(shop))/dump.php")
        }
    }

    @Test func aNewPageGetsTheListAndRemovesADumpOnlyWithTheToken() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state, servesDumpPage: true)

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            try await DumpWire.send([
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 1),
                DumpWire.dump("s1", host: "shop.test", root: RealPath.of(shop), seq: 2),
            ], to: engine)
            let arrived = await eventually { await engine.dumpStore.list().first?.dumpCount == 2 }
            let server = try #require(await engine.dumpPageServer)
            let dumpState = await engine.dumpState(place: nil, settings: DumpSettings())

            let events = try PageClient.events(port: server.port)
            defer { events.close() }
            var firstEvent: [String] = []

            while firstEvent.count < 2, let line = try events.readLine().map({ String(decoding: $0, as: UTF8.self) }) {
                if line.hasPrefix("event:") || !firstEvent.isEmpty {
                    firstEvent.append(line)
                }
            }

            let refused = try PageClient.post("/api/remove-dump", json: #"{"number":1}"#, port: server.port, token: "guess")
            let removed = try PageClient.post("/api/remove-dump", json: #"{"number":1}"#, port: server.port, token: server.token)
            let dumps = try PageClient.get("/api/dumps?request=s1", port: server.port)
            let unknown = try PageClient.get("/api/nothing", port: server.port)

            #expect(arrived)
            #expect(dumpState.page == "http://127.0.0.1:\(server.port)/")
            #expect(firstEvent.first == "event: list")
            #expect(firstEvent.last?.contains(#""id":"s1""#) == true)
            #expect(refused.status == 403)
            #expect(removed.status == 200)
            #expect(await engine.dumpStore.dumps(request: "s1").map(\.seq) == [2])
            #expect(dumps.status == 200)
            #expect(dumps.body.contains(#""seq":2"#))
            #expect(!dumps.body.contains(#""seq":1"#))
            #expect(unknown.status == 404)
        }
    }
}
