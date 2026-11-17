import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private static let fastRestarts = RestartPolicy(firstDelay: .milliseconds(50), maximumDelay: .milliseconds(200), stableAfter: .seconds(60), maximumQuickRestarts: 3, stopTimeout: .seconds(2))

    private func lines(of file: URL, _ activity: ActivityLog) throws -> [String] {
        activity.waitForWrites()

        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { line in String(line.drop { $0 != " " }.dropFirst()) }
    }

    @Test func aWorktreeGivesTheLinesOfItsRecordAndItsSetup() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, activity: activity)
        let worktree = root.appending(path: "TICKET-123", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "ticket", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let path = RealPath.of(worktree)
            try await git("worktree", "remove", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try lines(of: logFile, activity) == [
                "nexusd workspace: Nexus adds the workspace ticket-123 for the worktree \(path).",
                "nexusd workspace: Nexus sets up the workspace ticket-123.",
                "nexusd workspace: The setup of the workspace ticket-123 ended: Ready.",
                "nexusd workspace: Nexus removes the workspace ticket-123 of the worktree \(path).",
            ])
        }
    }

    @Test func aWorkspaceServerGetsItsStartItsEndAndItsStopAndAWorkerGetsNoLine() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let processes = ProcessSupervisor(policy: Self.fastRestarts)
        let engine = try makeSiteEngine(root: root, processSupervisor: processes, activity: activity)
        let port = freePort()
        let server = ServiceDefinition(id: "/data/workspaces/A/mysql-8.4", displayName: "MySQL 8.4 of a workspace", executable: URL(filePath: "/bin/sleep"), arguments: ["30"], ports: [port], logFile: root.appending(path: "mysql-8.4.log"), activityName: "mysql-8.4 of the workspace fix")
        let worker = ServiceDefinition(id: "worker", displayName: "php artisan queue:work", executable: URL(filePath: "/bin/sleep"), arguments: ["30"], logFile: root.appending(path: "worker.log"))

        try await whileRunning(engine) {
            await engine.observeSupervisor()
            try await processes.start(server)
            try await processes.start(worker)
            let first = try #require(await processes.state(of: server.id)?.pid)
            let workerPID = try #require(await processes.state(of: worker.id)?.pid)

            kill(first, SIGTERM)
            kill(workerPID, SIGTERM)
            #expect(await eventually { await processes.state(of: server.id)?.pid.map { $0 != first } == true })
            let second = try #require(await processes.state(of: server.id)?.pid)
            try await processes.stop(server.id, cause: "the workspace stopped")
            try await processes.stop(worker.id, cause: "the workspace stopped")

            #expect(try lines(of: logFile, activity) == [
                "nexusd workspace: mysql-8.4 of the workspace fix started on port \(port) (process \(first)).",
                "nexusd workspace: mysql-8.4 of the workspace fix (process \(first)) ended with signal 15 (SIGTERM). Nexus did not ask for this stop. Nexus starts it again, attempt 1.",
                "nexusd workspace: mysql-8.4 of the workspace fix started on port \(port) (process \(second)).",
                "nexusd workspace: mysql-8.4 of the workspace fix (process \(second)) stopped: the workspace stopped",
            ])
        }
    }

    @Test func aServiceGetsItsStartItsEndAndItsStopWithTheCause() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let services = ProcessSupervisor(policy: Self.fastRestarts)
        let engine = try makeSiteEngine(root: root, supervisor: services, activity: activity)
        let mariadb = ServiceDefinition(id: "mariadb-12.3", displayName: "MariaDB 12.3", executable: URL(filePath: "/bin/sleep"), arguments: ["30"], logFile: root.appending(path: "mariadb-12.3.log"))

        try await whileRunning(engine) {
            await engine.observeSupervisor()
            try await services.start(mariadb)
            let first = try #require(await services.state(of: mariadb.id)?.pid)

            kill(first, SIGTERM)
            #expect(await eventually { await services.state(of: mariadb.id)?.pid.map { $0 != first } == true })
            let second = try #require(await services.state(of: mariadb.id)?.pid)
            try await services.stop(mariadb.id, cause: "update to build 110")

            #expect(try lines(of: logFile, activity) == [
                "nexusd service: mariadb-12.3 started (process \(first)).",
                "nexusd service: mariadb-12.3 (process \(first)) ended with signal 15 (SIGTERM). Nexus did not ask for this stop. Nexus starts it again, attempt 1.",
                "nexusd service: mariadb-12.3 started (process \(second)).",
                "nexusd service: mariadb-12.3 (process \(second)) stopped: update to build 110",
            ])
        }
    }

    @Test func aWorkspaceServerHasTheNameOfItsInstanceAndItsWorkspace() {
        let runtime = InstalledRuntime(name: "mysql", line: "8.4", version: "8.4.0", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/tmp/mysql"))
        let catalog = ServiceCatalog(paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")))

        let definition = catalog.workspaceServerDefinition(id: "/data/workspaces/A/mysql-8.4", instance: "mysql-8.4", workspace: "lexi-1143", runtime: runtime, port: 20009, folder: URL(filePath: "/data/workspaces/A/mysql-8.4"), environment: [:])

        #expect(definition?.activityName == "mysql-8.4 of the workspace lexi-1143")
    }

    @Test func aRequestOfAnAgentNamesTheAgentAndAnotherRequestNamesTheAppAndTheCommand() {
        #expect(NexusEngine.origin(of: .fromAgent(agent: "Claude Code", request: .stop(service: "mysql-8.4"))) == "Claude Code")
        #expect(NexusEngine.origin(of: .stop(service: "mysql-8.4")) == "the app or the nexus command")
    }

    @Test func theRecordLinesNameTheWorkspaceAndItsWorktree() {
        let added = Workspace(name: "lexi-1143", worktree: "/w/.claude/worktrees/LEXI-1143", folder: "/w/.claude/worktrees/LEXI-1143")
        let removed = Workspace(name: "lexi-1983", worktree: "/w/.claude/worktrees/LEXI-1983", folder: "/w/.claude/worktrees/LEXI-1983")

        let lines = NexusEngine.recordLines(of: WorktreeChange(changed: true, removed: ["/w": [removed]], added: ["/w": [added]]))

        #expect(lines == [
            "Nexus adds the workspace lexi-1143 for the worktree /w/.claude/worktrees/LEXI-1143.",
            "Nexus removes the workspace lexi-1983 of the worktree /w/.claude/worktrees/LEXI-1983.",
        ])
    }

    @Test func aChangeOfTheWorktreesNamesTheNewWorkspaces() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStateStore(paths: NexusPaths(root: root))
        let staying = Workspace(name: "staying", worktree: "/w/staying", folder: "/w/staying")
        let new = Workspace(name: "new", worktree: "/w/new", folder: "/w/new")
        _ = try await store.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [staying])] }

        let change = try await store.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [staying, new])] }

        #expect(change.added == ["/w": [new]])
        #expect(change.removed.isEmpty)
    }

    @Test func theEndOfASetupNamesItsResult() {
        #expect(NexusEngine.setupEndText("lexi-1143", result: .stored(.ready)) == "The setup of the workspace lexi-1143 ended: Ready.")
        #expect(NexusEngine.setupEndText("lexi-1143", result: .stored(.notIsolated("The connection mysql does not use the database server of this workspace."))) == "The setup of the workspace lexi-1143 ended: Not isolated. The connection mysql does not use the database server of this workspace.")
        #expect(NexusEngine.setupEndText("lexi-1143", result: .stored(.preparing)) == "The setup of the workspace lexi-1143 ended without a result. The workspace stays in Preparing.")
        #expect(NexusEngine.setupEndText("lexi-1143", result: .workspaceRemoved) == "The setup of the workspace lexi-1143 ended. The workspace was removed during the setup.")
        #expect(NexusEngine.setupEndText("lexi-1143", result: .notSaved) == "Nexus could not save the result of the setup of the workspace lexi-1143. The workspace stays in Preparing.")
    }

    @Test func theRemovalOfADatabaseServerNamesItsDumps() {
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: "/data/workspaces/A/mysql-8.4", port: 20009, account: .newInstance)
        let removal = DatabaseRemoval(server: server, databases: ["shop"], workspace: "lexi-1143", site: "/w")

        #expect(NexusEngine.removalText(of: removal, dumps: []) == "Nexus removed the database server mysql-8.4 of the workspace lexi-1143: no dump.")
        #expect(NexusEngine.removalText(of: removal, dumps: ["/trash/a.sql.gz"]) == "Nexus removed the database server mysql-8.4 of the workspace lexi-1143: dump /trash/a.sql.gz")
        #expect(NexusEngine.removalText(of: removal, dumps: ["/trash/b.sql.gz", "/trash/a.sql.gz"]) == "Nexus removed the database server mysql-8.4 of the workspace lexi-1143: dumps /trash/a.sql.gz, /trash/b.sql.gz")
        #expect(NexusEngine.removalFailureText(of: removal, reason: "Nexus updates mysql-8.4 now.") == "Nexus did not remove the database server mysql-8.4 of the removed workspace lexi-1143. Nexus updates mysql-8.4 now. Nexus tries again in an hour.")
    }

    @Test func aRemovalWithoutACloneRemovesOnlyTheRecordAndGivesNoLine() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: root.appending(path: "clones/A/mysql-8.4").path(percentEncoded: false), port: 51_003, account: .standard, isComplete: true)
        var state = EngineState()
        state.databaseRemovals = [DatabaseRemoval(server: server, databases: ["shop"], workspace: "gone", site: "/w/shop")]
        let engine = try makeSiteEngine(root: root, state: state, activity: activity)

        try await whileRunning(engine) {
            await engine.startDatabaseRemovals().value
            activity.waitForWrites()

            #expect(await engine.stateStore.current().databaseRemovals.isEmpty)
            #expect(!((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").contains("Nexus removed"))
        }
    }

    @Test func aReloadNamesItsCause() {
        #expect(WebChange.sites.reloadCause == "a change of the sites")
        #expect(WebChange.automatic.reloadCause == "a change of the parked folders or the workspaces")
        #expect(WebChange.setting.reloadCause == "a change of the web settings")
    }
}
