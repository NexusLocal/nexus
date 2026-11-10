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
        runningCommand?.task.cancel()
        worktreeWatchers = [:]
        configurationWatcher = nil
        wordPressWatcher?.stop()
        wordPressWatcher = nil
        stopDumps()
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

        watchWordPressSettings(of: sites)
        startTrashChecks()
        await reconcileWorkspaces()
    }

    // wp-config.php or the files of Bedrock give the kind of a WordPress network (Phase 4, 3g). A
    // network on subdomains needs the names below its host in nginx at once. FSEvents names the
    // folder of a change. So only these folders count.
    private func watchWordPressSettings(of sites: [Site]) {
        let folders = Set(sites.filter { PHPProject.type(of: $0).isWordPress }.flatMap(Self.wordPressSettingFolders))

        guard folders != watchedWordPressFolders else {
            return
        }

        wordPressWatcher?.stop()
        watchedWordPressFolders = folders
        wordPressWatcher = folders.isEmpty ? nil : FolderWatcher(folders: folders.map { URL(filePath: $0, directoryHint: .isDirectory) }) { [weak self] changed in
            guard changed.map(RealPath.trimmed).contains(where: folders.contains) else {
                return
            }

            Task {
                if await self?.applyWorkspaceSites() == true {
                    await self?.publishSites()
                }
            }
        }
    }

    private static func wordPressSettingFolders(of site: Site) -> [String] {
        let project = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)

        guard PHPProject.type(of: site) != .bedrock else {
            return [RealPath.of(project), RealPath.of(project.appending(path: "config", directoryHint: .isDirectory))]
        }

        let config = PHPProject.wordPressFolder(in: project).flatMap(WordPressFiles.configFile(core:))
        return [RealPath.of(config?.deletingLastPathComponent() ?? project)]
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

            let change = await reconcileWorktrees()
            let removed = change?.removed ?? [:]
            let removedIndexes = Set(removed.values.joined().flatMap(\.redisIndexesOnInstances))

            // No record names these indexes now. A setup that runs must not choose them before they
            // are empty. The server blocks do not wait for Redis, because a stopped Redis must start
            // first for this step.
            emptyingRedisIndexes.formUnion(removedIndexes)

            if removed.values.joined().contains(where: { $0.worktree == runningCommand?.worktree }) {
                runningCommand?.task.cancel()
            }

            if change?.changed ?? true {
                await applyWorkspaceSites()
                publishSites()
            }

            // A worktree can change while nexusd does not run. The check comes before the sync, so a
            // program does not start with a configuration that nobody checked.
            await checkConfigurations()

            // A worker of a removed workspace would write to its Redis index again.
            await syncBackgroundProcesses().value
            removed.values.joined().forEach(Self.removeViteCache)

            for (key, workspaces) in removed {
                await emptyRedisIndexes(of: workspaces, key: key)
            }

            emptyingRedisIndexes.subtract(removedIndexes)

            // A dump can take minutes, and a new workspace must not wait for it here.
            await removeFilesOfGoneHosts()
            _ = startDatabaseRemovals()

            // A workspace can wait for its setup without a change here: a record of part 8b, or a
            // setup that a stop of nexusd ended.
            startWorkspaceSetups()
        } while reconcileAgain
    }

    // A new workspace needs its server block, and a Node.js app in it needs its port there. A change
    // that gives the same blocks does nothing. Returns true after a change, and after a failure that
    // the app must show.
    @discardableResult
    func applyWorkspaceSites() async -> Bool {
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
    // make nginx use only one of them. Two sites of one project share a block. A workspace of a
    // proxy site is left out, because it would go to the server of the main checkout. A workspace
    // of a WordPress site that is not Ready gets a notice page in nginx (noticeHosts).
    func workspaceSites(_ state: EngineState, resolved: [Site]? = nil) -> (sites: [Site], conflicts: [Workspace: String], sitesOfRecord: [String: [Site]], noticeHosts: Set<String>) {
        let resolved = resolved ?? resolvedSites(state).map(\.site)
        let sitesOfRecord = Dictionary(grouping: resolved, by: ProjectFolder.workspaceKey(of:))
        var claimed = Set(resolved.flatMap(\.hosts))
        var sites: [Site] = []
        var conflicts: [Workspace: String] = [:]
        var noticeHosts: Set<String> = []

        for (key, sitesOfProject) in sitesOfRecord.sorted(by: { $0.key < $1.key }) {
            let workspaces = state.worktrees[key]?.workspaces ?? []
            let isWordPress = !workspaces.isEmpty && Self.isWordPress(sitesOfProject)

            for workspace in workspaces {
                guard let site = workspace.site(of: sitesOfProject, tld: state.tld) else {
                    continue
                }

                if site.kind == .proxy {
                    conflicts[workspace] = "The workspace \(workspace.name) does not run, because \(sitesOfProject[0].host) is a proxy site. Each workspace would go to the same server. Remove the workspace."
                    continue
                }

                if let taken = site.hosts.first(where: claimed.contains) {
                    conflicts[workspace] = "The workspace \(workspace.name) does not run, because another site has the host \(taken) already."
                    continue
                }

                claimed.formUnion(site.hosts)
                sites.append(site)

                if isWordPress, workspace.state != .ready || workspace.configurationDigest == nil {
                    noticeHosts.formUnion(site.hosts)
                }
            }
        }

        return (sites, conflicts, sitesOfRecord, noticeHosts)
    }

    // A workspace of a WordPress site runs PHP only when it is Ready (Phase 4, 3a and 3e). Before
    // that, its plugins and WP-Cron could write into the database of the main site. So nginx gives a
    // page with this text. The Site screen says why.
    static let wordPressWorkspaceTitle = "This workspace runs no PHP yet"
    static let wordPressWorkspaceReason = "Nexus did not isolate this workspace yet. Its plugins and WP-Cron could write into the database of the main site. The section Workspaces of the site in Nexus says why."

    // The sites of one workspace record. layouts can hold the types that a list read already.
    static func isWordPress(_ sitesOfProject: [Site], layouts: [String: SiteLayout] = [:]) -> Bool {
        sitesOfProject.contains { (layouts[$0.host]?.projectType ?? PHPProject.type(of: $0)).isWordPress }
    }

    func workspaceInfo(key: String, sitesOfRecord: [String: [Site]], conflicts: [Workspace: String], noticeHosts: Set<String>, layouts: [String: SiteLayout], installed: [InstalledRuntime], state: EngineState, appPorts: [String: Int]) -> [WorkspaceInfo] {
        let sites = sitesOfRecord[key] ?? []
        let workspaces = state.worktrees[key]?.workspaces ?? []

        return workspaces.map { workspace in
            let site = workspace.site(of: sites, tld: state.tld)
            let layout = site.map { SiteLayout(of: $0) }
            let owner = Self.processOwner(key: key, workspace: workspace.name)
            let links = workspace.links.flatMap { links in
                links.done ? nil : WorkspaceLinkInfo(from: links.from, to: links.to, progress: linkProgress[owner] ?? 0)
            }
            let problem = conflicts[workspace] ?? site.flatMap { workspaceSite in
                layout.flatMap { layout in
                    Self.problem(of: workspaceSite, installed: installed, layout: layout) ?? applyProblem(of: workspaceSite, appPorts: appPorts, noticeHosts: noticeHosts, layout: layout)
                }
            }
            let app = site.flatMap { $0.kind == .node ? appInfo(owner: Self.processOwner(key: key, workspace: workspace.name), port: workspace.ports[NodeAppLaunch.portName], host: $0.host) : nil }

            return WorkspaceInfo(
                name: workspace.name,
                worktree: workspace.worktree,
                folder: workspace.folder,
                branch: workspace.branch,
                hosts: site?.hosts ?? [],
                url: problem == nil ? site.map { Self.url(for: $0.host, in: state) } : nil,
                problem: problem,
                state: workspace.state,
                warnings: workspace.warnings + (processProblems[owner] ?? []),
                databases: workspace.databases.map { database in
                    WorkspaceDatabaseInfo(name: database.name, instance: database.instance, port: workspace.servers.first { $0.instance == database.instance }?.port)
                },
                redisIndexes: workspace.redisIndexes,
                ports: workspace.ports,
                app: app,
                links: links,
                dump: dumpProgress[owner],
                documentRoot: layout.map { Self.displayPath($0.documentRoot) }
            )
        }
    }

    // A workspace of a WordPress site from before Phase 4, 3e has no digest. It was Not isolated, or
    // an older Nexus set it to Ready. It gets its setup now. A setup of 3e always gives a digest.
    // Returns nil when no record changes.
    static func settingUpOldWordPressWorkspaces(of worktrees: [String: SiteWorktrees], keys: Set<String>) -> [String: SiteWorktrees]? {
        var changed = worktrees

        for key in keys {
            for index in changed[key]?.workspaces.indices ?? 0..<0 {
                let workspace = changed[key]!.workspaces[index]

                if workspace.configurationDigest == nil, workspace.state != .preparing {
                    changed[key]?.workspaces[index].state = .preparing
                }
            }
        }

        return changed == worktrees ? nil : changed
    }

    // Before Phase 4, 3a the key of a Bedrock site on web/ ended in /web. Its workspaces move to the
    // key of the project. The move is a separate change of the state. In updateWorktrees a key
    // that goes away removes its workspaces with their databases. A site on the project folder can
    // have a record on that key already. A workspace with a name that this record has stays on the
    // old key. updateWorktrees then removes it as a workspace without a site.
    static func movingOldKeys(of worktrees: [String: SiteWorktrees], sites: [Site]) -> [String: SiteWorktrees] {
        var moved = worktrees

        for site in sites {
            let folder = RealPath.of(site.folder)
            let key = ProjectFolder.workspaceKey(of: site)

            guard key != folder, (folder as NSString).lastPathComponent == "web", let record = moved[folder] else {
                continue
            }

            var target = moved[key] ?? SiteWorktrees()
            let names = Set(target.workspaces.map(\.name))
            let staying = record.workspaces.filter { names.contains($0.name) }

            guard staying.count < record.workspaces.count || moved[key] == nil else {
                continue
            }

            target.listed.formUnion(record.listed)
            target.workspaces += record.workspaces.filter { !names.contains($0.name) }
            moved[key] = target
            moved[folder] = staying.isEmpty ? nil : SiteWorktrees(listed: record.listed, workspaces: staying)
        }

        return moved
    }

    // A site whose worktrees git cannot list keeps what it has. Only a list from git can remove
    // a workspace (D53). A site that went away takes its record with it. A folder that does not
    // exist now keeps its record, because a disk that is not connected also removes the site. Two
    // sites can share a project and so one record. A worktree of that project gets a workspace
    // when the setting of one of these sites is on. A site without a repository gets an empty
    // record. So a worktree after a later git init counts as new. Returns nil when nexusd cannot
    // store the change.
    private func reconcileWorktrees() async -> WorktreeChange? {
        let sites = resolvedSites(await stateStore.current()).map(\.site)
        let sitesOfRecord = Dictionary(grouping: sites, by: ProjectFolder.workspaceKey(of:))
        let projects = Set(sites.map(ProjectFolder.projectFolder(of:)))
        let repositories = sitesOfRecord.compactMapValues { $0.lazy.compactMap(ProjectFolder.repository(of:)).first }
        let lists = await Self.worktreeLists(of: Set(repositories.values.map(\.root)))

        let current = await stateStore.current().worktrees

        if Self.movingOldKeys(of: current, sites: sites) != current {
            try? await stateStore.update { $0.worktrees = Self.movingOldKeys(of: $0.worktrees, sites: sites) }
        }

        let wordPressKeys = Set(sitesOfRecord.filter { Self.isWordPress($0.value) }.keys)
        let inCreation = worktreesInCreation

        if Self.settingUpOldWordPressWorkspaces(of: await stateStore.current().worktrees, keys: wordPressKeys) != nil {
            try? await stateStore.update { state in
                state.worktrees = Self.settingUpOldWordPressWorkspaces(of: state.worktrees, keys: wordPressKeys) ?? state.worktrees
            }

            applySitesSoon()
        }

        return try? await stateStore.updateWorktrees { known in
            var worktrees = known.filter { key, _ in
                sitesOfRecord[key] != nil || !FileManager.default.fileExists(atPath: key)
            }

            for (key, sites) in sitesOfRecord {
                guard let repository = repositories[key] else {
                    worktrees[key] = worktrees[key] ?? SiteWorktrees()
                    continue
                }

                guard let listed = lists[repository.root] else {
                    continue
                }

                worktrees[key] = WorkspacePlanner.update(
                    known[key],
                    listed: listed,
                    automatic: sites.contains(where: \.createsWorkspaces),
                    subfolder: repository.subfolder,
                    excluded: projects.subtracting(sites.map(ProjectFolder.projectFolder(of:))).union(inCreation),
                    folderExists: { FileManager.default.fileExists(atPath: $0) }
                )
            }

            return worktrees
        }
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
