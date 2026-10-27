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
}
