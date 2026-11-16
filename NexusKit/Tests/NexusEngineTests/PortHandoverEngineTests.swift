import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import Testing
@testable import NexusEngine

private final class PortGateClient {
    private let descriptor: Int32

    init?(port: Int) {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(UInt16(port).bigEndian)
        target.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        guard connected == 0 else {
            close(descriptor)
            return nil
        }
    }

    deinit {
        close(descriptor)
    }

    func send(_ text: String) {
        let bytes = Array("\(text)\n".utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, bytes.count, 0) }
    }

    func received() -> String {
        var interval = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)

            guard count > 0 else {
                return String(decoding: data, as: UTF8.self)
            }

            data += buffer.prefix(count)
        }
    }
}

private struct Handover {
    let shop: URL
    let worktree: URL
    let engine: NexusEngine
    let gate: WorkspacePortGate
    let own: DatabaseClient
    let server: WorkspaceDatabaseServer
}

// The port hand-over of the workspace servers with real servers (plan item 3e).
extension NexusEngineTests {
    static let handoverRuntimes: [(String, String, String)] = [("mysql", "8.4", "mysql"), ("mariadb", "11.8", "mariadb"), ("postgresql", "18", "pgsql")]

    private func handoverWorkspace(in root: URL, name: String, line: String, driver: String, _ steps: (Handover) async throws -> Void) async throws {
        let gate = WorkspacePortGate()
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: driver, runtime: (name, line), serverGate: gate)
        let id = "\(name)-\(line)"

        try await whileRunning(engine) {
            await engine.beginIdleStops()
            _ = await engine.handle(.start(service: id))
            let client = try await databaseClient(engine, id: id, port: port)
            try await mainDatabase(client)
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let own = try await workspaceClient(engine, id: id, of: shop)
            let server = try #require(try await record(engine, of: shop).servers.first)

            try await steps(Handover(shop: shop, worktree: worktree, engine: engine, gate: gate, own: own, server: server))
        }
    }

    private func stopWorkspace(_ handover: Handover) async throws {
        let answer = await handover.engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))

        #expect(answer == .done(message: "Nexus stopped the workspace fix. The next page, command or database connection starts it again."))
        try await settle(handover.engine)
    }

    private func processID(_ engine: NexusEngine, _ folder: String) async -> Int32? {
        guard case .running(let pid, _) = await engine.processSupervisor.state(of: folder) else {
            return nil
        }

        return pid
    }

    private func fakeMySQLServer(_ paths: NexusPaths) throws {
        let mysqld = paths.runtime("mysql", line: "8.4").appending(path: "bin/mysqld")
        let script = """
            #!/bin/sh
            for argument in "$@"; do case "$argument" in --port=*) port="${argument#--port=}";; --socket=*) socket="${argument#--socket=}";; --datadir=*) data="${argument#--datadir=}";; esac; done
            if [ -e "$data/end-once" ]; then rm "$data/end-once"; exit 1; fi
            /usr/bin/nc -lk 127.0.0.1 "$port" < /dev/null &
            sleep 0.1
            while :; do rm -f "$socket"; printf x | /usr/bin/nc -lU "$socket"; done &
            wait

            """

        try FileManager.default.createDirectory(at: mysqld.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: mysqld, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mysqld.path(percentEncoded: false))
    }

    private func highPort() throws -> Int {
        freePortAboveNexus()
    }

    private func gatedServer(in root: URL, port: Int) -> GatedServer {
        GatedServer(
            folder: root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory).path(percentEncoded: false),
            instance: "mysql-8.4",
            kind: .mysql,
            port: port,
            socket: root.appending(path: "mysql.sock"),
            log: root.appending(path: "mysql-8.4.log")
        )
    }

    private func clientError(_ client: DatabaseClient) async -> String? {
        do {
            _ = try await client.query("SELECT 1")
            return nil
        } catch CommandError.failed(_, _, let output) {
            return output
        } catch {
            return "\(error)"
        }
    }

    @Test func aConnectionToAStoppedServerStartsItsWorkspaceAndReachesTheServer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        let gate = WorkspacePortGate()
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: ["exec sleep 300"])]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")], serverGate: gate)
        let port = freePort()
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try fakeMySQLServer(paths)

        try await whileRunning(engine) {
            await engine.beginIdleStops()
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: port, account: .standard, isComplete: true)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.servers = [server] }
            await engine.syncBackgroundProcesses().value
            #expect(await eventually { PortInspector.acceptsConnections(port) })

            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(await gate.phase(of: port) == .held)

            let client = try #require(PortGateClient(port: port))
            client.send("ping-of-the-client")

            #expect(await eventually { (try? String(contentsOf: paths.log("mysql-8.4"), encoding: .utf8))?.contains("ping-of-the-client") == true })
            #expect(await gate.phase(of: port) == nil)
            #expect(try await record(engine, of: shop).runState == .running)
        }
    }

    @Test func aConnectionToTheHeldPortOfAServerThatDoesNotRunInARunningWorkspaceStartsTheServer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        let gate = WorkspacePortGate()
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: ["exec sleep 300"])]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")], serverGate: gate)
        let port = freePortAboveNexus()
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try fakeMySQLServer(paths)

        try await whileRunning(engine) {
            await engine.beginIdleStops()
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: port, account: .standard, isComplete: true)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.servers = [server] }
            let gated = try #require(await engine.workspaceServers(await engine.stateStore.current()).first?.gated)
            await gate.hold([gated])

            #expect(await gate.phase(of: port) == .held)
            #expect(await processID(engine, server.folder) == nil)
            #expect(try await record(engine, of: shop).runState == .running)

            let client = try #require(PortGateClient(port: port))
            client.send("ping-of-the-client")

            #expect(await eventually { (try? String(contentsOf: paths.log("mysql-8.4"), encoding: .utf8))?.contains("ping-of-the-client") == true })
            #expect(await gate.phase(of: port) == nil)
            #expect(await processID(engine, server.folder) != nil)
        }
    }

    @Test func aServerThatEndsDuringItsStartGetsTheConnectionsOfTheStartAfterItsRestart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        let gate = WorkspacePortGate()
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: ["exec sleep 300"])]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")], serverGate: gate)
        let port = try highPort()
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try fakeMySQLServer(paths)

        try await whileRunning(engine) {
            await engine.beginIdleStops()
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: port, account: .standard, isComplete: true)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.servers = [server] }
            await engine.syncBackgroundProcesses().value
            #expect(await eventually { PortInspector.acceptsConnections(port) })

            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(await gate.phase(of: port) == .held)

            try Data().write(to: clone.appending(path: "end-once"))
            let client = try #require(PortGateClient(port: port))
            client.send("ping-of-the-client")

            #expect(await eventually { (try? String(contentsOf: paths.log("mysql-8.4"), encoding: .utf8))?.contains("ping-of-the-client") == true })
            #expect(!exists(clone.appending(path: "end-once")))
            #expect(await gate.phase(of: port) == nil)
        }
    }

    @Test func aFailedStartFreesThePortAndTheNumberOfAnEarlierHandOverEndsNoNewerOne() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspacePortGate()
        defer { await gate.end(reason: "The test ends.") }
        let port = try highPort()
        let server = gatedServer(in: root, port: port)

        await gate.hold([server])
        try #require(await gate.phase(of: port) == .held)

        let first = try #require(await gate.serverWillStart(server))
        await gate.serverDidNotStart(server, handOver: first, reason: "The first start failed.")

        #expect(await gate.phase(of: port) == nil)

        await gate.hold([server])
        try #require(await gate.phase(of: port) == .held)

        let second = try #require(await gate.serverWillStart(server))
        await gate.serverDidNotStart(server, handOver: first, reason: "The first start failed.")

        #expect(second != first)
        #expect(await gate.phase(of: port) == .handOver)

        await gate.serverDidNotStart(server, handOver: second, reason: "The second start failed.")

        #expect(await gate.phase(of: port) == nil)
    }

    @Test func aServerThatIsNotReadyInTimeGivesTheClientTheReasonAndLeavesThePortFree() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspacePortGate(readyTimeout: .seconds(1))
        defer { await gate.end(reason: "The test ends.") }
        let port = try highPort()
        let server = gatedServer(in: root, port: port)

        await gate.begin { [weak gate] server in
            _ = await gate?.serverWillStart(server)
            return nil
        }
        await gate.hold([server])
        try #require(await gate.phase(of: port) == .held)

        let client = try #require(PortGateClient(port: port))

        #expect(client.received().contains("does not take connections"))
        #expect(await gate.phase(of: port) == nil)
        #expect(await eventually { PortInspector.isFree(port) })
    }

    @Test func aServerWithAnotherSocketAndLogIsTheSameServerForTheGate() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspacePortGate()
        defer { await gate.end(reason: "The test ends.") }
        let port = try highPort()
        let server = gatedServer(in: root, port: port)
        let changed = GatedServer(folder: server.folder, instance: server.instance, kind: server.kind, port: port, socket: root.appending(path: "other.sock"), log: root.appending(path: "other.log"))

        await gate.hold([server])
        try #require(await gate.phase(of: port) == .held)

        let handOver = await gate.serverWillStart(changed)

        #expect(handOver != nil)
        #expect(await gate.phase(of: port) == .handOver)

        await gate.serverDidNotStart(changed, handOver: handOver, reason: "The test ends.")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: handoverRuntimes)
    func aRealStoppedWorkspaceServerStartsWithTheFirstConnectionAndASyncKeepsIt(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await handoverWorkspace(in: root, name: name, line: line, driver: driver) { handover in
            let port = handover.server.port
            let before = try await digest(handover.own, "shop")

            try await stopWorkspace(handover)

            #expect(await handover.gate.phase(of: port) == .held)
            #expect(await processID(handover.engine, handover.server.folder) == nil)

            await handover.engine.syncBackgroundProcesses().value

            #expect(await handover.gate.phase(of: port) == .held)
            #expect(await processID(handover.engine, handover.server.folder) == nil)

            #expect(try await handover.own.query("SELECT 1") == "1")
            #expect(try await digest(handover.own, "shop") == before)
            #expect(await handover.gate.phase(of: port) == nil)
            #expect(try await record(handover.engine, of: handover.shop).runState == .running)

            let pid = await processID(handover.engine, handover.server.folder)
            await handover.engine.syncBackgroundProcesses().value

            #expect(pid != nil)
            #expect(await processID(handover.engine, handover.server.folder) == pid)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: [("mysql", "8.4", "mysql"), ("mariadb", "11.8", "mariadb")])
    func aRealConnectionDuringTheStopStartsTheServerAgain(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await handoverWorkspace(in: root, name: name, line: line, driver: driver) { handover in
            let port = handover.server.port
            let kind = try #require(DatabaseKind(rawValue: name))
            let socket = await handover.engine.paths.workspaceDatabaseSocket(kind, line: line, port: port).path(percentEncoded: false)
            let engine = handover.engine
            let stop = Task { await engine.handle(.stopWorkspace(host: "shop.test", name: "fix")) }

            #expect(await eventually {
                let phase = await handover.gate.phase(of: port)
                return phase == .held || phase == .takeBack && !PortInspector.acceptsConnections(socket: socket)
            })
            #expect(try await handover.own.query("SELECT 1") == "1")
            #expect(await stop.value == .done(message: "Nexus stopped the workspace fix. The next page, command or database connection starts it again."))
            #expect(await processID(handover.engine, handover.server.folder) != nil)
            #expect(try await record(handover.engine, of: handover.shop).runState == .running)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: handoverRuntimes)
    func aRealClientGetsTheReasonWhenItsServerCannotStart(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await handoverWorkspace(in: root, name: name, line: line, driver: driver) { handover in
            let folder = URL(filePath: handover.server.folder, directoryHint: .isDirectory)
            let moved = folder.deletingLastPathComponent().appending(path: "moved", directoryHint: .isDirectory)

            try await stopWorkspace(handover)
            try FileManager.default.moveItem(at: folder, to: moved)

            let missing = await clientError(handover.own)

            try FileManager.default.moveItem(at: moved, to: folder)

            #expect(missing?.contains("Nexus cannot start this database server. It did not start with its workspace.") == true)

            try await stopWorkspace(handover)
            _ = await handover.engine.handle(.stopAll)

            let stopped = await clientError(handover.own)

            #expect(stopped?.contains("Nexus cannot start this database server. \(NexusEngine.servicesStoppedText)") == true)
            #expect(await handover.gate.phase(of: handover.server.port) == .held)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: handoverRuntimes)
    func aRealWaitForAHeldServerStartsItsWorkspace(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await handoverWorkspace(in: root, name: name, line: line, driver: driver) { handover in
            let tools = try #require(await handover.engine.databaseRuntime("\(name)-\(line)"))

            try await stopWorkspace(handover)
            try await handover.engine.waitForServer(tools, port: handover.server.port)

            #expect(await eventually { await processID(handover.engine, handover.server.folder) != nil })
            #expect(try await handover.own.query("SELECT 1") == "1")
            #expect(try await record(handover.engine, of: handover.shop).runState == .running)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: handoverRuntimes)
    func aRealRemovalOfAStoppedWorkspaceReleasesThePortAndKeepsADump(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await handoverWorkspace(in: root, name: name, line: line, driver: driver) { handover in
            let port = handover.server.port

            try await stopWorkspace(handover)
            #expect(await handover.gate.phase(of: port) == .held)

            try await git("worktree", "remove", "--force", handover.worktree.path(percentEncoded: false), in: handover.shop)
            try await settle(handover.engine)
            await handover.engine.startDatabaseRemovals().value

            let dumps = await handover.engine.dumps()

            #expect(dumps.count == 1)
            #expect(dumps.first?.name.hasSuffix("-\(name)-\(line)-shop_fix.\(name == "postgresql" ? "dump.gz" : "sql.gz")") == true)
            #expect(await handover.gate.phase(of: port) == nil)
            #expect(!FileManager.default.fileExists(atPath: handover.server.folder))
            #expect(PortInspector.isFree(port))
        }
    }
}
