import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusWorkspaces

// Old workspaces (owner, 2026-11-15). nexusd reads the signs of git only when the sheet or nexus
// workspace list --old asks. One git status takes about 27 ms. The app asks each hour for the
// notifications that are due. nexusd keeps the time of each one in its state. So a restart of
// nexusd or of the app sends none again before its time.
extension NexusEngine {
    func oldWorkspaces(host: String, days requested: Int?, now: Date = .now) async throws -> OldWorkspaceList {
        let state = await stateStore.current()
        let days = requested ?? state.workspaceSettings.oldAfterDays

        guard days >= OldWorkspaces.minimumDays else {
            throw RuntimeError.unsupported(OldWorkspaces.tooFewDaysText)
        }

        let resolved = resolvedSites(state).map(\.site)

        guard let site = resolved.first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let key = ProjectFolder.workspaceKey(of: site)
        let sites = resolved.filter { ProjectFolder.workspaceKey(of: $0) == key }
        let old = oldTrackedWorkspaces(key: key, sites: sites, state: state, days: days, now: now)

        // The line of the Site screen then counts the same workspaces as this list.
        publishSites()

        guard !old.isEmpty else {
            return OldWorkspaceList(host: host, days: days, dumpDays: state.workspaceSettings.dumpDays, mainBranch: nil, workspaces: [])
        }

        guard let repository = ProjectFolder.repository(of: site)?.root else {
            throw RuntimeError.unsupported("\(host) has no git repository.")
        }

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        async let listedWorktrees = WorktreeList.read(repository: repository, git: git)
        async let branchStates = GitTool.branchStates(repository: repository, git: git)
        async let mainBranch = GitTool.currentBranch(repository: repository, git: git)
        let listed = try await listedWorktrees
        let branches = try await branchStates
        let workspaces = await Self.oldWorkspaces(old, listed: listed, branches: branches, git: git)

        return OldWorkspaceList(
            host: host,
            days: days,
            dumpDays: state.workspaceSettings.dumpDays,
            mainBranch: await mainBranch,
            workspaces: workspaces
        )
    }

    // git status runs in each old workspace. A project can have 24 workspaces. So at most 4 runs go
    // at the same time.
    private static let workspaceReadsAtOnce = 4

    // The task group gives the workspaces in the order of their end. The index keeps the order of
    // the record for two workspaces with the same time.
    private static func oldWorkspaces(_ old: [(tracked: TrackedWorkspace, activity: WorkspaceActivity)], listed: [Worktree], branches: [String: BranchState], git: URL) async -> [OldWorkspace] {
        let found = await withTaskGroup(of: (index: Int, workspace: OldWorkspace).self) { group in
            var found: [(index: Int, workspace: OldWorkspace)] = []

            for (index, entry) in old.enumerated() {
                if index >= workspaceReadsAtOnce, let done = await group.next() {
                    found.append(done)
                }

                let worktree = listed.first { $0.path == entry.tracked.workspace.worktree }
                group.addTask { (index, await oldWorkspace(entry.tracked.workspace, activity: entry.activity, listed: worktree, branches: branches, git: git)) }
            }

            for await done in group {
                found.append(done)
            }

            return found
        }

        return found.sorted { ($0.workspace.activity.date, $0.index) < ($1.workspace.activity.date, $1.index) }.map(\.workspace)
    }

    // A worktree that git cannot read gives its error, and its row cannot go. git would refuse its
    // removal too. git removes the admin folder of a worktree whose folder is gone, also with
    // changes or submodules. So these checks run only while the folder is there.
    private static func oldWorkspace(_ workspace: Workspace, activity: WorkspaceActivity, listed: Worktree?, branches: [String: BranchState], git: URL) async -> OldWorkspace {
        let folderGone = listed?.prunable == true || !FileManager.default.fileExists(atPath: workspace.worktree)
        let branch = workspace.branch.flatMap { branches[$0] }
        var changes = 0
        var problem: String?
        var submodules = false

        if !folderGone {
            do {
                changes = try await GitTool.changeCount(in: workspace.worktree, git: git)
            } catch {
                problem = ErrorText.plain(error)
            }

            submodules = await GitTool.hasSubmodules(worktree: workspace.worktree, git: git)
        }

        return OldWorkspace(
            name: workspace.name,
            branch: workspace.branch,
            worktree: workspace.worktree,
            activity: activity,
            hasDatabases: !workspace.databases.isEmpty,
            merged: branch?.merged ?? false,
            branchGone: branch?.gone ?? false,
            commitsNotPushed: branch?.ahead ?? 0,
            changesNotCommitted: changes,
            locked: listed.map(\.locked) ?? workspace.locked,
            hasSubmodules: submodules,
            folderGone: folderGone,
            gitProblem: problem
        )
    }

    // The notifications that are due now (owner, 2026-11-15). "Old after" decides the first
    // notification too. nexusd notes each one as sent before the answer. A record without old
    // workspaces goes. So its next old workspace gives a notification at once. The app asks only
    // while its switch "When workspaces are old" is on.
    func dueOldWorkspaceNotices(now: Date = .now) async throws -> [OldWorkspacesNotice] {
        let state = await stateStore.current()
        let settings = state.workspaceSettings
        let resolved = resolvedSites(state).map(\.site)
        var records: [String: OldWorkspacesNoticeRecord] = [:]
        var notices: [OldWorkspacesNotice] = []

        for (key, sites) in Dictionary(grouping: resolved, by: ProjectFolder.workspaceKey(of:)).sorted(by: { $0.key < $1.key }) {
            let names = oldTrackedWorkspaces(key: key, sites: sites, state: state, days: settings.oldAfterDays, now: now)
                .map(\.tracked.workspace.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            guard !names.isEmpty else {
                continue
            }

            let last = state.oldWorkspaceNotices[key]

            guard OldWorkspaces.noticeIsDue(old: names, last: last, everyDays: settings.notifyOldEvery, now: now) else {
                records[key] = last.map { OldWorkspacesNoticeRecord(names: $0.names.filter(names.contains), sent: $0.sent) }
                continue
            }

            notices.append(OldWorkspacesNotice(host: sites[0].host, names: names, days: settings.oldAfterDays))
            records[key] = OldWorkspacesNoticeRecord(names: names, sent: now)
        }

        if records != state.oldWorkspaceNotices {
            try await stateStore.update { $0.oldWorkspaceNotices = records }
        }

        // The lines of the Site screens get the new times of the last activity once each hour.
        publishSites()
        return notices
    }
}
