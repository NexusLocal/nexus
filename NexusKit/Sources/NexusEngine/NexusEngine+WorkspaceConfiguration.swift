import Foundation
import NexusCore
import NexusRuntime

// A pull, a checkout or an edit in a worktree gives the application another configuration after its
// setup. The digest of the last setup shows that change, and a new setup then checks the worktree
// (D48). A workspace that is not isolated gets the same new setup, also after a change in the main
// checkout. So a fix in the configuration needs no Retry. A Ready workspace does not react to the main
// checkout, because its application reads the files of its worktree. A record without a digest comes
// from before this check. It gets no new setup, because its background processes must not start
// without a request.
extension NexusEngine {
    // A pull writes more than one file. A setup that starts after the first file checks half a pull.
    private static let configurationWatchLatency: TimeInterval = 1

    // What the probe reads in a worktree, and the files that decide if Nexus can write the .env.
    static func configurationDigest(of folder: String, in root: String) -> String {
        let configFiles = (FileManager.default.subpaths(atPath: "\(folder)/config") ?? []).filter { $0.hasSuffix(".php") }.sorted()
        let files = [".env", "artisan", "bootstrap/app.php", "bootstrap/cache/config.php"] + configFiles.map { "config/\($0)" }
        let digests = files.map { file in "\(file) \(digest(of: file, in: folder) ?? "")" }
        let ignoreFiles = foldersWithIgnoreFiles(of: folder, in: root).map { "\($0)/.gitignore \(digest(of: ".gitignore", in: $0) ?? "")" }

        return FileChecksum.sha256(of: Data((digests + ignoreFiles).joined(separator: "\n").utf8))
    }

    // The application can be in a subfolder of its root. git reads the .gitignore of each folder
    // from that root to the application.
    private static func foldersWithIgnoreFiles(of folder: String, in root: String) -> [String] {
        var path = root

        return [root] + folder.dropFirst(root.count).split(separator: "/").map { part in
            path += "/\(part)"
            return path
        }
    }

    // The watch comes first, so a change after the check still reports.
    func checkConfigurations() async {
        await watchConfigurations()
        await startSetupsForChangedConfigurations()
    }

    // A nil list checks each workspace. A worktree that is not there or that lost its .git file says
    // nothing about its files. The same applies to a main checkout that is not there. A setup in a
    // worktree that git removes now would write the files back, and git then stops with "Directory
    // not empty". A setup needs its services, and after "Stop all services" only the user starts
    // them. The start of the services ends with this check, so the change does not get lost. A setup
    // of another workspace can take minutes, and the programs of a changed workspace must not wait
    // for it. So the sync comes here.
    private func startSetupsForChangedConfigurations(in paths: [String]? = nil) async {
        guard !watchingStopped else {
            return
        }

        let state = await stateStore.current()
        lazy var sites = resolvedSites(state).map(\.site)
        var changed: [(key: String, workspace: Workspace)] = []

        for (key, list) in state.worktrees {
            for workspace in list.workspaces where workspace.state != .preparing {
                let isNotIsolated = workspace.state.isNotIsolated

                guard isNotIsolated || paths?.contains(where: { RealPath.contains(workspace.worktree, $0) }) != false,
                      let folders = fileFolders(of: workspace, key: key, sites: sites),
                      FileManager.default.fileExists(atPath: folders.worktree),
                      FileManager.default.fileExists(atPath: "\(workspace.worktree)/.git") else {
                    continue
                }

                let hasChanged = Self.configurationChanged(of: folders.worktree, in: workspace.worktree, known: workspace.configurationDigest, paths: paths)
                    || (isNotIsolated
                        && FileManager.default.fileExists(atPath: folders.application)
                        && Self.configurationChanged(of: folders.application, in: folders.applicationRoot, known: workspace.mainConfigurationDigest, paths: paths))

                if hasChanged, await !worktreeRemovalCheck(workspace.worktree) {
                    changed.append((key, workspace))
                }
            }
        }

        guard !changed.isEmpty, !stoppingAllServices, await !waitsForStoppedServices() else {
            return
        }

        // The checks above wait, and another field of a record can change in that time. Only a setup
        // that ended in that time gives another digest.
        try? await stateStore.update { [changed] state in
            for (key, workspace) in changed {
                let record = state.worktrees[key]?.workspaces.firstIndex { record in
                    record.name == workspace.name
                        && record.worktree == workspace.worktree
                        && record.configurationDigest == workspace.configurationDigest
                        && record.mainConfigurationDigest == workspace.mainConfigurationDigest
                }

                if let record {
                    state.worktrees[key]?.workspaces[record].state = .preparing
                }
            }
        }

        publishSites()
        startWorkspaceSetups()
        _ = syncBackgroundProcesses()
    }

    private static func configurationChanged(of folder: String, in root: String, known: String?, paths: [String]?) -> Bool {
        guard let known else {
            return false
        }

        if let paths, !paths.contains(where: { holdsConfiguration($0, of: folder, in: root) }) {
            return false
        }

        return configurationDigest(of: folder, in: root) != known
    }

    // FSEvents names the folder of a change. The logs of a worker also report here each second.
    private static func holdsConfiguration(_ path: String, of folder: String, in root: String) -> Bool {
        foldersWithIgnoreFiles(of: folder, in: root).contains(path)
            || ["\(folder)/bootstrap", "\(folder)/bootstrap/cache"].contains(path)
            || RealPath.contains("\(folder)/config", path)
    }

    // One watch for all worktrees, also for a worktree without a program. The main checkout has logs
    // and builds of its own. So only a workspace that waits for a fix adds that folder. Two calls can
    // run at the same time. So no wait comes after the state. The last call then has the newest state.
    private func watchConfigurations() async {
        let state = await stateStore.current()
        lazy var sites = resolvedSites(state).map(\.site)
        var watched: Set<String> = []

        for (key, list) in state.worktrees {
            for workspace in list.workspaces where workspace.configurationDigest != nil {
                watched.insert(workspace.worktree)

                if workspace.state.isNotIsolated, let folders = fileFolders(of: workspace, key: key, sites: sites) {
                    watched.insert(folders.applicationRoot)
                }
            }
        }

        guard !watchingStopped, watched != watchedConfigurations else {
            return
        }

        watchedConfigurations = watched

        let folders = watched.map { URL(filePath: $0, directoryHint: .isDirectory) }

        configurationWatcher = FolderWatcher(folders: folders, latency: Self.configurationWatchLatency) { [weak self] changed in
            let paths = changed.map(RealPath.trimmed)

            Task { await self?.startSetupsForChangedConfigurations(in: paths) }
        }
    }
}
