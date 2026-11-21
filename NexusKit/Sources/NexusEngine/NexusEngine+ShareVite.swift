import Foundation
import NexusConfig
import NexusCore
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// Vite Live and Build for a public link (group 4, 4e). Live sends the paths of Vite to the dev
// server. Build stops the dev server and serves a build. A Node.js app on Vite always uses its dev
// server.

// The Laravel root of a target with a vite.config file and a node_modules folder. output is the
// folder of the build with a slash at its end, for example public/build/.
struct ShareViteRoot: Sendable, Equatable {
    let root: URL
    let output: String
}

// The build ran longer than shareBuildTimeLimit.
struct ShareBuildTimeLimit: Error {}

extension NexusEngine {
    // The frameworks of a Node.js app on a Vite dev server (overview, question 5).
    static let viteFrameworks: Set<NodeFramework> = [.vite, .sveltekit, .astro, .nuxt]
    static let shareBuildStopCause = "a public link uses Build"

    static func usesLive(_ record: ShareRecord) -> Bool {
        record.usesVite && record.options.viteMode == .live && record.liveBlocked == nil
    }

    // Without node_modules no Vite can run. The wait page of 3d uses the same rule.
    static func viteRoot(of site: Site) -> ShareViteRoot? {
        guard site.kind == .php, let root = LaravelProject.root(containing: site.folder), let output = BackgroundPreset.viteOutput(inRoot: root) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: root.appending(path: "node_modules").path(percentEncoded: false)) else {
            return nil
        }

        return ShareViteRoot(root: root, output: output)
    }

    // The output folder in the root. A folder outside the root is not a folder that Nexus removes.
    static func outputFolder(of vite: ShareViteRoot) -> URL? {
        let parts = vite.output.split(separator: "/").filter { $0 != "." }

        guard !vite.output.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else {
            return nil
        }

        return vite.root.appending(path: parts.joined(separator: "/"), directoryHint: .isDirectory)
    }

    static func hotFilePort(in root: URL) -> Int? {
        (try? String(contentsOf: root.appending(path: BackgroundPreset.hotFile), encoding: .utf8)).flatMap(DevServer.port(inHotFile:))
    }

    // The log of the dev server of the owner. Without a plan it is the name that the dev servers use.
    static func shareBuildLog(plan: DevServerPlan?, record: ShareRecord) -> String {
        plan?.log ?? (record.workspace == nil ? "main-\(record.site)" : "workspace-\(record.host)")
    }

    // The owners whose open link uses Build (group 4, 4e). Their dev server does not run. The owner
    // comes from the target of the link. The state decides. So an own-domain link keeps its Build
    // after a new start of nexusd.
    static func buildShareOwners(_ shares: [ShareRecord], targets: [String: ShareTarget]) -> Set<String> {
        Set(shares.filter { $0.state.isActive && $0.buildsAssets }.compactMap { targets[$0.host]?.owner })
    }

    // The Node.js apps of the sites by their host, with the real path of their folder. The share
    // block of an app passes /@fs/ only inside this folder.
    static func viteAppFolders(of sites: [Site]) -> [String: URL] {
        Dictionary(sites.filter { $0.kind == .node }.map { ($0.host, URL(filePath: ProjectFolder.projectFolder(of: $0), directoryHint: .isDirectory)) }) { first, _ in first }
    }
}

// MARK: The check

extension NexusEngine {
    // project is shareProject(of: target).
    func viteCheck(of target: ShareTarget, project: ShareProject?) async -> ShareViteCheck {
        guard let site = project?.site else {
            return .none
        }

        if site.kind == .node {
            return Self.appViteCheck(of: site)
        }

        guard let vite = Self.viteRoot(of: site) else {
            return Self.mixCheck(of: site)
        }

        let version = ViteLiveCheck.installedVersion(in: vite.root)
        let install = "\((NodeProject.read(in: vite.root)?.packageManager ?? .npm).rawValue) install"
        var check = ShareViteCheck(usesVite: true)

        if !ViteLiveCheck.allowsLive(installed: version) {
            check.liveBlocked = ViteLiveCheck.liveBlockedText(version: version, install: install)
        }

        check.inTerminal = viteRunsInTerminal(owner: target.owner, root: vite.root)
        check.buildRefusal = await buildRefusal(of: vite, inTerminal: check.inTerminal, liveBlocked: check.liveBlocked != nil)
        check.refusal = check.liveBlocked == nil ? nil : check.buildRefusal
        return check
    }

    // A Node.js app always shares its dev server. An old or unknown version refuses the share.
    private static func appViteCheck(of site: Site) -> ShareViteCheck {
        let folder = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)

        guard let project = NodeProject.read(in: folder), let framework = project.framework, viteFrameworks.contains(framework) else {
            return .none
        }

        let version = ViteLiveCheck.installedVersion(in: folder)

        guard !ViteLiveCheck.allowsLive(installed: version) else {
            return .none
        }

        return ShareViteCheck(refusal: ViteLiveCheck.appRefusal(version: version, install: "\(project.packageManager.rawValue) install"))
    }

    // Laravel Mix writes public/hot for npm run hot. Visitors then get URLs on localhost:8080 (owner,
    // 4e question 5).
    private static func mixCheck(of site: Site) -> ShareViteCheck {
        guard site.kind == .php, let root = LaravelProject.root(containing: site.folder) else {
            return .none
        }

        let files = ["webpack.mix.js", BackgroundPreset.hotFile].map { root.appending(path: $0).path(percentEncoded: false) }

        return files.allSatisfy(FileManager.default.fileExists(atPath:)) ? ShareViteCheck(mixHot: true) : .none
    }

    // A public/hot whose port answers while Nexus runs no dev server for the owner.
    private func viteRunsInTerminal(owner: String, root: URL) -> Bool {
        guard let port = Self.hotFilePort(in: root) else {
            return false
        }

        return hotFilePortAnswers(port) && !runningProcesses.values.contains { $0.owner == owner && $0.isDevServer }
    }

    // A build writes the output folder. A file that git sees would change (D50). A folder without
    // git passes, as in runsVite.
    private func buildRefusal(of vite: ShareViteRoot, inTerminal: Bool, liveBlocked: Bool) async -> String? {
        if inTerminal {
            return liveBlocked ? ShareText.Vite.inTerminalWithoutLive : ShareText.Vite.inTerminal
        }

        guard NodeProject.read(in: vite.root)?.hasBuildScript == true else {
            return ShareText.Vite.noBuildScript
        }

        guard let git = await GitTool.executable(), let ignored = try? await GitTool.ignores(vite.output, in: vite.root.path(percentEncoded: false), git: git), !ignored else {
            return nil
        }

        return ShareText.Vite.notIgnored(vite.output)
    }
}

// MARK: Build

extension NexusEngine {
    // The part of 4e before the ports. The sync stops the dev server, because buildShareOwners holds
    // the owner now. The plugin of Laravel removes public/hot at SIGTERM. The sync removes it after a
    // SIGKILL. Nexus does not remove a public/hot of a port outside Nexus. project is
    // shareProject(of: target).
    func prepareShareBuild(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws {
        guard record.buildsAssets, let site = project?.site, let vite = Self.viteRoot(of: site) else {
            return
        }

        if runningProcesses.values.contains(where: { $0.owner == target.owner && $0.isDevServer }), let log = devServerPlans[target.owner]?.log {
            writeToLog(of: log, "\(ShareText.Vite.stopsForBuild(record.host))\n")
        }

        await syncBackgroundProcesses().value

        if FileManager.default.fileExists(atPath: vite.root.appending(path: BackgroundPreset.hotFile).path(percentEncoded: false)) {
            let port = Self.hotFilePort(in: vite.root)

            if let port, hotFilePortAnswers(port) {
                throw RuntimeError.unsupported(record.liveBlocked == nil ? ShareText.Vite.inTerminal : ShareText.Vite.inTerminalWithoutLive)
            }

            throw RuntimeError.unsupported(ShareText.Vite.hotFileStays)
        }

        // Only a folder that the build of the link makes goes at its end (owner, 4e question 4).
        // Else the first page after an idle stop shows that old build.
        if let folder = Self.outputFolder(of: vite), !FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path(percentEncoded: false)) {
            madeBuildOutput.insert(record.id)
        }
    }

    // The build of a Build link, after nexusd reads the public host. The record then holds that
    // host. A stop during the build ends the start with the reason of the stop.
    func buildLinkAssets(_ id: String, target: ShareTarget, project: ShareProject?) async throws {
        guard let record = await stateStore.current().share(id: id), record.buildsAssets else {
            return
        }

        do {
            try await runOrJoinShareBuild(record, target: target, project: project)
        } catch {
            try await ensureStarting(id)
            throw error
        }
    }

    // Build Again. The link stays open with the old files when the build fails.
    func rebuildShare(host: String) async throws -> String {
        let state = await stateStore.current()

        guard let record = activeShare(naming: host, in: state), let target = shareTargets(state)[record.host] else {
            throw RuntimeError.unsupported(ShareText.noOpenLink(host))
        }

        guard record.state == .open else {
            throw RuntimeError.unsupported(ShareText.Vite.notOpenYet(record.host))
        }

        guard record.buildsAssets else {
            throw RuntimeError.unsupported(ShareText.Vite.noBuild(record.host))
        }

        try await runOrJoinShareBuild(record, target: target, project: shareProject(of: target, in: state))
        return ShareText.Vite.builtAgain(record.host)
    }

    // A second request for the same link waits for the build that runs. A cancel of the request
    // that started the build stops the build. So a failed DNS record of an own-domain link stops
    // its build at once.
    private func runOrJoinShareBuild(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws {
        if let running = shareBuilds[record.id] {
            try await running.value
            return
        }

        let build = Task { try await self.runShareBuild(record, target: target, project: project) }
        shareBuilds[record.id] = build

        defer {
            if shareBuilds[record.id] == build {
                shareBuilds[record.id] = nil
            }
        }

        try await withTaskCancellationHandler {
            try await build.value
        } onCancel: {
            build.cancel()
        }
    }

    // The build gets the environment of the dev server and the values of 4c. A cancelled task stops
    // the build. The time limit stops a build that waits for input or does not end.
    private func runShareBuild(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws {
        guard let site = project?.site, let vite = Self.viteRoot(of: site) else {
            return
        }

        let plan = devServerPlans[target.owner]
        let log = Self.shareBuildLog(plan: plan, record: record)
        let logFile = paths.log(log)
        let command = shareBuildCommand(plan?.command ?? BackgroundPreset.viteCommand)
        let limit = shareBuildTimeLimit

        activity?.write("share", ShareText.buildLine(record.host))
        writeToLog(of: log, "$ \(command)\n")

        let tool = try? await toolCommand(.php, folder: vite.root.path(percentEncoded: false))
        let added = [Self.processMarker: processMarkerValue, Self.nodeLineKey: site.node ?? "", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0"]
        let programEnvironment = environment(of: tool)
            .merging(added) { _, new in new }
            .merging(viteEnvironment(of: record)) { _, new in new }
        let build = Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", command], environment: programEnvironment, workingDirectory: vite.root, name: command)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await CommandRunner.run(build, appendingTo: logFile)
                }

                group.addTask {
                    try await Task.sleep(for: limit)
                    throw ShareBuildTimeLimit()
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch is ShareBuildTimeLimit {
            throw RuntimeError.unsupported(ShareText.Vite.buildTooLong(command, log: logFile.path(percentEncoded: false)))
        } catch is CommandError {
            throw RuntimeError.unsupported(ShareText.Vite.buildFailed(command, log: logFile.path(percentEncoded: false)))
        }
    }
}

// MARK: Live

extension NexusEngine {
    // The target of a share block. A Laravel link in Live gets Vite lines only while public/hot has a
    // text that passes the check. writtenHotTexts then holds that text for watchShareHotFiles.
    func shareViteTarget(for record: ShareRecord, site: WebSite?) -> ShareViteTarget? {
        switch site?.backend {
        case .app(let port, let framework?)? where Self.viteFrameworks.contains(framework):
            return viteAppFolders[record.host].map { ShareViteTarget(kind: .app, port: port, projectFolder: $0) }
        case .php(_, let documentRoot, _, _)?:
            guard Self.usesLive(record), let hotFile = site?.devServer?.hotFile,
                  let contents = try? String(contentsOf: hotFile, encoding: .utf8),
                  let text = ShareViteRoutes.checkedHotText(contents),
                  let port = DevServer.port(inHotFile: text) else {
                writtenHotTexts[record.id] = nil
                return nil
            }

            writtenHotTexts[record.id] = text
            let projectFolder = hotFile.deletingLastPathComponent().deletingLastPathComponent()

            return ShareViteTarget(kind: .laravel(hotText: text, secure: text.hasPrefix("https://"), documentRoot: documentRoot), port: port, projectFolder: projectFolder)
        default:
            return nil
        }
    }

    // One watch on the public folder of each Live link. The plugin of Laravel writes public/hot one
    // time and closes it. A new text or a removed file writes the share block again.
    func watchShareHotFiles(_ records: [ShareRecord], sites: [WebSite]) {
        var wanted: [String: URL] = [:]

        for record in records where Self.usesLive(record) {
            wanted[record.id] = sites.first { $0.hosts.first == record.host }?.devServer?.hotFile
        }

        for (id, watcher) in shareHotWatchers where wanted[id] == nil {
            watcher.stop()
            shareHotWatchers[id] = nil
        }

        guard !watchingStopped else {
            return
        }

        for (id, hotFile) in wanted where shareHotWatchers[id] == nil {
            shareHotWatchers[id] = FolderWatcher(folders: [hotFile.deletingLastPathComponent()], latency: 0.2) { [weak self] _ in
                Task { await self?.shareHotFileChanged(id, hotFile: hotFile) }
            }
        }
    }

    func shareHotFileChanged(_ id: String, hotFile: URL) async {
        guard shareHotWatchers[id] != nil else {
            return
        }

        let text = (try? String(contentsOf: hotFile, encoding: .utf8)).flatMap(ShareViteRoutes.checkedHotText)

        guard text != writtenHotTexts[id] else {
            return
        }

        _ = try? await serialWeb { try await self.applyWeb(.shares) }
    }
}

// MARK: The end

extension NexusEngine {
    // The build stops before its folder goes. The next page after the end starts the dev server
    // again, because the owner is no longer in startedOnDemand. So the end needs no sync of the
    // programs. A new start of nexusd ends its links before the services run. A sync there would
    // start the other background processes too early.
    func endShareVite(_ record: ShareRecord) async {
        let build = shareBuilds.removeValue(forKey: record.id)
        build?.cancel()
        _ = await build?.result

        shareHotWatchers.removeValue(forKey: record.id)?.stop()
        writtenHotTexts[record.id] = nil

        let madeOutput = madeBuildOutput.remove(record.id) != nil

        guard record.buildsAssets else {
            return
        }

        let state = await stateStore.current()
        let targets = shareTargets(state)

        buildShareOwners = Self.buildShareOwners(state.shares, targets: targets)

        guard let target = targets[record.host] else {
            return
        }

        startedOnDemand.remove(target.owner)

        if madeOutput, let site = shareProject(of: target, in: state)?.site, let vite = Self.viteRoot(of: site) {
            await removeBuildOutput(of: vite, log: Self.shareBuildLog(plan: devServerPlans[target.owner], record: record))
        }
    }

    // nexusd stops: no build and no watch stays.
    func stopShareVite() {
        for build in shareBuilds.values {
            build.cancel()
        }

        for watcher in shareHotWatchers.values {
            watcher.stop()
        }

        shareHotWatchers = [:]
    }

    // Only while git still ignores the folder. A folder without git counts as ignored, as in runsVite.
    private func removeBuildOutput(of vite: ShareViteRoot, log: String) async {
        guard let folder = Self.outputFolder(of: vite) else {
            return
        }

        if let git = await GitTool.executable(), let ignored = try? await GitTool.ignores(vite.output, in: vite.root.path(percentEncoded: false), git: git), !ignored {
            return
        }

        guard (try? FileManager.default.removeItem(at: folder)) != nil else {
            return
        }

        writeToLog(of: log, "\(ShareText.Vite.removedOutput(vite.output))\n")
    }
}
