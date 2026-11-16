import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import Synchronization
import Testing
@testable import NexusEngine

private final class RecordingGate: WorkspaceServerGate {
    private let calls = Mutex<[String]>([])

    var recorded: [String] {
        calls.withLock { $0 }
    }

    private func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    func begin(wake: @escaping @Sendable (GatedServer) async -> String?) async {
        record("begin")
    }

    func hold(_ servers: Set<GatedServer>) async {
        record("hold \(servers.map(\.port).sorted())")
    }

    func serverWillStart(_ server: GatedServer) async -> Int? {
        record("willStart \(server.port)")
        return nil
    }

    func serverDidNotStart(_ server: GatedServer, handOver: Int?, reason: String) async {
        record("didNotStart \(server.port)")
    }

    func serverWillStop(_ server: GatedServer) async {
        record("willStop \(server.port)")
    }

    func serverDidStop(_ server: GatedServer) async {
        record("didStop \(server.port)")
    }

    func waitForHandOver(of port: Int) async -> String? {
        nil
    }

    func end(reason: String) async {}
}

extension NexusEngine {
    func useActivityBaseline(_ date: Date) {
        activityBaseline = date
    }

    func useUpdatingServices(_ ids: Set<String>) {
        updatingServices = ids
    }

    func useCheckingWorktrees(_ worktrees: Set<String>) {
        checkingWorktrees = worktrees
    }
}

extension NexusEngineTests {
    private func idleWorkspace(_ engine: NexusEngine) async -> WorkspaceInfo? {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return nil
        }

        return sites.flatMap { $0.workspaces ?? [] }.first
    }

    private func readyWorkspace(in root: URL, command: String = "exec sleep 300", runtimes: [(name: String, line: String)] = [], gate: any WorkspaceServerGate = NoServerGate()) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: [command])]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: runtimes, serverGate: gate)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        return (shop, engine, worktree)
    }

    private func isStopped(_ engine: NexusEngine, of shop: URL) async throws -> Bool {
        try await record(engine, of: shop).runState == .stopped
    }

    // git writes these files at the creation of the worktree. So they give a fresh workspace its
    // activity.
    private func backdateGitFiles(of worktree: URL, by seconds: TimeInterval) throws {
        let admin = try #require(ProjectFolder.adminFolder(ofWorktree: worktree.path(percentEncoded: false)))
        let date = Date.now.addingTimeInterval(-seconds)

        for file in ["logs/HEAD", "index", "commondir"] {
            let path = (admin as NSString).appendingPathComponent(file)

            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: path)
            }
        }
    }

    @Test func aStoppedWorkspaceRunsNoProcessAndAStartRunsItAgain() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            #expect(await runningProcesses(engine).count == 1)

            let stopped = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(stopped == .done(message: "Nexus stopped the workspace fix. The next page, command or database connection starts it again."))
            #expect(await runningProcesses(engine).isEmpty)
            #expect(try await isStopped(engine, of: shop))
            #expect(await idleWorkspace(engine)?.runState == .stopped)
            #expect(await idleWorkspace(engine)?.stoppedAfter == nil)

            let started = await engine.handle(.startWorkspace(host: "shop.test", name: "fix"))

            #expect(started == .done(message: "Nexus started the workspace fix."))
            #expect(try await !isStopped(engine, of: shop))
            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test func aStoppedWorkspaceStaysStoppedAfterANewStartOfNexusd() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)
        var saved = EngineState()

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            saved = await engine.stateStore.current()
        }

        let next = try makeSiteEngine(root: root, state: saved)

        try await whileRunning(next) {
            try await settle(next)

            #expect(await runningProcesses(next).isEmpty)
            #expect(try await isStopped(next, of: shop))
        }
    }

    @Test func theIdleCheckStopsAWorkspaceWithoutActivity() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            await engine.checkIdleWorkspaces(now: .now + 1800)
            #expect(await runningProcesses(engine).count == 1)

            await engine.checkIdleWorkspaces(now: .now + 7200)
            try await settle(engine)

            #expect(await runningProcesses(engine).isEmpty)
            #expect(try await isStopped(engine, of: shop))
            #expect(await idleWorkspace(engine)?.runState == .stopped)
            #expect(await idleWorkspace(engine)?.stoppedAfter == .oneHour)
        }
    }

    @Test func theIdleCheckKeepsAWorkspaceWithStopWhenIdleOff() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            let answer = await engine.handle(.setKeepAwake(host: "shop.test", name: "fix", keepAwake: true))
            try await settle(engine)
            await engine.checkIdleWorkspaces(now: .now + 7200)

            #expect(answer == .done(message: "The workspace fix does not stop when idle."))
            #expect(await idleWorkspace(engine)?.keepAwake == true)
            #expect(try await !isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func theIdleCheckStopsNoWorkspaceWithNever() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            try await engine.stateStore.update { $0.workspaceSettings.stopIdleAfter = .never }
            await engine.checkIdleWorkspaces(now: .now + 86_400 * 30)

            #expect(try await !isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func theIdleCheckKeepsAWorkspaceInPreparing() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.state = .preparing }
            await engine.checkIdleWorkspaces(now: .now + 7200)

            #expect(try await !isStopped(engine, of: shop))
        }
    }

    @Test(arguments: [
        NexusRequest.databaseConnections(host: "shop.test", workspace: "fix"),
        .fromAgent(agent: "Claude Code", request: .databaseConnections(host: "shop.test", workspace: "fix")),
    ])
    func aRequestThatNamesAWorkspaceCountsAsActivity(request: NexusRequest) async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            try await engine.stateStore.update { $0.workspaceSettings.stopIdleAfter = .fifteenMinutes }
            try backdateGitFiles(of: worktree, by: 86_400)
            await engine.useActivityBaseline(.now - 86_400)

            _ = await engine.handle(request)
            await engine.checkIdleWorkspaces(now: .now + 600)

            #expect(try await !isStopped(engine, of: shop))
            #expect(try #require(await idleWorkspace(engine)?.lastActivity) > .now - 120)

            await engine.checkIdleWorkspaces(now: .now + 1200)

            #expect(try await isStopped(engine, of: shop))
        }
    }

    @Test func aCommandInAStoppedWorkspaceStartsItBeforeTheAnswer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            _ = await engine.handle(.tool(.php, folder: worktree.path(percentEncoded: false)))

            #expect(try await !isStopped(engine, of: shop))
            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test func aCommandOfABackgroundProcessDoesNotStartAStoppedWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            _ = await engine.handle(.tool(.php, folder: worktree.path(percentEncoded: false), activity: false))
            try await settle(engine)

            #expect(try await isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aPageStartsAStoppedWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            await engine.pageRequested(by: NexusEngine.processOwner(key: RealPath.of(shop), workspace: "fix"))

            #expect(try await !isStopped(engine, of: shop))
            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test func aStopOnRequestKeepsStopWhenIdle() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.setKeepAwake(host: "shop.test", name: "fix", keepAwake: true))
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            let record = try await record(engine, of: shop)

            #expect(record.runState == .stopped)
            #expect(record.keepAwake)
            #expect(record.stoppedAfter == nil)
        }
    }

    @Test func aStartWithKeepTurnsStopWhenIdleOff() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            let answer = await engine.handle(.startWorkspace(host: "shop.test", name: "fix", keepAwake: true))
            try await settle(engine)

            let record = try await record(engine, of: shop)

            #expect(answer == .done(message: "Nexus started the workspace fix. It does not stop when idle."))
            #expect(record.runState == .running)
            #expect(record.keepAwake)
        }
    }

    @Test func aStartWhileTheServicesAreStoppedChangesNothing() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            _ = await engine.handle(.stopAll)
            try await settle(engine)

            let answer = await engine.handle(.startWorkspace(host: "shop.test", name: "fix"))

            #expect(answer == .failure(message: NexusEngine.servicesStoppedText))
            #expect(try await isStopped(engine, of: shop))
        }
    }

    @Test func aStoppedWorkspaceGivesNoServerAndARemovalKeepsItsServer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stoppedFolder = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)
        let removedFolder = root.appending(path: "clones/two/mysql-8.4", directoryHint: .isDirectory)
        let stoppedServer = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: stoppedFolder.path(percentEncoded: false), port: 51_001, account: .standard, isComplete: true)
        let removedServer = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: removedFolder.path(percentEncoded: false), port: 51_002, account: .standard, isComplete: true)
        var state = EngineState()
        state.worktrees["/w/shop"] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/shop-fix", folder: "/w/shop-fix", state: .ready, servers: [stoppedServer], runState: .stopped)])
        state.databaseRemovals = [DatabaseRemoval(server: removedServer, databases: ["shop"], workspace: "old", site: "/w/shop")]

        try FileManager.default.createDirectory(at: stoppedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removedFolder, withIntermediateDirectories: true)

        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])
        let paths = await engine.paths
        let current = await engine.stateStore.current()

        let servers = await engine.workspaceServers(current)
        let processes = await engine.workspaceServerProcesses(servers)
        let held = NexusEngine.serversToHold(servers)
        let expected = GatedServer(
            folder: stoppedServer.folder,
            instance: "mysql-8.4",
            kind: .mysql,
            port: 51_001,
            socket: paths.workspaceDatabaseSocket(.mysql, line: "8.4", port: 51_001),
            log: paths.log("mysql-8.4")
        )

        #expect(processes.map(\.definition.id) == [removedServer.folder])
        #expect(held == [expected])
    }

    @Test func theGateGetsTheListBeforeTheStopAndTheStartCallsBeforeTheSupervisor() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RecordingGate()
        let (shop, engine, _) = try await readyWorkspace(in: root, runtimes: [("mysql", "8.4")], gate: gate)
        let port = freePort()
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)
        let mysqld = await engine.paths.runtime("mysql", line: "8.4").appending(path: "bin/mysqld")
        let script = "#!/bin/sh\nfor argument in \"$@\"; do case \"$argument\" in --port=*) port=\"${argument#--port=}\";; esac; done\nexec \(fakeListener(port: "$port"))\n"

        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mysqld.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: mysqld, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mysqld.path(percentEncoded: false))

        try await whileRunning(engine) {
            let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: port, account: .standard, isComplete: true)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.servers = [server] }
            await engine.syncBackgroundProcesses().value
            #expect(await eventually { PortInspector.acceptsConnections(port) })

            let beforeStop = gate.recorded.count
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            let stop = Array(gate.recorded.dropFirst(beforeStop))

            let willStop = try #require(stop.firstIndex(of: "willStop \(port)"))
            let didStop = try #require(stop.firstIndex(of: "didStop \(port)"))

            #expect(stop[..<willStop].last == "hold [\(port)]")
            #expect(willStop < didStop)
            #expect(stop.last == "hold [\(port)]")
            #expect(!PortInspector.acceptsConnections(port))

            let beforeStart = gate.recorded.count
            let started = await engine.handle(.startWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            let start = Array(gate.recorded.dropFirst(beforeStart))

            let willStart = try #require(start.firstIndex(of: "willStart \(port)"))

            #expect(started == .done(message: "Nexus started the workspace fix."))
            #expect(start.first == "willStart \(port)")
            #expect(start[willStart...].contains("hold []"))
            #expect(start.last == "hold []")
            #expect(PortInspector.acceptsConnections(port))
        }
    }

    @Test func twoStartsAtTheSameMomentStartTheWorkspaceOnce() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyWorkspace(in: root, command: "echo x >> starts.txt; exec sleep 300")
        let starts = worktree.appending(path: "starts.txt")

        try await whileRunning(engine) {
            #expect(await eventually { FileManager.default.fileExists(atPath: starts.path(percentEncoded: false)) })

            let stopped = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(stopped == .done(message: "Nexus stopped the workspace fix. \(WorkspaceIdleText.startsAgain)"))
            #expect(await runningProcesses(engine).isEmpty)

            try FileManager.default.removeItem(at: starts)

            await withTaskGroup { group in
                group.addTask { _ = await engine.handle(.startWorkspace(host: "shop.test", name: "fix")) }
                group.addTask { _ = await engine.handle(.startWorkspace(host: "shop.test", name: "fix")) }
            }

            try await settle(engine)

            #expect(try await !isStopped(engine, of: shop))
            #expect(await eventually { (try? String(contentsOf: starts, encoding: .utf8)) == "x\n" })
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aStopOnRequestDuringTheCheckOfAFileChangeStopsTheWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            let worktree = try await record(engine, of: shop).worktree

            await engine.useCheckingWorktrees([worktree])
            let stopped = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            await engine.useCheckingWorktrees([])
            try await settle(engine)

            #expect(stopped == .done(message: "Nexus stopped the workspace fix. \(WorkspaceIdleText.startsAgain)"))
            #expect(try await isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func theIdleCheckWithoutAWorkspaceToStopWritesNoState() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)
        let file = await engine.paths.config.appending(path: "state.json").path(percentEncoded: false)

        try await whileRunning(engine) {
            let before = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date

            await engine.checkIdleWorkspaces(now: .now + 60)
            await engine.checkIdleWorkspaces(now: .now + 120)

            let after = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date

            #expect(before != nil)
            #expect(after == before)
            #expect(try await !isStopped(engine, of: shop))
        }
    }

    @Test func aSecondStopDuringAStopSaysThatTheWorkspaceIsStoppedAlready() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            let answers = await withTaskGroup(of: NexusResponse.self) { group in
                group.addTask { await engine.handle(.stopWorkspace(host: "shop.test", name: "fix")) }
                group.addTask { await engine.handle(.stopWorkspace(host: "shop.test", name: "fix")) }

                return await group.reduce(into: [NexusResponse]()) { $0.append($1) }
            }

            try await settle(engine)

            #expect(answers.contains(.done(message: "Nexus stopped the workspace fix. The next page, command or database connection starts it again.")))
            #expect(answers.contains(.done(message: "The workspace fix is stopped already.")))
            #expect(try await isStopped(engine, of: shop))
        }
    }

    @Test func aStopWhoseStateIsNotSavedGivesTheErrorAndStillStopsTheProcesses() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)
        let config = await engine.paths.config.path(percentEncoded: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config) }

        try await whileRunning(engine) {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: config)
            let answer = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config)
            try await settle(engine)

            guard case .failure(let message) = answer else {
                Issue.record("The stop gave no failure: \(answer)")
                return
            }

            #expect(message.contains("state.json"))
            #expect(try await isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aSetupOfAStoppedWorkspaceEndsWithTheReasonOfARefusedStart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: root.appending(path: "clones/one/mysql-8.4").path(percentEncoded: false), port: 51_003, account: .standard, isComplete: true)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { record in
                record.servers = [server]
                record.state = .preparing
            }
            await engine.useUpdatingServices(["mysql-8.4"])
            await engine.startWorkspaceSetups()
            try await settle(engine)

            let record = try await record(engine, of: shop)

            #expect(record.state == .notIsolated(NexusEngine.updateText("mysql-8.4")))
            #expect(record.runState == .stopped)
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aRefusedCommandDoesNotStartAStoppedWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            let answer = await engine.handle(.tool(.node, folder: worktree.path(percentEncoded: false), debug: true))
            try await settle(engine)

            #expect(answer == .failure(message: DebugCommand.onlyPHP(.node)))
            #expect(try await isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aRefusedDatabaseRequestDoesNotStartAStoppedWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            let answer = await engine.handle(.serverDatabases(.workspace(site: "shop.test", name: "fix", instance: "mysql-8.4")))
            try await settle(engine)

            #expect(answer == .failure(message: "Nexus has no database instance mysql-8.4. See: nexus db list"))
            #expect(try await isStopped(engine, of: shop))
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aPageStartsAWorkspaceThatStoppedBeforeANewStartOfNexusd() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, _) = try await readyWorkspace(in: root)
        var saved = EngineState()

        try await whileRunning(engine) {
            _ = await engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            saved = await engine.stateStore.current()
        }

        let next = try makeSiteEngine(root: root, state: saved)

        try await whileRunning(next) {
            try await settle(next)

            await next.pageRequested(by: NexusEngine.processOwner(key: RealPath.of(shop), workspace: "fix"))

            #expect(try await !isStopped(next, of: shop))
            #expect(await eventually { await runningProcesses(next).count == 1 })
        }
    }
}
