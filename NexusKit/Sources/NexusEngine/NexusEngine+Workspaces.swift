import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusWorkspaces

// Worktree detection (D40, part 8b). nexusd watches the .git folder of each site, also without
// the app. git writes much to that folder. So a change counts only when the admin folders in
// .git/worktrees change. `git worktree list` then decides.
extension NexusEngine {
    func stopWatchingWorktrees() {
        worktreeWatcher?.stop()
        worktreeWatcher = nil
        watchingStopped = true
    }

    func workspaceSitesChanged() async {
        let sites = resolvedSites(await stateStore.current()).map(\.site)
        let repositories = Set(sites.compactMap { ProjectFolder.repository(of: $0)?.root })
        let plainFolders = Set(sites.filter { ProjectFolder.repository(of: $0) == nil }.map(ProjectFolder.projectFolder(of:)))

        guard !watchingStopped else {
            return
        }

        if repositories != watchedRepositories || plainFolders != watchedPlainFolders {
            watch(repositories, plainFolders: plainFolders)
        }

        await reconcileWorkspaces()
    }

    // A site without a repository can get one later. git init then changes the folder itself. A
    // change deeper in that folder does not matter.
    private func watch(_ repositories: Set<String>, plainFolders: Set<String>) {
        worktreeWatcher?.stop()
        watchedRepositories = repositories
        watchedPlainFolders = plainFolders
        worktreeSignature = Self.signature(of: repositories)

        let gitFolders = repositories.map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: ".git", directoryHint: .isDirectory) }
        let folders = plainFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }

        worktreeWatcher = FolderWatcher(folders: gitFolders + folders) { [weak self] changed in
            let paths = changed.map(RealPath.trimmed)

            if paths.contains(where: plainFolders.contains) {
                Task { await self?.workspaceSitesChanged() }
            }

            if paths.contains(where: { $0.hasSuffix("/.git") || $0.contains("/.git/worktrees") }) {
                Task { await self?.worktreeFoldersChanged() }
            }
        }
    }

    private func worktreeFoldersChanged() async {
        guard !watchingStopped else {
            return
        }

        let signature = Self.signature(of: watchedRepositories)

        if signature != worktreeSignature {
            worktreeSignature = signature
            await reconcileWorkspaces()
        }

        // A checkout, a pull or a merge in a worktree changes no workspace and nothing that git
        // lists. It can still add the public folder. That changes the document root.
        if await applyWorkspaceSites() {
            publishSites()
        }
    }

    // What git lists for each admin folder. The end of git worktree add writes the index. The end
    // of git worktree add --no-checkout writes no index, so only the lock changes. The lock alone
    // is not enough, because it can come back at once: claude --worktree locks the worktree after
    // git adds it. git worktree move changes gitdir. A new branch changes HEAD.
    private static func signature(of repositories: Set<String>) -> [String] {
        let fileManager = FileManager.default

        return repositories.sorted().flatMap { repository in
            let folder = "\(repository)/.git/worktrees"
            let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []

            return names.sorted().map { name in
                let admin = "\(folder)/\(name)"
                let gitdir = (try? String(contentsOfFile: "\(admin)/gitdir", encoding: .utf8)) ?? ""
                let head = (try? String(contentsOfFile: "\(admin)/HEAD", encoding: .utf8)) ?? ""

                return "\(admin) \(fileManager.fileExists(atPath: "\(admin)/index")) \(fileManager.fileExists(atPath: "\(admin)/locked")) \(gitdir) \(head)"
            }
        }
    }

    // One run at a time, because two runs could give one worktree two workspaces. A trigger
    // during a run gives one more run.
    func reconcileWorkspaces() async {
        guard !reconcilingWorkspaces else {
            reconcileAgain = true
            return
        }

        reconcilingWorkspaces = true
        defer { reconcilingWorkspaces = false }

        repeat {
            reconcileAgain = false

            if await reconcileWorktrees() {
                await applyWorkspaceSites()
                publishSites()
            }
        } while reconcileAgain
    }

    // A new workspace needs its server block. A change that gives the same blocks does nothing.
    // Returns true after a change, and after a failure that the app must show.
    @discardableResult
    private func applyWorkspaceSites() async -> Bool {
        let changed = try? await serialWeb {
            guard await !self.watchingStopped else {
                return false
            }

            return try await self.applySitesIfChanged()
        }

        return changed ?? true
    }

    // Each workspace runs as a site with its own hosts. A site claims its hosts first. A workspace
    // whose host is taken is left out with a warning, because two server blocks with one name
    // make nginx use only one of them. Two sites of one project share a block.
    func workspaceSites(_ state: EngineState, resolved: [Site]? = nil) -> (sites: [Site], conflicts: [Workspace: String], sitesOfRecord: [String: [Site]]) {
        let resolved = resolved ?? resolvedSites(state).map(\.site)
        let sitesOfRecord = Dictionary(grouping: resolved, by: ProjectFolder.workspaceKey(of:))
        var claimed = Set(resolved.flatMap(\.hosts))
        var sites: [Site] = []
        var conflicts: [Workspace: String] = [:]

        for (key, sitesOfProject) in sitesOfRecord.sorted(by: { $0.key < $1.key }) {
            for workspace in state.worktrees[key]?.workspaces ?? [] {
                guard let site = workspace.site(of: sitesOfProject, tld: state.tld) else {
                    continue
                }

                if let taken = site.hosts.first(where: claimed.contains) {
                    conflicts[workspace] = "The workspace \(workspace.name) does not run, because another site has the host \(taken) already."
                    continue
                }

                claimed.formUnion(site.hosts)
                sites.append(site)
            }
        }

        return (sites, conflicts, sitesOfRecord)
    }

    func workspaceInfo(key: String, sitesOfRecord: [String: [Site]], conflicts: [Workspace: String], installed: [InstalledRuntime], state: EngineState) -> [WorkspaceInfo] {
        let sites = sitesOfRecord[key] ?? []

        return (state.worktrees[key]?.workspaces ?? []).map { workspace in
            let site = workspace.site(of: sites, tld: state.tld)
            let problem = conflicts[workspace] ?? site.flatMap { Self.problem(of: $0, installed: installed) ?? applyProblem(of: $0) }

            return WorkspaceInfo(
                name: workspace.name,
                worktree: workspace.worktree,
                folder: workspace.folder,
                branch: workspace.branch,
                hosts: site?.hosts ?? [],
                url: problem == nil ? site.map { Self.url(for: $0.host, in: state) } : nil,
                problem: problem
            )
        }
    }

    // A site whose worktrees git cannot list keeps what it has. Only a list from git can remove
    // a workspace (D53). A site that went away takes its record with it. A folder that does not
    // exist now keeps its record, because a disk that is not connected also removes the site. Two
    // sites can share a project and so one record. A worktree of that project gets a workspace
    // when the setting of one of these sites is on. A site without a repository gets an empty
    // record. So a worktree after a later git init counts as new.
    private func reconcileWorktrees() async -> Bool {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)
        let sitesOfRecord = Dictionary(grouping: sites, by: ProjectFolder.workspaceKey(of:))
        let projects = Set(sites.map(ProjectFolder.projectFolder(of:)))
        var worktrees = state.worktrees.filter { key, _ in
            sitesOfRecord[key] != nil || !FileManager.default.fileExists(atPath: key)
        }
        let repositories = sitesOfRecord.compactMapValues { $0.lazy.compactMap(ProjectFolder.repository(of:)).first }
        let lists = await Self.worktreeLists(of: Set(repositories.values.map(\.root)))

        for (key, sites) in sitesOfRecord {
            guard let repository = repositories[key] else {
                worktrees[key] = worktrees[key] ?? SiteWorktrees()
                continue
            }

            guard let listed = lists[repository.root] else {
                continue
            }

            worktrees[key] = WorkspacePlanner.update(
                state.worktrees[key],
                listed: listed,
                automatic: sites.contains(where: \.createsWorkspaces),
                subfolder: repository.subfolder,
                excluded: projects.subtracting(sites.map(ProjectFolder.projectFolder(of:))),
                folderExists: { FileManager.default.fileExists(atPath: $0) }
            )
        }

        guard worktrees != state.worktrees else {
            return false
        }

        let updated = worktrees
        try? await stateStore.update { $0.worktrees = updated }
        return true
    }

    // A repository that git cannot read has no entry.
    private static func worktreeLists(of repositories: Set<String>) async -> [String: [Worktree]] {
        guard !repositories.isEmpty, let git = await GitTool.executable() else {
            return [:]
        }

        return await withTaskGroup(of: (String, [Worktree]?).self) { group in
            for repository in repositories {
                group.addTask { (repository, try? await WorktreeList.read(repository: repository, git: git)) }
            }

            var lists: [String: [Worktree]] = [:]

            for await (repository, listed) in group {
                lists[repository] = listed
            }

            return lists
        }
    }
}
