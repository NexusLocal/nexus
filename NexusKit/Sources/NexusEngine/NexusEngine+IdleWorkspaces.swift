import Foundation
import NexusCore
import NexusIPC
import NexusRuntime

// One start of a workspace. begun ends when the supervisor has each server, or with the reason why
// nothing starts. ready ends when the servers take connections, or with the reason of a failure.
struct WorkspaceStart {
    let begun: Task<String?, Never>
    let ready: Task<String?, Never>
}

// The servers that one start began, with the reason of a refusal or of a failed start. ready waits
// for these servers. So one start reads the installed runtimes one time.
struct ServerStart: Sendable {
    var problem: String?
    var servers: [WorkspaceServerEntry] = []
}

// A check each minute stops each workspace without activity for the time of "Stop after". A page, a
// command through Nexus, a request that names the workspace and a database connection start it
// again. A stop or a start covers all parts: the servers, the background processes and the Node.js
// app (owner, 2026-11-15). The Node.js app and the dev server then wait for the first page, as after
// a start of nexusd.
extension NexusEngine {
    static let servicesStoppedText = "The services of Nexus are stopped. So the database server of this workspace does not run. Start the services, and then try again."

    static func updateText(_ instance: String) -> String {
        "Nexus updates \(instance) now. Try again after the update."
    }

    // MARK: Activity

    func noteActivity(owner: String) {
        activityTimes[owner] = .now
    }

    // A request of nexus, MCP or the app that names a workspace counts as activity.
    func noteActivity(host: String, workspace name: String) async {
        guard let found = try? await workspaceOfSite(host: host, name: name) else {
            return
        }

        noteActivity(owner: Self.processOwner(key: found.key, workspace: name))
    }

    // The record of a workspace of the site with this host.
    func workspaceOfSite(host: String, name: String) async throws -> (key: String, workspace: Workspace) {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let key = ProjectFolder.workspaceKey(of: site)

        guard let workspace = state.worktrees[key]?.workspaces.first(where: { $0.name == name }) else {
            throw RuntimeError.unsupported("\(host) has no workspace \(name).")
        }

        return (key, workspace)
    }

    // A command through a link of bin/ in a workspace counts as activity. A command in a stopped
    // workspace waits until the servers of the workspace take connections. A command of the setup
    // that runs now is no activity, because a setup is no work of the user. Returns the reason of a
    // failed start.
    func toolActivity(in place: ToolPlace) async -> String? {
        guard let found = place.workspace, found.workspace.worktree != runningSetupWorktree else {
            return nil
        }

        noteActivity(owner: Self.processOwner(key: found.key, workspace: found.workspace.name))

        // The checks of the command come before this step, and they can wait. So the current record
        // decides.
        guard let current = await record(found.workspace.name, key: found.key) else {
            return nil
        }

        return await startIfStopped(current, key: found.key, cause: "a command")?.ready.value
    }

    // A page of a stopped workspace starts it. The page itself is in the access log, so it needs no
    // time in memory. Each line of each access log comes here. So an owner outside stoppedOwners
    // returns before a read of the state. The first page reads the stopped records of the state.
    func startAfterPage(of owner: String) async {
        if !knowsStoppedOwners {
            stoppedOwners.formUnion(Self.ownersOfStoppedWorkspaces(in: await stateStore.current()))
            knowsStoppedOwners = true
        }

        guard stoppedOwners.contains(owner) else {
            return
        }

        guard let found = Self.workspace(ofOwner: owner, in: await stateStore.current()) else {
            return
        }

        _ = await startIfStopped(found.workspace, key: found.key, cause: "a page")?.begun.value
    }

    static func ownersOfStoppedWorkspaces(in state: EngineState) -> Set<String> {
        Set(state.worktrees.flatMap { key, record in
            record.workspaces.filter { $0.runState == .stopped }.map { processOwner(key: key, workspace: $0.name) }
        })
    }

    // The main checkout has no record. So its owner gives nil.
    static func workspace(ofOwner owner: String, in state: EngineState) -> (key: String, workspace: Workspace)? {
        for (key, record) in state.worktrees {
            if let workspace = record.workspaces.first(where: { processOwner(key: key, workspace: $0.name) == owner }) {
                return (key, workspace)
            }
        }

        return nil
    }

    // MARK: The start

    // The one start of a stopped workspace. The servers start past the sync, because a sync can wait
    // 30 seconds for a probe. A start during a start gives that start. A workspace that runs gives nil
    // and no start. The caller reads the record, so this function has no wait before it stores the
    // start.
    func startIfStopped(_ workspace: Workspace, key: String, cause: String) -> WorkspaceStart? {
        let owner = Self.processOwner(key: key, workspace: workspace.name)

        if let running = workspaceStarts[owner] {
            return running
        }

        guard workspace.runState == .stopped else {
            return nil
        }

        let name = workspace.name
        let starting = Task { await self.startServers(of: name, key: key, owner: owner, cause: cause) }
        let begun = Task { await starting.value.problem }
        let ready = Task {
            let started = await starting.value
            let problem: String?

            if let refusal = started.problem {
                problem = refusal
            } else {
                self.stoppedOwners.remove(owner)
                problem = await self.waitForServers(started.servers)
            }

            self.workspaceStarts[owner] = nil
            self.publishSites()
            return problem
        }
        let start = WorkspaceStart(begun: begun, ready: ready)

        workspaceStarts[owner] = start
        return start
    }

    // The servers of the workspace start here, and the sync at the end starts its background
    // processes. A refusal changes nothing, so the workspace stays stopped. An entry in
    // runningProcesses before the first wait keeps a sync from a second start of the same server.
    private func startServers(of name: String, key: String, owner: String, cause: String) async -> ServerStart {
        guard let record = await stateStore.current().worktrees[key]?.workspaces.first(where: { $0.name == name }) else {
            return ServerStart(problem: "Nexus has no workspace \(name) now.")
        }

        guard record.runState == .stopped else {
            return ServerStart()
        }

        if let refusal = await serverStartRefusal(of: record.servers.map(\.instance)) {
            return ServerStart(problem: refusal)
        }

        do {
            try await updateRecord(of: name, key: key) { record in
                record.runState = .running
                record.stoppedAfter = nil
            }
        } catch {
            return ServerStart(problem: ErrorText.plain(error))
        }

        // A workspace that a database connection started stays awake for the full idle time
        // (owner, 2026-11-15). A connection is no activity, so the start has its own time.
        lastStarts[owner] = .now
        activity?.write("workspace", "Nexus starts the workspace \(name): \(cause).")
        publishSites()

        let servers = await workspaceServers(await stateStore.current())
        var start = ServerStart(servers: servers.filter { entry in record.servers.contains { $0.folder == entry.server.folder } })

        for process in workspaceServerProcesses(servers) where process.owner == owner && runningProcesses[process.definition.id] == nil {
            if let reason = await startProcess(process) {
                start.problem = start.problem ?? reason
            }
        }

        _ = syncBackgroundProcesses()

        // A change of the links of a WordPress workspace waits for its servers. It can be left from
        // a stop of nexusd during that change.
        if record.links?.done == false {
            await startLinkChanges()
        }

        return start
    }

    // The sync starts no server while the services are stopped or while an update of its instance
    // runs.
    private func serverStartRefusal(of instances: [String]) async -> String? {
        if await servicesAreStopped() {
            return Self.servicesStoppedText
        }

        return instances.first { updatingServices.contains($0) }.map(Self.updateText)
    }

    private func waitForServers(_ servers: [WorkspaceServerEntry]) async -> String? {
        for entry in servers {
            do {
                try await waitForServer(entry.tools, port: entry.server.port)
            } catch {
                return ErrorText.plain(error)
            }
        }

        return nil
    }

    // The gate of plan item 3e calls this for a new connection to the port of a stopped server. A
    // database connection is no activity (owner, 2026-11-15). The start gives the workspace its
    // idle time.
    func wake(_ server: GatedServer) async -> String? {
        guard let found = await workspace(holding: server) else {
            return Self.serverWithoutWorkspaceText
        }

        if let start = startIfStopped(found.workspace, key: found.key, cause: "a database connection") {
            return await start.begun.value
        }

        // The workspace runs, but the gate still holds the port of this server. The list of the last
        // sync can cause this. Only the sync can start it now. The gate then hands the port over to
        // it, and the client of this connection reaches the server. A sync can wait 30 seconds for a
        // probe, and the client waits that long too. So a known refusal comes before the sync.
        if let refusal = await serverStartRefusal(of: [server.instance]) {
            return refusal
        }

        await syncBackgroundProcesses().value

        guard runningProcesses[server.folder] == nil else {
            return nil
        }

        // The workspace can go during the sync, and its removal can stop this server.
        guard await workspace(holding: server) != nil else {
            return Self.serverWithoutWorkspaceText
        }

        return await serverStartRefusal(of: [server.instance]) ?? "It did not start. See \(server.log.path(percentEncoded: false))."
    }

    private static let serverWithoutWorkspaceText = "This database server belongs to no workspace now."

    private func workspace(holding server: GatedServer) async -> (key: String, workspace: Workspace)? {
        let state = await stateStore.current()
        let records = state.worktrees.flatMap { key, record in record.workspaces.map { (key: key, workspace: $0) } }

        return records.first { $0.workspace.servers.contains { $0.folder == server.folder } }
    }

    // Once, at the start of nexusd. A workspace that runs at that moment gets the whole idle time.
    func beginIdleStops() async {
        activityBaseline = .now

        await serverGate.begin { [weak self] server in
            guard let self else {
                return NexusEngine.gateEndText
            }

            return await self.wake(server)
        }
    }

    // MARK: The stop

    // One stop for each target and one sync for all. idleAfter is the setting at an idle stop, and nil
    // for a stop on request. A stop never changes "Stop when idle" (owner, 2026-11-15). A workspace in
    // Preparing does not stop, because its setup needs the servers. The Node.js app and the dev server
    // wait for the first page after the next start. Without a target that runs, nothing writes the
    // state. Returns the names that stopped.
    @discardableResult
    func stopWorkspaces(_ targets: [(key: String, name: String)], after idleAfter: WorkspaceIdleTime?, cause: String) async throws -> [String] {
        for target in targets {
            _ = await workspaceStarts[Self.processOwner(key: target.key, workspace: target.name)]?.ready.value
        }

        let running = Self.stoppable(targets, in: await stateStore.current())

        guard !running.isEmpty else {
            return []
        }

        // The owners go in before the save. So a page during the save reads the state, and it still
        // starts the workspace.
        stoppedOwners.formUnion(running.map { Self.processOwner(key: $0.key, workspace: $0.name) })

        let stopped: [(key: String, name: String)]
        var saveError: (any Error)?

        do {
            stopped = try await stateStore.update { state in Self.stop(running, after: idleAfter, in: &state) }
        } catch {
            // The store keeps the change in memory also when the save fails. So the processes still
            // follow that state, and the error comes after the sync.
            let current = await stateStore.current()

            saveError = error
            stopped = running.filter { target in
                current.worktrees[target.key]?.workspaces.contains { $0.name == target.name && $0.runState == .stopped } == true
            }
        }

        for target in stopped {
            let owner = Self.processOwner(key: target.key, workspace: target.name)

            startedOnDemand.remove(owner)
            lastOpenTab[owner] = nil
        }

        let names = stopped.map(\.name)

        if !names.isEmpty {
            activity?.write("workspace", "Nexus stops \(names.joined(separator: ", ")): \(cause).")
            await syncBackgroundProcesses().value
            publishSites()
        }

        if let saveError {
            throw saveError
        }

        return names
    }

    private static func stoppable(_ targets: [(key: String, name: String)], in state: EngineState) -> [(key: String, name: String)] {
        targets.filter { target in
            state.worktrees[target.key]?.workspaces.contains { $0.name == target.name && $0.runState == .running && $0.state != .preparing } == true
        }
    }

    private static func stop(_ targets: [(key: String, name: String)], after idleAfter: WorkspaceIdleTime?, in state: inout EngineState) -> [(key: String, name: String)] {
        let running = stoppable(targets, in: state)

        for target in running {
            guard let index = state.worktrees[target.key]?.workspaces.firstIndex(where: { $0.name == target.name }) else {
                continue
            }

            state.worktrees[target.key]?.workspaces[index].runState = .stopped
            state.worktrees[target.key]?.workspaces[index].stoppedAfter = idleAfter
        }

        return running
    }

    // MARK: The check each minute

    func startIdleChecks() {
        guard idleCheck == nil else {
            return
        }

        idleCheck = Task { [weak self, wait = idleCheckWait] in
            while (try? await Task.sleep(for: wait)) != nil, let engine = self {
                await engine.checkIdleWorkspaces()
            }
        }
    }

    // The check also sends a new site list, because the site list holds the last activity of each
    // workspace in whole minutes. nexusd sends it only when it changed. The main checkout has no
    // record, so it never stops. A test gives another now.
    func checkIdleWorkspaces(now: Date = .now) async {
        publishSiteList()

        let state = await stateStore.current()
        let setting = state.workspaceSettings.stopIdleAfter

        guard let limit = setting.duration, await !servicesAreStopped() else {
            return
        }

        let sitesOfRecord = Dictionary(grouping: resolvedSites(state).map(\.site), by: ProjectFolder.workspaceKey(of:))
        var due: [(key: String, name: String)] = []

        for key in state.worktrees.keys.sorted() {
            for tracked in trackedWorkspaces(key: key, sites: sitesOfRecord[key] ?? [], state: state) {
                let workspace = tracked.workspace

                guard workspace.runState == .running, !workspace.keepAwake, workspace.state != .preparing, workspaceStarts[tracked.owner] == nil, !nexusWorks(in: workspace, owner: tracked.owner) else {
                    continue
                }

                let last = [lastActivity(of: tracked)?.date, lastStarts[tracked.owner]].compactMap { $0 }.reduce(activityBaseline, max)

                if now.timeIntervalSince(last) >= limit {
                    due.append((key, workspace.name))
                }
            }
        }

        guard !due.isEmpty else {
            return
        }

        _ = try? await stopWorkspaces(due, after: setting, cause: "no activity for \(setting.title)")
    }

    // Nexus itself works in the workspace now, so its servers must run. A stop during the change of
    // the links of a WordPress workspace would leave the links of the main site in its posts. Each
    // file change in the worktree starts a short check for a removal by git. That check changes
    // nothing in the workspace. So only the idle check waits for it, and a stop on request does not
    // fail during it.
    private func nexusWorks(in workspace: Workspace, owner: String, includingRemovalCheck: Bool = true) -> Bool {
        runningSetupWorktree == workspace.worktree
            || runningCommand?.worktree == workspace.worktree
            || linkChanges[owner] != nil
            || dumpProgress[owner] != nil
            || removingWorktrees.contains(workspace.worktree)
            || includingRemovalCheck && checkingWorktrees.contains(workspace.worktree)
    }

    // MARK: The list for the gate

    // Each complete server of each stopped workspace, with a clone folder on disk and an installed
    // instance. The servers of a removal are not in it, because a removal needs its server.
    static func serversToHold(_ servers: [WorkspaceServerEntry]) -> Set<GatedServer> {
        Set(servers.filter(\.isStopped).map(\.gated))
    }

    // MARK: The requests

    func stopWorkspace(host: String, name: String) async throws -> String {
        let found = try await workspaceOfSite(host: host, name: name)

        if let answer = try Self.answerWithoutStop(found.workspace) {
            return answer
        }

        guard !nexusWorks(in: found.workspace, owner: Self.processOwner(key: found.key, workspace: name), includingRemovalCheck: false) else {
            throw RuntimeError.unsupported("Nexus works in the workspace \(name) now. Stop it when that work ends.")
        }

        guard try await stopWorkspaces([(found.key, name)], after: nil, cause: "a request").isEmpty else {
            return "Nexus stopped the workspace \(name). \(WorkspaceIdleText.startsAgain)"
        }

        // Another stop, a new setup or a removal can change the record during this stop. The stop
        // also waits for a start that runs now.
        let current = try await workspaceOfSite(host: host, name: name).workspace

        return try Self.answerWithoutStop(current) ?? "The workspace \(name) started again during the stop. Stop it again."
    }

    // nil for a workspace that can stop.
    private static func answerWithoutStop(_ workspace: Workspace) throws -> String? {
        guard workspace.state != .preparing else {
            throw RuntimeError.unsupported("Nexus sets up the workspace \(workspace.name) now. Stop it when it is ready.")
        }

        guard workspace.runState != .stopped else {
            return "The workspace \(workspace.name) is stopped already."
        }

        return nil
    }

    // The answer comes after the servers take connections.
    func startWorkspace(host: String, name: String, keepAwake: Bool?) async throws -> String {
        let found = try await workspaceOfSite(host: host, name: name)
        let start = startIfStopped(found.workspace, key: found.key, cause: "a request")

        if let keepAwake {
            try await updateRecord(of: name, key: found.key) { $0.keepAwake = keepAwake }
        }

        if let problem = await start?.ready.value {
            throw RuntimeError.unsupported(problem)
        }

        publishSites()

        let answer = start == nil ? "The workspace \(name) runs already." : "Nexus started the workspace \(name)."
        return keepAwake == true ? "\(answer) It does not stop when idle." : answer
    }

    func setKeepAwake(host: String, name: String, keepAwake: Bool) async throws -> String {
        let found = try await workspaceOfSite(host: host, name: name)

        try await updateRecord(of: name, key: found.key) { $0.keepAwake = keepAwake }
        publishSites()

        return keepAwake ? "The workspace \(name) does not stop when idle." : "The workspace \(name) stops when idle."
    }
}
