import Foundation
import NexusCore

// The XPC interface of nexusd. An app calls watch() once on its connection. nexusd then calls
// receive(_:) on the app with the current state, and again after each change.
@objc public protocol NexusDaemonXPCService: NexusXPCService {
    func watch()
}

@objc public protocol NexusEventReceiver {
    func receive(_ event: Data)
}

public enum NexusFeedUpdate: Sendable, Equatable {
    case event(NexusEvent)
    case unreachable(String)
    // nexusd answers, but the app cannot read the event. nexusd then has another version.
    case unreadable(String)
}

// Keeps one connection to nexusd open and gives each event of nexusd to the app. When nexusd
// stops, for example for an update, the feed connects again after the retry delay. launchd
// starts nexusd again for the watch message.
public final class NexusEventFeed: NSObject, NexusEventReceiver, @unchecked Sendable {
    public let updates: AsyncStream<NexusFeedUpdate>

    private let continuation: AsyncStream<NexusFeedUpdate>.Continuation
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let retryDelay: Duration
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var retrying = false
    private var closed = false

    public convenience init(serviceName: String = NexusIdentifiers.daemon) {
        self.init(retryDelay: .seconds(2)) {
            NSXPCConnection(machServiceName: serviceName, options: [])
        }
    }

    public init(retryDelay: Duration, makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        (updates, continuation) = AsyncStream.makeStream(of: NexusFeedUpdate.self)
        self.makeConnection = makeConnection
        self.retryDelay = retryDelay
    }

    public func start() {
        let connection: NSXPCConnection? = lock.withLock {
            guard connection == nil, !closed else {
                return nil
            }

            connection = makeConnection()
            return connection
        }

        if let connection {
            watch(on: connection)
        }
    }

    public func stop() {
        let current = lock.withLock {
            closed = true
            defer { connection = nil }
            return connection
        }

        current?.interruptionHandler = nil
        current?.invalidationHandler = nil
        current?.invalidate()
        continuation.finish()
    }

    public func receive(_ event: Data) {
        guard let decoded = try? NexusMessageCoding.decode(NexusEvent.self, from: event) else {
            continuation.yield(.unreadable("Nexus cannot read the state that nexusd sends. nexusd has probably another version than the app. Start nexusd again: launchctl kickstart -k gui/\(getuid())/\(NexusIdentifiers.daemon)"))
            return
        }

        continuation.yield(.event(decoded))
    }

    private func watch(on connection: NSXPCConnection) {
        connection.remoteObjectInterface = NSXPCInterface(with: NexusDaemonXPCService.self)
        connection.exportedInterface = NSXPCInterface(with: NexusEventReceiver.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.lost(connection, reason: "nexusd stopped.")
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.lost(connection, reason: "Nexus cannot connect to nexusd.")
        }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            self?.lost(connection, reason: error.localizedDescription)
        }
        (proxy as? NexusDaemonXPCService)?.watch()
    }

    // The error handler and the connection handlers can all report the same loss. Only the
    // first report of the current connection counts.
    private func lost(_ lostConnection: NSXPCConnection?, reason: String) {
        let retry = lock.withLock {
            guard !closed, !retrying, let lostConnection, lostConnection === connection else {
                return false
            }

            retrying = true
            return true
        }

        guard retry else {
            return
        }

        continuation.yield(.unreachable(reason))

        Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            self?.reconnect()
        }
    }

    private func reconnect() {
        let old = lock.withLock {
            retrying = false
            defer { connection = nil }
            return closed ? nil : connection
        }

        guard let old else {
            return
        }

        old.interruptionHandler = nil
        old.invalidationHandler = nil
        old.invalidate()
        start()
    }
}

// Sends the events of nexusd to each app that watches them. A watch ends with its connection.
public final class NexusEventWatchers: @unchecked Sendable {
    private let events: @Sendable () async -> AsyncStream<NexusEvent>
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(events: @escaping @Sendable () async -> AsyncStream<NexusEvent>) {
        self.events = events
    }

    // Call this in listener(_:shouldAcceptNewConnection:), before the connection resumes.
    public func prepare(_ connection: NSXPCConnection) {
        let key = ObjectIdentifier(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: NexusEventReceiver.self)
        connection.invalidationHandler = { [weak self] in
            self?.end(key)
        }
    }

    // Call this in watch(). Only there NSXPCConnection.current() names the connection.
    public func watchCurrentConnection() {
        guard let connection = NSXPCConnection.current(),
              let receiver = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? NexusEventReceiver else {
            return
        }

        let box = ReceiverBox(receiver: receiver)
        let events = events
        let task = Task {
            for await event in await events() {
                guard let data = try? NexusMessageCoding.encode(event) else {
                    continue
                }

                box.receiver.receive(data)
            }
        }

        let previous = lock.withLock {
            defer { tasks[ObjectIdentifier(connection)] = task }
            return tasks[ObjectIdentifier(connection)]
        }
        previous?.cancel()
    }

    private func end(_ key: ObjectIdentifier) {
        lock.withLock { tasks.removeValue(forKey: key) }?.cancel()
    }
}

// An XPC proxy is safe to use from any thread.
private struct ReceiverBox: @unchecked Sendable {
    let receiver: any NexusEventReceiver
}
