import Darwin
import Foundation
import NexusCore
import Synchronization
import Testing
@testable import NexusSupervisor

private final class FakeServer: Sendable {
    let port: Int
    private let listener: Int32
    private let stopped = Mutex(false)
    private let payloads = Mutex<[String]>([])
    private let peerPorts = Mutex<[Int]>([])

    init(port: Int) throws {
        self.port = port
        listener = try PortGate.listener(on: port, host: inet_addr("127.0.0.1"))

        Thread.detachNewThread { [self] in
            serve()
        }
    }

    var received: [String] {
        payloads.withLock { $0 }
    }

    var peers: [Int] {
        peerPorts.withLock { $0 }
    }

    func stop() {
        stopped.withLock { $0 = true }
        usleep(150_000)
        close(listener)
    }

    private func serve() {
        while !stopped.withLock({ $0 }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)

            guard poll(&poller, 1, 50) > 0 else {
                continue
            }

            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }

            guard client >= 0 else {
                continue
            }

            peerPorts.withLock { $0.append(Int(UInt16(bigEndian: peer.sin_port))) }

            Thread.detachNewThread { [self] in
                answer(client)
            }
        }
    }

    private func answer(_ client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        PortGateTests.setTimeout(client, seconds: 2)
        PortGateTests.send(client, Array("hello".utf8))

        let payload = PortGateTests.read(client, count: 2)

        if !payload.isEmpty {
            payloads.withLock { $0.append(String(decoding: payload, as: UTF8.self)) }
        }

        usleep(200_000)
        close(client)
    }
}

private final class PortList: Sendable {
    static let givenPorts = PortList()

    private let ports = Mutex<[Int]>([])

    var all: [Int] {
        ports.withLock { $0 }
    }

    func record(_ port: Int) {
        ports.withLock { $0.append(port) }
    }

    func claim(_ port: Int) -> Bool {
        ports.withLock { ports in
            guard !ports.contains(port) else {
                return false
            }

            ports.append(port)
            return true
        }
    }
}

struct PortGateTests {
    private let wakes = PortList()

    private func gate() -> PortGate {
        let gate = PortGate()
        gate.onWake { [wakes] port in
            wakes.record(port)
        }
        return gate
    }

    private var woken: [Int] {
        wakes.all
    }

    // A port that no other test of this run got. It is above the ports of Nexus and Nexus Dev, and
    // below the ports that macOS gives to outgoing connections (49152 and higher). So no other
    // program gets the port after a close in a test. freePortAboveNexus of the engine tests uses
    // 48001 to 49000. A probe socket on the port can keep it for some milliseconds after its close,
    // so the caller binds the port itself and tries another port when that fails.
    static func freePort() -> Int {
        while true {
            let port = Int.random(in: 47_001...48_000)

            if PortList.givenPorts.claim(port) {
                return port
            }
        }
    }

    static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var interval = timeval(tv_sec: seconds, tv_usec: 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func send(_ descriptor: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, bytes.count, 0) }
    }

    // Reads until count bytes, the end of the connection, a reset or the timeout.
    static func read(_ descriptor: Int32, count: Int) -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < count {
            let received = recv(descriptor, &buffer, min(buffer.count, count - data.count), 0)

            guard received > 0 else {
                break
            }

            data += buffer.prefix(received)
        }

        return data
    }

    private func client(_ port: Int) throws -> Int32 {
        let descriptor = connection(to: port, address: inet_addr("127.0.0.1"))
        try #require(descriptor >= 0)
        return descriptor
    }

    private func connection(to port: Int, address: in_addr_t) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        Self.setTimeout(descriptor, seconds: 5)
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(UInt16(port).bigEndian)
        target.sin_addr = in_addr(s_addr: address)

        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        guard connected == 0 else {
            close(descriptor)
            return -1
        }

        return descriptor
    }

    private func localPort(of descriptor: Int32) -> Int {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return Int(UInt16(bigEndian: local.sin_port))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)

        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return false
    }

    private func startupMessage() -> [UInt8] {
        let body: [UInt8] = [0x00, 0x03, 0x00, 0x00] + Array("user\0shop\0\0".utf8)
        let length = UInt32(body.count + 4)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + body
    }

    // The other tests of this process connect at the same time. A connection can take a free port
    // as its own port before the bind of the test.
    private func heldPort(_ gate: PortGate, wire: PortGate.Wire = .mysql) throws -> Int {
        try #require((0..<20).lazy.map { _ in Self.freePort() }.first { (try? gate.hold($0, wire: wire)) != nil })
    }

    // The engine tries the bind of a take back again for 1 second, because a socket that just
    // closed can keep its port for some milliseconds.
    private func finishTakeBack(_ gate: PortGate, _ port: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)

        while true {
            do {
                return try await gate.finishTakeBack(port)
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw error
                }

                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    // The engine waits until the server can bind 127.0.0.1, as WorkspacePortGate.serverWillStart does.
    private func beginHandOver(_ gate: PortGate, _ port: Int) async {
        await gate.beginHandOver(port)
        _ = await PortInspector.becomesFree(port, on: inet_addr("127.0.0.1"))
    }

    private func fakeServer() throws -> FakeServer {
        try #require((0..<20).firstNonNil { _ in try? FakeServer(port: Self.freePort()) })
    }

    @Test func aHeldPortIsNotFreeUntilItsRelease() async throws {
        let gate = gate()
        let port = try heldPort(gate)

        #expect(gate.isHeld(port))
        #expect(gate.phase(of: port) == .held)
        #expect(!PortInspector.isFree(port))

        await gate.release(port)

        #expect(!gate.isHeld(port))
        #expect(await eventually { !PortInspector.acceptsConnections(port) })
    }

    @Test func threeConnectionsAtTheSameMomentGiveOneWake() async throws {
        let gate = gate()
        let port = try heldPort(gate)
        defer { await gate.release(port) }

        let clients = try (0..<3).map { _ in try client(port) }
        defer { clients.forEach { close($0) } }

        #expect(await eventually { woken == [port] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(woken == [port])
        #expect(gate.phase(of: port) == .wake)
    }

    @Test func aHandOverGivesEachClientOfTheStartTheServerAndItsOwnBytes() async throws {
        let gate = gate()
        let port = try heldPort(gate)
        defer { await gate.release(port) }

        let clients = try (0..<3).map { _ in try client(port) }
        defer { clients.forEach { close($0) } }

        for (index, client) in clients.enumerated() {
            Self.send(client, Array("c\(index)".utf8))
        }

        #expect(await eventually { woken == [port] })
        try await Task.sleep(for: .milliseconds(100))

        await beginHandOver(gate, port)
        let server = try FakeServer(port: port)
        defer { server.stop() }
        await gate.finishHandOver(port)

        for client in clients {
            #expect(Self.read(client, count: 5) == Array("hello".utf8))
        }

        #expect(await eventually { server.received.count == 3 })
        #expect(Set(server.received) == ["c0", "c1", "c2"])
        #expect(!gate.isHeld(port))
    }

    @Test func aClientAfterTheHandOverReachesTheServerItself() async throws {
        let gate = gate()
        let port = try heldPort(gate)

        await beginHandOver(gate, port)
        let server = try FakeServer(port: port)
        defer { server.stop() }
        await gate.finishHandOver(port)

        let late = try client(port)
        defer { close(late) }

        #expect(Self.read(late, count: 5) == Array("hello".utf8))
        #expect(server.peers.contains(localPort(of: late)))
    }

    @Test func aFailedHandOverGivesTheMySQLErrorAndHoldsThePortForThePause() async throws {
        let gate = gate()
        let port = try heldPort(gate)
        let error = [UInt8](PortRefusal.mysqlErrorPacket("Stopped."))
        defer { await gate.release(port) }

        let clients = try (0..<2).map { _ in try client(port) }
        defer { clients.forEach { close($0) } }

        #expect(await eventually { woken == [port] })
        try await Task.sleep(for: .milliseconds(100))

        await beginHandOver(gate, port)
        try await gate.failHandOver(port, reason: "Stopped.", holdsAgain: true)

        for client in clients {
            #expect(Self.read(client, count: error.count + 1) == error)
        }

        #expect(gate.phase(of: port) == .held)

        let early = try client(port)
        defer { close(early) }

        #expect(Self.read(early, count: error.count + 1) == error)
        #expect(woken == [port])

        try await Task.sleep(for: PortGate.failurePause + .milliseconds(200))
        let later = try client(port)
        defer { close(later) }

        #expect(await eventually { woken == [port, port] })
    }

    @Test func aFailedHandOverAnswersAPostgreSQLClientAfterItsStartupMessage() async throws {
        let gate = gate()
        let port = try heldPort(gate, wire: .postgresql)
        defer { await gate.release(port) }

        let psql = try client(port)
        defer { close(psql) }

        Self.send(psql, [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F])
        #expect(await eventually { woken == [port] })

        await gate.beginHandOver(port)
        try await gate.failHandOver(port, reason: "Stopped.", holdsAgain: false)

        #expect(Self.read(psql, count: 1) == Array("N".utf8))

        Self.send(psql, startupMessage())
        let error = [UInt8](PortRefusal.postgreSQLErrorResponse("Stopped."))

        #expect(Self.read(psql, count: error.count + 1) == error)
        #expect(!gate.isHeld(port))
    }

    @Test func aFailedHandOverAnswersTheHelloOfAMongoDBClient() async throws {
        let gate = gate()
        let port = try heldPort(gate, wire: .mongodb)
        defer { await gate.release(port) }

        let mongo = try client(port)
        defer { close(mongo) }

        let body = Array(repeating: UInt8(0), count: 5) + [5, 0, 0, 0, 0]
        Self.send(mongo, PortRefusalTests.mongoDBHeader(length: Int32(16 + body.count), id: 9, operation: 2013) + body)
        #expect(await eventually { woken == [port] })

        await gate.beginHandOver(port)
        try await gate.failHandOver(port, reason: "Stopped.", holdsAgain: false)

        let reply = [UInt8](PortRefusal.mongoDBErrorReply("Stopped.", to: .message(id: 9, length: 16 + body.count)) ?? Data())

        #expect(Self.read(mongo, count: reply.count + 1) == reply)
        #expect(!gate.isHeld(port))
    }

    @Test func aRefusalAnswersTheClientsAndTheNextConnectionWakesAgain() async throws {
        let gate = gate()
        let port = try heldPort(gate)
        let error = [UInt8](PortRefusal.mysqlErrorPacket("No."))
        defer { await gate.release(port) }

        let first = try client(port)
        defer { close(first) }
        #expect(await eventually { woken == [port] })

        gate.refuse(port, reason: "No.")

        #expect(Self.read(first, count: error.count + 1) == error)
        #expect(gate.phase(of: port) == .held)

        let second = try client(port)
        defer { close(second) }

        #expect(await eventually { woken == [port, port] })
    }

    @Test func aCancelRequestToAHeldPostgreSQLPortStartsNothing() async throws {
        let gate = gate()
        let port = try heldPort(gate, wire: .postgresql)
        defer { await gate.release(port) }

        let cancel = try client(port)
        defer { close(cancel) }

        Self.send(cancel, [0, 0, 0, 16, 0x04, 0xD2, 0x16, 0x2E, 0, 0, 0x30, 0x39, 0, 0, 0, 7])

        #expect(Self.read(cancel, count: 1).isEmpty)
        #expect(woken.isEmpty)
        #expect(gate.phase(of: port) == .held)
    }

    @Test func aConnectionDuringAStopWakesAfterTheTakeBack() async throws {
        let gate = gate()
        let server = try fakeServer()
        let port = server.port

        #expect(await gate.beginTakeBack(port, wire: .mysql))
        server.stop()

        #expect(await eventually { !PortInspector.isInUse(port, address: inet_addr("127.0.0.1")) })

        let waiting = try client(port)
        defer { close(waiting) }

        try await Task.sleep(for: .milliseconds(100))
        try await finishTakeBack(gate, port)
        defer { await gate.release(port) }

        #expect(await eventually { woken == [port] })
        #expect(gate.phase(of: port) == .wake)
    }

    @Test func aTakeBackWithoutConnectionsHoldsThePort() async throws {
        let gate = gate()
        let port = try heldPort(gate)

        await gate.beginHandOver(port)
        #expect(await gate.beginTakeBack(port, wire: .mysql))
        try await finishTakeBack(gate, port)
        defer { await gate.release(port) }

        #expect(gate.phase(of: port) == .held)
        #expect(woken.isEmpty)
    }

    @Test func onlyAConnectionToTheLoopbackAddressPassesTheFilterOfTheNetwork() throws {
        let (listener, port) = try #require((0..<20).firstNonNil { _ -> (Int32, Int)? in
            let port = Self.freePort()
            return (try? PortGate.listener(on: port, host: inet_addr("127.0.0.1"))).map { ($0, port) }
        })
        defer { close(listener) }
        let local = try client(port)
        defer { close(local) }
        var pair: [Int32] = [0, 0]

        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { close($0) } }

        #expect(PortGate.goesToLoopback(local))
        #expect(!PortGate.goesToLoopback(pair[0]))
    }

    @Test func aReleaseFreesThePortAndEndsTheClientsOfTheStart() async throws {
        let gate = gate()
        let port = try heldPort(gate)

        let waiting = try client(port)
        defer { close(waiting) }
        #expect(await eventually { woken == [port] })

        await gate.release(port)

        #expect(Self.read(waiting, count: 1).isEmpty)
        #expect(await eventually { !PortInspector.acceptsConnections(port) })
    }

    @Test func aReleaseInATaskWithACancelStillEndsAfterTheClose() async throws {
        let gate = gate()
        let port = try heldPort(gate)

        let release = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await gate.release(port)
        }

        await release.value

        #expect(!gate.isHeld(port))
        #expect(await eventually { !PortInspector.acceptsConnections(port) })
    }

    @Test func releaseAllGivesEachClientOfAStartTheReason() async throws {
        let gate = gate()
        let port = try heldPort(gate)
        let error = [UInt8](PortRefusal.mysqlErrorPacket("Bye."))

        let waiting = try client(port)
        defer { close(waiting) }
        #expect(await eventually { woken == [port] })

        await gate.releaseAll(reason: "Bye.")

        #expect(Self.read(waiting, count: error.count + 1) == error)
        #expect(!gate.isHeld(port))
    }

    @Test func twoHeldPortsAreIndependent() async throws {
        let gate = gate()
        let first = try heldPort(gate)
        let second = try heldPort(gate)
        defer {
            await gate.release(first)
            await gate.release(second)
        }

        let waiting = try client(first)
        defer { close(waiting) }

        #expect(await eventually { woken == [first] })
        #expect(gate.phase(of: first) == .wake)
        #expect(gate.phase(of: second) == .held)
    }
}
