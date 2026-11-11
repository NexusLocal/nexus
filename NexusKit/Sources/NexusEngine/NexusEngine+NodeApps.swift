import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// The Node.js apps of the sites (D67). nexusd runs the app of each main checkout and of each
// workspace that is ready, each on its own port. The supervisor of the background processes
// starts an app again after a crash. The log is logs/app-<host>.log. A child gets the environment
// of ChildEnvironment and not the environment of nexusd. So it gets no CLAUDECODE, which makes
// Astro start a detached server.
extension NexusEngine {
    static let corepackRetryWait: Duration = .seconds(60)
    static let firstAppPort = NexusVariant.current.firstAppPort

    // A background command has no tab at its start, so this id is never the id of such a command.
    static func appProcessID(owner: String) -> String {
        "\(owner)\n\t\(NodeAppLaunch.portName)"
    }

    // Returns nil when the app cannot start now. The reason then goes to the problems of its owner.
    // The caller checks that list has the port of the app. hosts are the names that nginx sends to
    // the app.
    func appProcess(of site: Site, in list: BackgroundList, hosts: [String], tld: String) async -> BackgroundProcess? {
        guard let port = list.ports[NodeAppLaunch.portName] else {
            return nil
        }

        let folder = URL(filePath: list.folder, directoryHint: .isDirectory)
        let project = NodeProject.read(in: folder)
        let custom = site.command.map { WorkspaceKeys.expanded($0, workspace: list.name, host: list.host, database: list.database.map(ShellWord.quoted), ports: list.ports) }

        guard let launch = NodeAppLaunch.make(command: custom, project: project, port: port, hosts: hosts, tld: tld) else {
            plannedProcessProblems[list.owner, default: []].append("The Node.js app does not run, because package.json has no dev or start script. Set a command, for example: nexus site edit \(site.host) --command \"npm run dev\"")
            return nil
        }

        let node: ToolCommand

        do {
            node = try await toolCommand(.node, folder: list.folder)
        } catch {
            plannedProcessProblems[list.owner, default: []].append("The Node.js app does not run. \(ErrorText.plain(error))")
            return nil
        }

        guard let extraPath = await packageManagerPath(for: custom == nil ? project?.packageManager : nil, owner: list.owner) else {
            return nil
        }

        if !launch.warnings.isEmpty {
            plannedProcessProblems[list.owner, default: []].append(contentsOf: launch.warnings)
        }

        let added = [Self.processMarker: processMarkerValue, Self.nodeLineKey: list.node ?? "", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0"]
        let programEnvironment = environment(of: ToolCommand(executable: node.executable, path: node.path + extraPath))
            .merging(launch.environment) { _, app in app }
            .merging(added) { _, new in new }
        let log = "app-\(list.host)"

        return BackgroundProcess(owner: list.owner, command: launch.command, log: log, worktree: list.worktree, definition: ServiceDefinition(
            id: Self.appProcessID(owner: list.owner),
            displayName: launch.command,
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", launch.command],
            environment: programEnvironment,
            workingDirectory: folder,
            ports: [port],
            logFile: paths.log(log),
            stopsGroup: true
        ))
    }

    // The folders for pnpm, yarn and bun after the folder of Node. The script of a project with
    // pnpm or yarn waits for corepack, and the script of a project with bun needs bun. A command of
    // the user gets the folders that exist. Returns nil when the app must wait.
    private func packageManagerPath(for manager: PackageManager?, owner: String) async -> [String]? {
        let links = paths.corepackLinks.path(percentEncoded: false)
        let hasCorepack = FileManager.default.fileExists(atPath: "\(links)/pnpm")
        let bun = Self.bunFolder()

        if manager?.usesCorepack == true, !hasCorepack {
            plannedProcessProblems[owner, default: []].append(corepackWait())
            return nil
        }

        if manager == .bun, bun == nil {
            plannedProcessProblems[owner, default: []].append("The Node.js app does not run, because the project uses bun and Nexus found no bun. Install bun from bun.sh.")
            return nil
        }

        return (hasCorepack ? [links] : []) + (bun.map { [$0] } ?? [])
    }

    private static func bunFolder() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        return ["\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"].first { FileManager.default.isExecutableFile(atPath: "\($0)/bun") }
    }

    // Nexus installs corepack one time, in the background. A failure waits a minute before the next
    // try, because each sync would try again. A sync after that minute tries again.
    private func corepackWait() -> String {
        if let corepackFailure, ContinuousClock.now < corepackFailure.nextTry {
            return "The Node.js app does not run, because Nexus could not install corepack for pnpm and yarn. \(corepackFailure.reason)"
        }

        if corepackInstall == nil {
            corepackInstall = Task {
                do {
                    try await installCorepack()
                    corepackFailure = nil
                } catch {
                    corepackFailure = (nextTry: .now + Self.corepackRetryWait, reason: ErrorText.plain(error))
                }

                corepackInstall = nil
                _ = syncBackgroundProcesses()

                if corepackFailure != nil {
                    try? await Task.sleep(for: Self.corepackRetryWait)
                    _ = syncBackgroundProcesses()
                }
            }
        }

        return "Nexus installs corepack for pnpm and yarn. The Node.js app starts after that."
    }

    // npm installs corepack from the registry, and corepack makes the links for pnpm and yarn. Each
    // link starts with #!/usr/bin/env node, so it runs with the Node of the app.
    func installCorepack() async throws {
        guard let node = Self.newest("node", in: await installer.installedRuntimes()) else {
            throw RuntimeError.unsupported("Node is not installed. Run: nexus install node 24")
        }

        let bin = node.folder.appending(path: "bin", directoryHint: .isDirectory)
        let executable = bin.appending(path: "node")
        let npm = node.folder.appending(path: "lib/node_modules/npm/bin/npm-cli.js")
        let environment = ["PATH": "\(bin.path(percentEncoded: false)):\(ChildEnvironment.path)"]
        let package = paths.corepackPackage
        let corepack = package.appending(path: "node_modules/corepack/dist/corepack.js")

        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.corepackLinks, withIntermediateDirectories: true)

        try await CommandRunner.run(Command(
            executable: executable,
            arguments: [npm.path(percentEncoded: false), "install", "--prefix", package.path(percentEncoded: false), "--no-audit", "--no-fund", "corepack@latest"],
            environment: environment,
            name: "npm"
        ))

        try await CommandRunner.run(Command(
            executable: executable,
            arguments: [corepack.path(percentEncoded: false), "enable", "--install-directory", paths.corepackLinks.path(percentEncoded: false), "pnpm", "yarn"],
            environment: environment,
            name: "corepack"
        ))
    }

    // What the Site screen shows about an app. host names the log.
    func appInfo(owner: String, port: Int?, host: String) -> AppProcessInfo {
        let id = Self.appProcessID(owner: owner)

        return AppProcessInfo(port: port, command: runningProcesses[id]?.command, state: appStates[id], log: paths.log("app-\(host)").path(percentEncoded: false))
    }

    // A stop and a sync start the app again. A failed app also starts again, and a failed install of
    // corepack tries again.
    func restartApp(host: String, workspace: String?) async throws -> String {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.host == host }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        guard site.kind == .node else {
            throw RuntimeError.unsupported("\(host) is no Node.js app.")
        }

        let key = ProjectFolder.workspaceKey(of: site)

        if let workspace, state.worktrees[key]?.workspaces.contains(where: { $0.name == workspace }) != true {
            throw RuntimeError.unsupported("\(host) has no workspace \(workspace).")
        }

        let id = Self.appProcessID(owner: Self.processOwner(key: key, workspace: workspace))

        if runningProcesses[id] != nil {
            try? await processSupervisor.stop(id)
            runningProcesses[id] = nil
        }

        corepackFailure = nil
        await syncBackgroundProcesses().value

        return "Nexus starts the Node.js app of \(workspace ?? host) again."
    }
}
