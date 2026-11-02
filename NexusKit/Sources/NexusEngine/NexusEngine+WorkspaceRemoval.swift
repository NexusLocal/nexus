import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

struct DatabaseRemovalProblem {
    let reason: String
    let nextTry: ContinuousClock.Instant
}

// The end of a workspace (D53). The state names each server that must go, so a stop of nexusd loses
// none. A dump can take minutes, so this work runs next to the watch of the worktrees. A clone
// without a complete dump stays. Nexus tries it again after an hour and at the next start of nexusd.
extension NexusEngine {
    private static let removalRetryWait: Duration = .seconds(3600)
    private static let workspaceRemovalWait: Duration = .seconds(300)
    private static let dumpExtensions = DatabaseKind.allCases.map { ".\($0.dumpExtension)" }

    // D53: Nexus removes a workspace only when git no longer lists the worktree. So this request asks
    // git. git also refuses a worktree with changes. Those are the work of the user. The answer comes
    // after the dump. So a script can go on with the trash.
    func removeWorkspace(host: String, name: String, force: Bool) async throws -> String {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).first(where: { $0.site.hosts.contains(host) })?.site else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let key = ProjectFolder.workspaceKey(of: site)

        guard var workspace = state.worktrees[key]?.workspaces.first(where: { $0.name == name }) else {
            throw RuntimeError.unsupported("\(host) has no workspace \(name).")
        }

        guard let repository = ProjectFolder.repository(of: site) else {
            throw RuntimeError.unsupported("\(host) has no git repository. So git cannot remove the worktree of \(name).")
        }

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        let earlierDumps = Set(dumps().map(\.name))
        let arguments = ["-C", repository.root, "worktree", "remove"] + (force ? ["--force"] : []) + [workspace.worktree]

        do {
            _ = try await CommandRunner.run(Command(executable: git, arguments: arguments))
        } catch let failure as CommandError {
            throw RuntimeError.unsupported("git did not remove the worktree. So the workspace stays. \(failure)")
        }

        // A check that runs now gets one more run. That check can wait for the checks of other
        // workspaces. So this request waits until the record is gone. A setup can start a clone while
        // git runs. So the last record names the servers and not the first one.
        let deadline = ContinuousClock.now + Self.workspaceRemovalWait
        let worktree = workspace.worktree

        func listedRecord() async -> Workspace? {
            await stateStore.current().worktrees[key]?.workspaces.first { $0.name == name && $0.worktree == worktree }
        }

        while !watchingStopped, ContinuousClock.now < deadline, let record = await listedRecord() {
            workspace = record
            await reconcileWorkspaces()
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard await listedRecord() == nil else {
            return "git removed the worktree of \(name). Nexus removes the workspace and its databases later."
        }

        await startDatabaseRemovals().value

        let removals = workspace.databaseRemovals(site: key)
        let dumpNames = removals.flatMap { removal in
            removal.databases.map { "-\(removal.server.instance)-\(Workspace.databaseName($0, workspace: name))." }
        }
        let newDumps = dumps().map(\.name).filter { dump in
            !earlierDumps.contains(dump) && dumpNames.contains(where: dump.contains)
        }
        let answer = (["The workspace \(name) is removed."] + newDumps.map { "The trash keeps \($0)." }).joined(separator: "\n")

        // The workspace is gone, but a script must not count on a dump that does not exist.
        if let problem = databaseRemovalProblem(ofSite: key, in: await stateStore.current(), of: Set(removals.map(\.server.folder))) {
            throw RuntimeError.unsupported("\(answer)\n\(problem)")
        }

        return answer
    }

    // A request during a run gives one more pass, because the run can have passed the removal that
    // this request waits for.
    func startDatabaseRemovals() -> Task<Void, Never> {
        if let running = databaseRemovalRun {
            databaseRemovalsAgain = true
            return running
        }

        let run = Task { await runDatabaseRemovals() }
        databaseRemovalRun = run
        return run
    }

    private func runDatabaseRemovals() async {
        var dumpDays: Int

        repeat {
            databaseRemovalsAgain = false

            while !watchingStopped, let next = await nextDatabaseRemoval() {
                let folder = next.server.folder

                do {
                    try await remove(next)
                    dumpsOfRemovals = dumpsOfRemovals.filter { !$0.key.hasPrefix("\(folder)\n") }
                    try await stateStore.update { $0.databaseRemovals.removeAll { $0 == next } }
                    databaseRemovalProblems[folder] = nil
                } catch {
                    databaseRemovalProblems[folder] = DatabaseRemovalProblem(reason: String(describing: error), nextTry: .now + Self.removalRetryWait)
                    writeToLog(of: next.server.instance, "Nexus did not remove the server of the workspace \(next.workspace). \(error)\n")
                }

                publishSites()
            }

            // A save that fails can remove an entry and still give a problem. A problem without an
            // entry would give a new run at once, and that run would change nothing.
            let state = await stateStore.current()

            dumpDays = state.workspaceSettings.dumpDays
            databaseRemovalProblems = databaseRemovalProblems.filter { problem in
                state.databaseRemovals.contains { $0.server.folder == problem.key }
            }
        } while databaseRemovalsAgain && !watchingStopped

        databaseRemovalRun = nil
        removeOldDumps(after: dumpDays)
        scheduleDatabaseRemovalRetry()
    }

    private func nextDatabaseRemoval() async -> DatabaseRemoval? {
        await stateStore.current().databaseRemovals.first { removal in
            databaseRemovalProblems[removal.server.folder].map { $0.nextTry <= .now } ?? true
        }
    }

    // Nothing else starts a run when the worktrees do not change.
    private func scheduleDatabaseRemovalRetry() {
        databaseRemovalRetry?.cancel()
        databaseRemovalRetry = nil

        guard !watchingStopped, let nextTry = databaseRemovalProblems.values.map(\.nextTry).min() else {
            return
        }

        databaseRemovalRetry = Task { [weak self] in
            guard (try? await Task.sleep(until: nextTry, clock: .continuous)) != nil else {
                return
            }

            _ = await self?.startDatabaseRemovals()
        }
    }

    // A setup can still clone for this record, and a folder that comes after this step would stay for
    // ever. The server stops before its clone goes.
    private func remove(_ removal: DatabaseRemoval) async throws {
        let server = removal.server

        // An update can replace the package, so this check comes before the check of the package.
        guard !updatingServices.contains(server.instance) else {
            throw RuntimeError.unsupported("Nexus updates \(server.instance) now.")
        }

        while cloningServers.contains(server.folder) {
            setupIsOutdated = true
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard FileManager.default.fileExists(atPath: Self.cloneFolder(of: server)) else {
            return
        }

        if removal.keepsDump, FileManager.default.fileExists(atPath: server.folder) {
            try await writeDumps(of: removal)
        }

        removingServers.insert(server.folder)
        defer { removingServers.remove(server.folder) }

        await syncBackgroundProcesses().value
        try await Self.removeClone(of: server)
    }

    private func writeDumps(of removal: DatabaseRemoval) async throws {
        let server = removal.server

        guard let tools = await databaseRuntime(server.instance) else {
            throw RuntimeError.unsupported("\(server.instance) is not installed, so Nexus cannot make a dump. Install it again.")
        }

        await syncBackgroundProcesses().value
        try await waitForServer(tools, port: server.port)

        let (client, work) = try serverClient(tools, server)
        defer { try? FileManager.default.removeItem(at: work) }

        let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)

        try copier.prepare()

        for database in removal.databases {
            let name = try DatabaseName.validated(database)
            let key = "\(server.folder)\n\(database)"

            guard try await copier.exists(name), !hasDump(key) else {
                continue
            }

            dumpsOfRemovals[key] = try await writeDump(of: name, as: Workspace.databaseName(database, workspace: removal.workspace), with: copier, instance: server.instance, kind: tools.kind)
        }
    }

    // The trash can have removed an earlier dump before a retry.
    private func hasDump(_ key: String) -> Bool {
        dumpsOfRemovals[key].map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    private func writeDump(of name: String, as fileName: String, with copier: DatabaseCopier, instance: String, kind: DatabaseKind) async throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let file = paths.trash.appending(path: "\(formatter.string(from: .now))-\(instance)-\(fileName).\(kind.dumpExtension)", directoryHint: .notDirectory)

        try FileManager.default.createDirectory(at: paths.trash, withIntermediateDirectories: true)

        try await runTask(.dumpDatabase(name: name, instance: instance), stopped: { "The dump of \(name) stopped. \(instance) keeps the database." }) { progress in
            let estimating = copier.estimate(name, into: progress)
            defer { estimating.cancel() }

            try await copier.dump(name, to: file, progress: progress)
        }

        return file
    }

    // A stop of nexusd also stops the database of a running dump.
    func stopDumps() {
        databaseRemovalRetry?.cancel()
        trashCheck?.cancel()

        for task in runningTasks.values {
            if case .dumpDatabase = task.work {
                task.cancel()
            }
        }
    }

    func databaseRemovalProblem(ofSite site: String, in state: EngineState, of folders: Set<String>? = nil) -> String? {
        let removals = state.databaseRemovals.filter { $0.site == site && folders?.contains($0.server.folder) != false }
        let problems = removals.compactMap { removal in
            databaseRemovalProblems[removal.server.folder].map { "Nexus did not remove the database server of the removed workspace \(removal.workspace). \($0.reason) Nexus tries again in an hour." }
        }

        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // Each host that no site and no workspace has now. This also covers a removed site, because this
    // check does not need the record of a site. The first check of a start of nexusd only reads the
    // hosts. So a file from before that start stays. A parked folder on a disk that is not connected
    // lists no sites, and its hosts come back with that disk.
    func removeFilesOfGoneHosts() async {
        let state = await stateStore.current()

        guard state.parked.allSatisfy({ FileManager.default.fileExists(atPath: $0.folder.path(percentEncoded: false)) }) else {
            return
        }

        let resolved = resolvedSites(state).map(\.site)
        let hosts = Set((resolved + workspaceSites(state, resolved: resolved).sites).flatMap(\.hosts))
        let gone = knownHosts.map { $0.subtracting(hosts) } ?? []

        knownHosts = hosts

        for host in gone {
            let files = [
                paths.log("workspace-\(host)"),
                paths.log("main-\(host)"),
                paths.siteLog(host),
                paths.certs.appending(path: "\(host).crt"),
                paths.certs.appending(path: "\(host).key"),
            ]

            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    func dumps() -> [DatabaseDump] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.trash, includingPropertiesForKeys: keys)) ?? []

        return files
            .filter { file in Self.dumpExtensions.contains { file.lastPathComponent.hasSuffix($0) } }
            .compactMap { file in
                guard let values = try? file.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate else {
                    return nil
                }

                return DatabaseDump(name: file.lastPathComponent, path: file.path(percentEncoded: false), bytes: Int64(values.fileSize ?? 0), date: date)
            }
            .sorted { $0.date > $1.date }
    }

    // A Mac can run for weeks without a change in Nexus, and the trash can hold gigabytes.
    func startTrashChecks() {
        guard trashCheck == nil else {
            return
        }

        trashCheck = Task { [weak self, wait = trashCheckWait] in
            while (try? await Task.sleep(for: wait)) != nil, let engine = self {
                await engine.checkTrash()
            }
        }
    }

    private func checkTrash() async {
        removeOldDumps(after: await stateStore.current().workspaceSettings.dumpDays)
    }

    func removeOldDumps(after days: Int) {
        let limit = Date.now.addingTimeInterval(-Double(days) * 86_400)

        for dump in dumps() where dump.date < limit {
            try? FileManager.default.removeItem(atPath: dump.path)
        }

        // A crash during a dump leaves this file.
        guard databaseRemovalRun == nil else {
            return
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: paths.trash, includingPropertiesForKeys: nil)) ?? []

        files.filter { $0.lastPathComponent.hasSuffix(".partial") }.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func emptyTrash() throws -> String {
        let all = dumps()

        for dump in all {
            try FileManager.default.removeItem(atPath: dump.path)
        }

        return all.isEmpty ? "The trash is empty." : "Nexus removed \(Self.count(all.count, "dump")) from the trash."
    }

    func setWorkspaceSettings(_ settings: WorkspaceSettings) async throws -> String {
        guard settings.dumpDays >= 1 else {
            throw RuntimeError.unsupported("The trash keeps a dump for at least 1 day.")
        }

        try await stateStore.update { $0.workspaceSettings = settings }
        removeOldDumps(after: settings.dumpDays)
        return "The settings of the workspaces are changed."
    }

    func restoreDump(_ file: String, instance: String, name: String) async throws -> String {
        guard let tools = await databaseRuntime(instance) else {
            throw RuntimeError.unsupported("Nexus has no database instance \(instance). See: nexus db list")
        }

        let dump = file.contains("/") ? URL(filePath: file) : paths.trash.appending(path: file)
        let validName = try DatabaseName.validated(name)

        guard FileManager.default.fileExists(atPath: dump.path(percentEncoded: false)) else {
            throw RuntimeError.unsupported("Nexus has no dump \(file). See: nexus db dumps")
        }

        guard dump.lastPathComponent.hasSuffix(".\(tools.kind.dumpExtension)") else {
            throw RuntimeError.unsupported("\(dump.lastPathComponent) is no dump for \(tools.kind.displayName). Use an instance of the kind that made the dump.")
        }

        let target = try reserveCopyTarget(validName, on: instance, for: "restore")
        defer { copyTargets.remove(target) }

        if await supervisor.state(of: instance)?.isActive != true {
            _ = try await serialWeb { try await self.start(instance) }
        }

        let (_, client, work) = try await runningClient(instance)
        defer { try? FileManager.default.removeItem(at: work) }

        let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)

        try copier.prepare()

        guard try await !copier.exists(validName) else {
            throw RuntimeError.unsupported("\(instance) has a database \(validName) already. Give the restore another name with --as.")
        }

        try await copier.restore(dump, as: validName)
        return "\(dump.lastPathComponent) is restored into \(instance) as \(validName)."
    }
}
