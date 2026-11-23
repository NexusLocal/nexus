import Foundation
import NexusCore
import NexusMongoDB
import NexusSupervisor

// The gate of the ports of the stopped workspace servers (plan item 3e, owner 2026-11-15, way 1 of
// research 5). The engine gives the list of the servers to hold and calls the gate around each start
// and stop of a workspace server. After a start the gate waits until the server takes connections,
// and then it passes on the connections of the start. A database connection starts its workspace,
// but it is no activity (owner, 2026-11-15).
public actor WorkspacePortGate: WorkspaceServerGate {
    static let refusalStart = "Nexus cannot start this database server."

    private let gate = PortGate()
    private let activity: ActivityLog?
    private let readyTimeout: Duration
    private var wake: (@Sendable (GatedServer) async -> String?)?
    // wanted is the last list of hold, without the servers that started after that list. gated has
    // the server of each port with a phase in the gate. A start or a stop can keep a port after the
    // list lost it. handOvers has the number of the hand-over of each port. That number tells it
    // apart from an earlier hand-over of the same port, and its watch ends when the number goes.
    private var wanted: [Int: GatedServer] = [:]
    private var gated: [Int: GatedServer] = [:]
    private var handOvers: [Int: Int] = [:]
    private var handOverCount = 0
    private var waiters: [Int: [CheckedContinuation<String?, Never>]] = [:]
    // A server that runs holds its own port, so a failed hold of that port is no problem. reported
    // has each port with a problem in the activity log.
    private var started: Set<Int> = []
    private var reported: Set<Int> = []
    private var ended = false

    public init(activity: ActivityLog? = nil, readyTimeout: Duration = ServiceCatalog.databaseStartTimeout) {
        self.activity = activity
        self.readyTimeout = readyTimeout
    }

    static func refusal(_ reason: String) -> String {
        "\(refusalStart) \(reason)"
    }

    public func phase(of port: Int) -> PortGate.Phase? {
        gate.phase(of: port)
    }

    // MARK: WorkspaceServerGate

    public func begin(wake: @escaping @Sendable (GatedServer) async -> String?) async {
        self.wake = wake

        gate.onWake { [weak self] port in
            Task { await self?.connected(port) }
        }
    }

    public func hold(_ servers: Set<GatedServer>) async {
        guard !ended else {
            return
        }

        wanted = Dictionary(servers.map { ($0.port, $0) }) { first, _ in first }

        for port in gated.keys.sorted() {
            await releaseIfUnwanted(port)
        }

        for server in wanted.values.sorted(by: { $0.port < $1.port }) where gated[server.port] == nil {
            holdPort(of: server)
        }
    }

    // 3c sets the record of the workspace to running before the start of its servers. So a server
    // that starts leaves the list of hold at once, and a failed start does not hold the port of a
    // workspace that runs (owner, 2026-11-15).
    public func serverWillStart(_ server: GatedServer) async -> Int? {
        started.insert(server.port)

        if server.isSame(as: wanted[server.port]) {
            wanted[server.port] = nil
        }

        guard !ended, server.isSame(as: gated[server.port]) else {
            return nil
        }

        if let running = handOvers[server.port] {
            return running
        }

        handOverCount += 1

        let number = handOverCount

        // The entry comes before the first wait. So a call during the wait finds this start.
        handOvers[server.port] = number

        guard await gate.beginHandOver(server.port) else {
            if handOvers[server.port] == number {
                conclude(server.port, nil)
            }

            return nil
        }

        // A stop during the wait ends this hand-over.
        guard handOvers[server.port] == number else {
            return nil
        }

        Task { await self.watchStart(of: server, number: number) }

        // A listener that just closed can keep its port for some milliseconds, and the server must
        // not find it.
        _ = await PortInspector.becomesFree(server.port, on: IPv4Socket.loopback)
        return number
    }

    public func serverDidNotStart(_ server: GatedServer, handOver: Int?, reason: String) async {
        guard let handOver else {
            started.remove(server.port)
            return
        }

        guard handOvers[server.port] == handOver else {
            return
        }

        await fail(server, reason: reason, holdsAgain: server.isSame(as: wanted[server.port]))
    }

    // A stop during a hand-over keeps the connections of that start. After the stop they start the
    // workspace again, or they get the reason why not.
    public func serverWillStop(_ server: GatedServer) async {
        if server.isSame(as: gated[server.port]), handOvers[server.port] != nil {
            conclude(server.port, server.stoppedDuringStart)
        }

        guard !ended, server.isSame(as: wanted[server.port]) || server.isSame(as: gated[server.port]) else {
            return
        }

        if await gate.beginTakeBack(server.port, wire: Self.wire(of: server.kind)) {
            gated[server.port] = server
        }
    }

    public func serverDidStop(_ server: GatedServer) async {
        started.remove(server.port)

        guard server.isSame(as: gated[server.port]), gate.phase(of: server.port) == .takeBack else {
            return
        }

        do {
            try await retried { try await self.gate.finishTakeBack(server.port) }
        } catch {
            gated[server.port] = nil
            report(server.port, error)
            await gate.release(server.port)
            return
        }

        await releaseIfUnwanted(server.port)
    }

    public func waitForHandOver(of port: Int) async -> String? {
        guard handOvers[port] != nil else {
            return nil
        }

        return await withCheckedContinuation { waiter in
            waiters[port, default: []].append(waiter)
        }
    }

    public func end(reason: String) async {
        ended = true

        for port in handOvers.keys {
            conclude(port, reason)
        }

        gated = [:]
        wanted = [:]
        await gate.releaseAll(reason: Self.refusal(reason))
    }

    // MARK: The ports

    // The first new connection to a held port. wake answers nil after serverWillStart came for each
    // server that starts. So a port that still waits did not start with its workspace.
    private func connected(_ port: Int) async {
        guard let server = gated[port], let wake else {
            gate.refuse(port, reason: Self.refusal("nexusd starts now. Connect again in a few seconds."))
            return
        }

        if let reason = await wake(server) {
            gate.refuse(port, reason: Self.refusal(reason))
        } else if gate.phase(of: port) == .wake {
            gate.refuse(port, reason: Self.refusal("It did not start with its workspace. See \(server.log.path(percentEncoded: false))."))
        }

        await releaseIfUnwanted(port)
    }

    private func holdPort(of server: GatedServer) {
        guard !ended else {
            return
        }

        do {
            try gate.hold(server.port, wire: Self.wire(of: server.kind))
            gated[server.port] = server
            reported.remove(server.port)
        } catch {
            guard !started.contains(server.port) else {
                return
            }

            report(server.port, error)
        }
    }

    // Only a port without connections goes. A start or a stop ends its phase first.
    private func releaseIfUnwanted(_ port: Int) async {
        guard let server = gated[port], !server.isSame(as: wanted[port]), gate.phase(of: port) == .held else {
            return
        }

        gated[port] = nil
        await gate.release(port)
    }

    private func report(_ port: Int, _ error: any Error) {
        guard reported.insert(port).inserted else {
            return
        }

        activity?.write("workspace", "Nexus cannot hold port \(port) of a stopped database server. \(ErrorText.plain(error)) A database app gets \"Connection refused\" until its workspace starts.")
    }

    // A server that just ended can keep its port for some milliseconds (PortInspector.becomesFree).
    // The wait is here and not in the gate, so no thread blocks.
    private func retried(_ bind: () async throws -> Void) async throws {
        let deadline = ContinuousClock.now + .seconds(1)

        while true {
            do {
                return try await bind()
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw error
                }

                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    // MARK: The start

    // MySQL and MariaDB greet after both listeners exist. PostgreSQL takes logins after line 8 of
    // postmaster.pid says "ready". The supervisor starts a server that ends during its start again,
    // so the watch keeps the connections of the start for that new start.
    private func watchStart(of server: GatedServer, number: Int) async {
        let deadline = ContinuousClock.now + readyTimeout

        while ContinuousClock.now < deadline {
            let isReady = await Self.isReady(server)

            guard handOvers[server.port] == number else {
                return
            }

            // The connections of the start go to the server before a waiter probes it. A stop during
            // the pass on can end this hand-over already.
            if isReady {
                await gate.finishHandOver(server.port)

                if gate.phase(of: server.port) == nil, server.isSame(as: gated[server.port]) {
                    gated[server.port] = nil
                }

                if handOvers[server.port] == number {
                    conclude(server.port, nil)
                }

                return
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        guard handOvers[server.port] == number else {
            return
        }

        // The process still runs, and it can still get ready. A listener of the gate on 127.0.0.1
        // would stop its bind. So the gate does not hold the port again (owner, 2026-11-15).
        await fail(server, reason: "The server does not take connections after \(readyTimeout.components.seconds) seconds. See \(server.log.path(percentEncoded: false)).", holdsAgain: false)
    }

    // The clients of the start get the reason. With holdsAgain the port stays held after the failed
    // start, and the next connections get the reason for the failure pause. holdsAgain must be false
    // while the process of the server runs.
    private func fail(_ server: GatedServer, reason: String, holdsAgain: Bool) async {
        started.remove(server.port)
        conclude(server.port, reason)

        do {
            try await gate.failHandOver(server.port, reason: Self.refusal(reason), holdsAgain: holdsAgain)
        } catch {
            report(server.port, error)
        }

        if gate.phase(of: server.port) == nil, server.isSame(as: gated[server.port]) {
            gated[server.port] = nil
        }
    }

    private func conclude(_ port: Int, _ result: String?) {
        handOvers[port] = nil
        waiters.removeValue(forKey: port)?.forEach { $0.resume(returning: result) }
    }

    private static func isReady(_ server: GatedServer) async -> Bool {
        switch server.kind {
        case .mysql, .mariadb:
            await ServerReadiness.receivesGreeting(socket: server.socket.path(percentEncoded: false))
        case .postgresql:
            ServerReadiness.isReady(postgreSQLData: URL(filePath: server.folder, directoryHint: .isDirectory))
        case .mongodb:
            await isPrimary(socket: server.socket.path(percentEncoded: false))
        }
    }

    // mongod listens on its socket after its TCP port (tested with 7.0, 8.0 and 9.0). During the
    // hand-over a probe of the port would reach the gate itself. The set elects its one server about
    // a second after the start. A driver of PHP asks one time and does not wait for an election. So
    // the clients of the start wait until the server takes writes. hello needs no login.
    private static func isPrimary(socket path: String) async -> Bool {
        guard PortInspector.acceptsConnections(socket: path), let connection = try? await MongoDBConnection.connect(socket: path, timeout: 1) else {
            return false
        }

        let isPrimary = (try? await MongoDBServer(connection).isPrimary()) == true
        await connection.disconnect()
        return isPrimary
    }

    private static func wire(of kind: DatabaseKind) -> PortGate.Wire {
        switch kind {
        case .mysql, .mariadb: .mysql
        case .postgresql: .postgresql
        case .mongodb: .mongodb
        }
    }
}
