import Darwin
import Dispatch
import Foundation
import NexusCore
import Synchronization

// The port of a stopped workspace server (plan item 3e, owner 2026-11-15, way 1 of research 5).
// nexusd holds 127.0.0.1:<port> while the server is stopped. The first new connection asks for a
// start. During a start or a stop a second listener on all addresses takes the new connections,
// because the server binds 127.0.0.1 next to it. macOS gives a new loopback connection to the
// listener on 127.0.0.1. So the gate passes on only the connections of that moment, and nexusd is
// not between the client and a server that runs.
public final class PortGate: Sendable {
    public enum Wire: Sendable, Equatable {
        case mysql
        case postgresql
    }

    public enum Phase: Sendable, Equatable {
        case held
        case wake
        case handOver
        case takeBack
    }

    // A failed start answers new connections with its reason for this time. So a second try of a
    // client does not start the server again at once.
    public static let failurePause: Duration = .seconds(2)
    static let relayBufferSize = 256 * 1024
    static let answerTimeout: TimeInterval = 5
    // The bytes that a client can send after the reply before the gate closes.
    static let drainLimit = 65_536

    private struct Listener: @unchecked Sendable {
        let descriptor: Int32
        let port: Int
        let isWildcard: Bool
        let source: any DispatchSourceRead
        let closed: Closed
    }

    // The cancel handler of a listener signals it after the close of the socket. A wait for it ends
    // only then, also in a task that got a cancel. So the port is free when the wait ends.
    private final class Closed: Sendable {
        private let state = Mutex<(isClosed: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

        func signal() {
            let waiter = state.withLock { state in
                state.isClosed = true
                defer { state.waiter = nil }
                return state.waiter
            }

            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { waiter in
                let isClosed = state.withLock { state in
                    if !state.isClosed {
                        state.waiter = waiter
                    }

                    return state.isClosed
                }

                if isClosed {
                    waiter.resume()
                }
            }
        }
    }

    private struct Failure: Sendable {
        let reason: String
        let until: ContinuousClock.Instant
    }

    // passOn and answer exist only while a public call closes the listener on all addresses. Each
    // connection in its queue then goes to the server or gets the reason.
    private enum State: Sendable {
        case held(Listener, failure: Failure?)
        case wake(Listener, [Int32])
        case handOver(Listener?, [Int32])
        case takeBack(Listener?, [Int32])
        case passOn
        case answer(String)
    }

    private struct Gated: Sendable {
        let wire: Wire
        var state: State
    }

    private enum Admission {
        case close
        case answer(String, Wire)
        case checkCancel
        case wake
        case keep
        case passOn
    }

    private enum Start {
        case closed
        case cancel(length: Int)
        case other
    }

    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.port-gate")
    private let ports = Mutex<[Int: Gated]>([:])
    private let wakeHandler = Mutex<(@Sendable (Int) -> Void)?>(nil)

    public init() {}

    // The handler runs on the queue of the gate or on a thread of a connection. It must only start a
    // Task.
    public func onWake(_ handler: @escaping @Sendable (Int) -> Void) {
        wakeHandler.withLock { $0 = handler }
    }

    public func phase(of port: Int) -> Phase? {
        ports.withLock { ports in
            switch ports[port]?.state {
            case .held, .answer: .held
            case .wake: .wake
            case .handOver, .passOn: .handOver
            case .takeBack: .takeBack
            case nil: nil
            }
        }
    }

    public func isHeld(_ port: Int) -> Bool {
        phase(of: port) != nil
    }

    // Binds 127.0.0.1 one time. Throws SocketError when the bind fails, and the port then has no
    // phase. A port with a phase stays as it is.
    public func hold(_ port: Int, wire: Wire) throws {
        guard !isHeld(port) else {
            return
        }

        let listener = try open(port, host: IPv4Socket.loopback)

        ports.withLock { ports in
            ports[port] = Gated(wire: wire, state: .held(listener, failure: nil))
        }
    }

    // Opens the listener on all addresses. Then each connection in the queue of the 127.0.0.1
    // listener gets its place, and that listener closes. So the server can bind 127.0.0.1. A failed
    // bind on all addresses leaves no listener for that time, and the server binds anyway. Returns
    // false when the port has no phase for a start. A listener that just closed can keep its port
    // for some milliseconds (PortInspector.becomesFree). So the caller waits until 127.0.0.1 is free
    // before the start of the server. That wait does not block the thread of the caller.
    @discardableResult
    public func beginHandOver(_ port: Int) async -> Bool {
        switch phase(of: port) {
        case .handOver:
            return true
        case .held, .wake:
            break
        case .takeBack, nil:
            return false
        }

        let wildcard = try? open(port, host: INADDR_ANY)

        let loopback = ports.withLock { ports -> Listener? in
            guard var gated = ports[port] else {
                return nil
            }

            let loopback: Listener

            switch gated.state {
            case .held(let listener, _):
                loopback = listener
                gated.state = .handOver(wildcard, [])
            case .wake(let listener, let connections):
                loopback = listener
                gated.state = .handOver(wildcard, connections)
            default:
                return nil
            }

            ports[port] = gated
            return loopback
        }

        guard let loopback else {
            await close(wildcard, draining: false)
            return phase(of: port) == .handOver
        }

        await close(loopback, draining: true)
        return true
    }

    // The server takes connections on 127.0.0.1 now. Each connection of the start goes to it, and
    // the listener on all addresses closes. A new loopback connection goes to the server itself.
    public func finishHandOver(_ port: Int) async {
        let taken = ports.withLock { ports -> (Listener?, [Int32])? in
            guard var gated = ports[port], case .handOver(let listener, let connections) = gated.state else {
                return nil
            }

            gated.state = .passOn
            ports[port] = gated
            return (listener, connections)
        }

        guard let (listener, connections) = taken else {
            return
        }

        connections.forEach { Self.relay($0, to: port) }
        await close(listener, draining: true)
        removeTransient(port)
    }

    // The start failed. Each connection of the start gets the reason. With holdsAgain the gate binds
    // 127.0.0.1 again and answers new connections with the reason for the failure pause. When that
    // bind fails, the port has no phase and the call throws.
    public func failHandOver(_ port: Int, reason: String, holdsAgain: Bool) async throws {
        guard phase(of: port) == .handOver else {
            return
        }

        var problem: (any Error)?
        var loopback: Listener?

        if holdsAgain {
            do {
                loopback = try open(port, host: IPv4Socket.loopback)
            } catch {
                problem = error
            }
        }

        let failure = Failure(reason: reason, until: .now + Self.failurePause)
        let taken = ports.withLock { ports -> (Listener?, [Int32], Wire)? in
            guard var gated = ports[port], case .handOver(let wildcard, let connections) = gated.state else {
                return nil
            }

            gated.state = loopback.map { .held($0, failure: failure) } ?? .answer(reason)
            ports[port] = gated
            return (wildcard, connections, gated.wire)
        }

        guard let (wildcard, connections, wire) = taken else {
            await close(loopback, draining: false)
            return
        }

        connections.forEach { Self.answer($0, reason: reason, wire: wire) }
        await close(wildcard, draining: true)
        removeTransient(port)

        if let problem {
            throw problem
        }
    }

    // The start of the phase wake did not come. Each connection gets the reason, and the next
    // connection asks for a start again.
    public func refuse(_ port: Int, reason: String) {
        let taken = ports.withLock { ports -> ([Int32], Wire)? in
            guard var gated = ports[port], case .wake(let listener, let connections) = gated.state else {
                return nil
            }

            gated.state = .held(listener, failure: nil)
            ports[port] = gated
            return (connections, gated.wire)
        }

        guard let (connections, wire) = taken else {
            return
        }

        connections.forEach { Self.answer($0, reason: reason, wire: wire) }
    }

    // Opens the listener on all addresses next to the server before its stop. The server closes its
    // listener at the start of its stop, so the new connections wait in this listener. A stop during
    // a hand-over keeps the connections of that start. Returns false for a port in another phase.
    @discardableResult
    public func beginTakeBack(_ port: Int, wire: Wire) async -> Bool {
        switch phase(of: port) {
        case .handOver:
            return ports.withLock { ports in
                guard var gated = ports[port], case .handOver(let listener, let connections) = gated.state else {
                    return false
                }

                gated.state = .takeBack(listener, connections)
                ports[port] = gated
                return true
            }
        case nil:
            break
        case .held, .wake, .takeBack:
            return false
        }

        let wildcard = try? open(port, host: INADDR_ANY)

        let added = ports.withLock { ports in
            guard ports[port] == nil else {
                return false
            }

            ports[port] = Gated(wire: wire, state: .takeBack(wildcard, []))
            return true
        }

        if !added {
            await close(wildcard, draining: false)
        }

        return added
    }

    // The server stopped. Binds 127.0.0.1 one time, and the listener on all addresses closes. With
    // connections of the stop the phase is wake, and the wake handler runs. When the bind fails the
    // call throws, and the phase stays takeBack. So the caller can try again.
    public func finishTakeBack(_ port: Int) async throws {
        guard phase(of: port) == .takeBack else {
            return
        }

        let loopback = try open(port, host: IPv4Socket.loopback)

        let taken = ports.withLock { ports -> (Listener?, Bool)? in
            guard var gated = ports[port], case .takeBack(let wildcard, let connections) = gated.state else {
                return nil
            }

            gated.state = connections.isEmpty ? .held(loopback, failure: nil) : .wake(loopback, connections)
            ports[port] = gated
            return (wildcard, !connections.isEmpty)
        }

        guard let (wildcard, wakes) = taken else {
            await close(loopback, draining: false)
            return
        }

        if wakes {
            wakeHandler.withLock { $0 }?(port)
        }

        await close(wildcard, draining: true)
    }

    // Closes the listeners and the connections of the port.
    public func release(_ port: Int) async {
        guard let state = ports.withLock({ $0.removeValue(forKey: port)?.state }) else {
            return
        }

        let (listeners, connections) = Self.parts(of: state)

        connections.forEach { Darwin.close($0) }

        for listener in listeners {
            await close(listener, draining: false)
        }
    }

    // Each connection gets the reason, and all listeners close.
    public func releaseAll(reason: String) async {
        let all = ports.withLock { ports -> [(port: Int, gated: Gated)] in
            let all = ports.map { (port: $0.key, gated: $0.value) }

            for (port, gated) in all {
                ports[port] = Gated(wire: gated.wire, state: .answer(reason))
            }

            return all
        }

        for (port, gated) in all {
            let (listeners, connections) = Self.parts(of: gated.state)

            connections.forEach { Self.answer($0, reason: reason, wire: gated.wire) }

            for listener in listeners {
                await close(listener, draining: true)
            }

            removeTransient(port)
        }
    }

    // MARK: Listeners

    // The listener does not block, so an accept can empty its queue.
    static func listener(on port: Int, host: in_addr_t) throws -> Int32 {
        let descriptor = try IPv4Socket.listener(on: port, host: host, backlog: SOMAXCONN)

        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    private func open(_ port: Int, host: in_addr_t) throws -> Listener {
        let descriptor = try Self.listener(on: port, host: host)
        let isWildcard = host == INADDR_ANY
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let closed = Closed()

        source.setEventHandler { [weak self] in
            self?.acceptAll(on: descriptor, port: port, isWildcard: isWildcard)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
            closed.signal()
        }
        source.resume()

        return Listener(descriptor: descriptor, port: port, isWildcard: isWildcard, source: source, closed: closed)
    }

    // Only the public calls close a listener. The callers are actors on the cooperative thread pool,
    // and an accept on the queue of the gate can pause for a free descriptor. So the drain and the
    // cancel run on that queue, and the caller waits without a blocked thread. With draining, each
    // connection in the queue of the listener gets its place first. The port is free when this call
    // returns.
    private func close(_ listener: Listener?, draining: Bool) async {
        guard let listener else {
            return
        }

        queue.async { [self] in
            if draining {
                acceptAll(on: listener.descriptor, port: listener.port, isWildcard: listener.isWildcard)
            }

            listener.source.cancel()
        }

        await listener.closed.wait()
    }

    private func removeTransient(_ port: Int) {
        ports.withLock { ports in
            switch ports[port]?.state {
            case .passOn, .answer: ports[port] = nil
            default: break
            }
        }
    }

    private func acceptAll(on descriptor: Int32, port: Int, isWildcard: Bool) {
        while true {
            let client = accept(descriptor, nil, nil)

            guard client >= 0 else {
                if errno == EINTR {
                    continue
                }

                // Without a free descriptor the source fires again at once. A short pause keeps the
                // queue out of a loop at full speed, as in LoopbackListener.
                if errno == EMFILE || errno == ENFILE {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                return
            }

            Self.prepare(client)

            // The servers bind only 127.0.0.1. So a connection to another address comes from the
            // network, and it gets a reset at once.
            if isWildcard, !Self.goesToLoopback(client) {
                Self.reset(client)
                continue
            }

            admit(client, port: port, checked: false)
        }
    }

    private func admit(_ client: Int32, port: Int, checked: Bool) {
        let admission = ports.withLock { ports -> Admission in
            guard var gated = ports[port] else {
                return .close
            }

            switch gated.state {
            case .held(let listener, let failure):
                if let failure, ContinuousClock.now < failure.until {
                    return .answer(failure.reason, gated.wire)
                }

                if gated.wire == .postgresql, !checked {
                    return .checkCancel
                }

                gated.state = .wake(listener, [client])
                ports[port] = gated
                return .wake
            case .wake(let listener, let connections):
                gated.state = .wake(listener, connections + [client])
            case .handOver(let listener, let connections):
                gated.state = .handOver(listener, connections + [client])
            case .takeBack(let listener, let connections):
                gated.state = .takeBack(listener, connections + [client])
            case .passOn:
                return .passOn
            case .answer(let reason):
                return .answer(reason, gated.wire)
            }

            ports[port] = gated
            return .keep
        }

        switch admission {
        case .close:
            Darwin.close(client)
        case .answer(let reason, let wire):
            Self.answer(client, reason: reason, wire: wire)
        case .checkCancel:
            Thread.detachNewThread { [self] in
                checkCancel(client, port: port)
            }
        case .wake:
            wakeHandler.withLock { $0 }?(port)
        case .keep:
            break
        case .passOn:
            Self.relay(client, to: port)
        }
    }

    // A cancel request names the PID and the key of a session. A held port has no session, so a
    // cancel request starts nothing. The phase can change during the read, so the connection then
    // gets its place again.
    private func checkCancel(_ client: Int32, port: Int) {
        switch Self.peekStart(client) {
        case .closed:
            Darwin.close(client)
        case .cancel(let length):
            _ = try? LineSocket(descriptor: client, timeout: Self.answerTimeout).read(count: length)
            Darwin.close(client)
        case .other:
            admit(client, port: port, checked: true)
        }
    }

    private static func peekStart(_ client: Int32) -> Start {
        let deadline = Date.now.addingTimeInterval(answerTimeout)
        var head = [UInt8](repeating: 0, count: 8)

        while true {
            let remaining = deadline.timeIntervalSinceNow

            guard remaining > 0 else {
                return .other
            }

            var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(remaining * 1000) + 1)

            if ready < 0, errno == EINTR {
                continue
            }

            guard ready > 0 else {
                return .other
            }

            let count = recv(client, &head, head.count, MSG_PEEK)

            if count < 0, errno == EINTR {
                continue
            }

            guard count > 0 else {
                return .closed
            }

            guard count == head.count else {
                usleep(5_000)
                continue
            }

            if case .cancelRequest(let length) = PortRefusal.postgreSQLStart(Data(head)) {
                return .cancel(length: length)
            }

            return .other
        }
    }

    private static func parts(of state: State) -> (listeners: [Listener], connections: [Int32]) {
        switch state {
        case .held(let listener, _): ([listener], [])
        case .wake(let listener, let connections): ([listener], connections)
        case .handOver(let listener, let connections), .takeBack(let listener, let connections): (listener.map { [$0] } ?? [], connections)
        case .passOn, .answer: ([], [])
        }
    }

    // MARK: Connections

    // An accepted socket gets the O_NONBLOCK of its listener on macOS.
    private static func prepare(_ descriptor: Int32) {
        var on: Int32 = 1
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func goesToLoopback(_ descriptor: Int32) -> Bool {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let found = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }

        return found == 0 && Int32(local.sin_family) == AF_INET && local.sin_addr.s_addr == IPv4Socket.loopback
    }

    private static func reset(_ descriptor: Int32) {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        Darwin.close(descriptor)
    }

    // Each direction has its own thread with blocking calls and no timeout, as LoopbackListener
    // serves. A connection of the start can stay open for hours, for example in a database app.
    private static func relay(_ client: Int32, to port: Int) {
        Thread.detachNewThread {
            guard let server = try? IPv4Socket.connectToLoopback(port: port) else {
                Darwin.close(client)
                return
            }

            var on: Int32 = 1

            for descriptor in [client, server] {
                setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            }

            let back = DispatchSemaphore(value: 0)

            Thread.detachNewThread {
                copy(from: server, to: client)
                back.signal()
            }

            copy(from: client, to: server)
            back.wait()
            Darwin.close(client)
            Darwin.close(server)
        }
    }

    // The end of one direction ends the writes of the other socket. A reply can still come back.
    private static func copy(from source: Int32, to target: Int32) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: relayBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        copying: while true {
            let count = recv(source, buffer, relayBufferSize, 0)

            if count < 0, errno == EINTR {
                continue
            }

            guard count > 0 else {
                break
            }

            var offset = 0

            while offset < count {
                let written = send(target, buffer + offset, count - offset, 0)

                if written < 0, errno == EINTR {
                    continue
                }

                guard written > 0 else {
                    break copying
                }

                offset += written
            }
        }

        shutdown(target, SHUT_WR)
    }

    private static func answer(_ client: Int32, reason: String, wire: Wire) {
        Thread.detachNewThread {
            let socket = LineSocket(descriptor: client, timeout: answerTimeout)

            switch wire {
            case .mysql:
                try? socket.write(PortRefusal.mysqlErrorPacket(reason))
            case .postgresql:
                answerPostgreSQL(socket, reason: reason)
            }

            closeAfterReply(client)
        }
    }

    // An SSLRequest or a GSSENCRequest gets N, and the next message follows. A startup message gets
    // the error. A cancel request gets no answer.
    private static func answerPostgreSQL(_ socket: LineSocket, reason: String) {
        for _ in 0..<3 {
            guard let head = try? socket.read(count: 8) else {
                return
            }

            switch PortRefusal.postgreSQLStart(head) {
            case .sslRequest, .encryptionRequest:
                guard (try? socket.write(Data("N".utf8))) != nil else {
                    return
                }
            case .cancelRequest(let length):
                _ = try? socket.read(count: length - 8)
                return
            case .startup(let length):
                guard (try? socket.read(count: length - 8)) != nil else {
                    return
                }

                try? socket.write(PortRefusal.postgreSQLErrorResponse(reason))
                return
            case .tooLong:
                return
            }
        }
    }

    // A close with bytes that nobody read sends a reset, and the client can lose the reply. So the
    // gate reads until the client closes.
    private static func closeAfterReply(_ client: Int32) {
        shutdown(client, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var total = 0

        while total < drainLimit {
            let count = recv(client, &buffer, buffer.count, 0)

            guard count > 0 else {
                break
            }

            total += count
        }

        Darwin.close(client)
    }
}
