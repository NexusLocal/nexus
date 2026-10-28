import Foundation
import NexusIPC
import NexusSupervisor
import Testing

// A daemon on an anonymous listener in the test process. It sends one event to each watcher.
private final class TestDaemon: NSObject, NSXPCListenerDelegate, NexusDaemonXPCService, @unchecked Sendable {
    private let watchers: NexusEventWatchers
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    init(event: NexusEvent) {
        watchers = NexusEventWatchers {
            AsyncStream { $0.yield(event) }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NexusDaemonXPCService.self)
        connection.exportedObject = self
        watchers.prepare(connection)
        lock.withLock { connections.append(connection) }
        connection.resume()
        return true
    }

    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        reply(Data())
    }

    func watch() {
        watchers.watchCurrentConnection()
    }

    func dropConnections() {
        let dropped = lock.withLock {
            defer { connections = [] }
            return connections
        }

        dropped.forEach { $0.invalidate() }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct NexusEventFeedTests {
    private let event = NexusEvent.services(ServiceList(
        services: [ServiceInfo(id: "redis-8.2", name: "redis", line: "8.2", version: "8.2.3", ports: [16379], state: .stopped)],
        stoppedByStopAll: []
    ))

    private func makeFeed(_ daemon: TestDaemon) -> (NexusEventFeed, NSXPCListener) {
        let listener = NSXPCListener.anonymous()
        listener.delegate = daemon
        listener.resume()

        let endpoint = listener.endpoint
        let feed = NexusEventFeed(retryDelay: .milliseconds(50)) {
            NSXPCConnection(listenerEndpoint: endpoint)
        }
        return (feed, listener)
    }

    @Test func aWatcherGetsTheEventsOfTheDaemon() async {
        let daemon = TestDaemon(event: event)
        let (feed, listener) = makeFeed(daemon)
        var updates = feed.updates.makeAsyncIterator()

        feed.start()
        let first = await updates.next()

        #expect(first == .event(event))
        feed.stop()
        listener.invalidate()
    }

    @Test func theFeedConnectsAgainWhenTheDaemonDropsTheConnection() async {
        let daemon = TestDaemon(event: event)
        let (feed, listener) = makeFeed(daemon)
        var updates = feed.updates.makeAsyncIterator()

        feed.start()
        let first = await updates.next()
        daemon.dropConnections()
        let lost = await updates.next()
        let again = await updates.next()

        #expect(first == .event(event))
        if case .unreachable = lost {} else { Issue.record("no loss reported: \(String(describing: lost))") }
        #expect(again == .event(event))
        feed.stop()
        listener.invalidate()
    }

    // A nexusd of part 6c sends this. A new key that is not optional makes this test fail.
    @Test func anEventOfTheNexusdOfPart6cStillReads() throws {
        let old = #"""
            {"services":{"_0":{"services":[
                {"id":"mysql-8.0","name":"mysql","line":"8.0","version":"8.0.46","ports":[13306],
                 "state":{"running":{"pid":2442,"since":"2026-10-28T07:00:00Z"}},
                 "logFile":"/logs/mysql-8.0.log","dataFolder":"/data/mysql-8.0","account":{"user":"root","password":"root"}},
                {"id":"dns","name":"dns","line":"","version":"","ports":[10053],"state":{"stopped":{}}}
            ],"stoppedByStopAll":["redis-8.2"]}}}
            """#
        let toggle = #"{"name":"xdebug","enabled":false,"required":false}"#
        let site = #"""
            {"hosts":["shop.test"],"folder":"/Sites/shop","documentRoot":"/Sites/shop/public","php":"8.5",
             "server":"nginx","parked":true,"url":"https://shop.test"}
            """#

        let event = try NexusMessageCoding.decode(NexusEvent.self, from: Data(old.utf8))
        let oldToggle = try NexusMessageCoding.decode(Toggle.self, from: Data(toggle.utf8))
        let oldSite = try NexusMessageCoding.decode(SiteInfo.self, from: Data(site.utf8))

        guard case .services(let list) = event else {
            Issue.record("no service list")
            return
        }
        #expect(list.services.map(\.id) == ["mysql-8.0", "dns"])
        #expect(list.services.first?.toggles == nil)
        #expect(list.lanAccess == nil)
        #expect(oldToggle.help == nil)
        #expect(oldSite.group == nil)
        #expect(oldSite.parkedFolder == nil)
        #expect(oldSite.problem == nil)
    }

    // An app of part 6e sends the group. An app before it does not.
    @Test func anAddSiteRequestWithoutAGroupStillReads() throws {
        let old = #"{"addSite":{"folder":"/Sites/shop","aliases":[],"php":"8.5"}}"#

        let request = try NexusMessageCoding.decode(NexusRequest.self, from: Data(old.utf8))

        #expect(request == .addSite(folder: "/Sites/shop", host: nil, aliases: [], php: "8.5", server: nil, group: nil))
    }

    @Test func anEventThatTheAppCannotReadShowsAProblem() async {
        let feed = NexusEventFeed(retryDelay: .milliseconds(50)) { NSXPCConnection() }
        var updates = feed.updates.makeAsyncIterator()

        feed.receive(Data("{}".utf8))
        let update = await updates.next()

        if case .unreadable(let reason) = update {
            #expect(reason.contains("another version"))
        } else {
            Issue.record("no problem reported: \(String(describing: update))")
        }
        feed.stop()
    }
}
