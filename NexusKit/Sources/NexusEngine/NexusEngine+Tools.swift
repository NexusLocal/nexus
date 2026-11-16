import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime

// The folder of a tool command, with the state, the sites and the workspace that holds the folder.
// A .tool request uses one place for its command and for its activity (owner, 2026-11-15). Each
// tool command through a link of Nexus is a request, and resolvedSites reads each parked folder.
struct ToolPlace {
    let state: EngineState
    let sites: [Site]
    let folder: URL
    let location: ProjectLocation?
    let workspace: (key: String, workspace: Workspace)?

    var wordPressWorkspace: Workspace? {
        guard let workspace, NexusEngine.isWordPress(sites.filter { ProjectFolder.workspaceKey(of: $0) == workspace.key }) else {
            return nil
        }

        return workspace.workspace
    }
}

// nexus php, composer, node, npm and wp (D38). Each one uses the versions of the site that holds
// the folder. Outside a site, the defaults for a new site apply. nexusd only says what to run. The
// nexus command runs it in the terminal. The program then gets the terminal and the exit code.
// Without a package of the tool, a link in bin/ runs the next program on the PATH. The refusal in
// a workspace of WordPress that is not Ready comes first. So that program does not run there
// either. php and Composer are refused there too, because php wp-cron.php or a Composer script can
// load WordPress. The setup of that workspace runs these tools after it wrote the values of the
// workspace (Phase 4, 3e).
extension NexusEngine {
    func toolPlace(_ path: String, argumentFolder: String? = nil) async -> ToolPlace {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)
        let (folder, location) = Self.toolFolder(path, argumentFolder: argumentFolder, sites: sites)

        return ToolPlace(state: state, sites: sites, folder: folder, location: location, workspace: Self.workspace(holding: folder, location: location, state: state))
    }

    // The checks of the command come before the start of a stopped workspace. So a refused command
    // starts nothing. Without the package of the tool, the link runs the next program on the PATH.
    // That program also needs the servers of the workspace.
    func toolRequest(_ tool: ProjectTool, folder: String, argumentFolder: String?, debug: Bool, activity: Bool) async throws -> ToolCommand {
        let place = await toolPlace(folder, argumentFolder: argumentFolder)
        var command: ToolCommand

        do {
            command = try await toolCommand(tool, in: place, debug: debug)
        } catch let missing as ToolNotInstalled {
            if activity {
                _ = await toolActivity(in: place)
            }

            throw missing
        }

        if activity {
            command.startProblem = await toolActivity(in: place)
        }

        return command
    }

    func toolCommand(_ tool: ProjectTool, folder path: String, argumentFolder: String? = nil, inSetup: Bool = false, debug: Bool = false) async throws -> ToolCommand {
        try await toolCommand(tool, in: await toolPlace(path, argumentFolder: argumentFolder), inSetup: inSetup, debug: debug)
    }

    func toolCommand(_ tool: ProjectTool, in place: ToolPlace, inSetup: Bool = false, debug: Bool = false) async throws -> ToolCommand {
        if debug, !tool.runsPHP {
            throw RuntimeError.unsupported(DebugCommand.onlyPHP(tool))
        }

        let installed = await installer.installedRuntimes()

        if !inSetup, tool.runsPHP, let workspace = place.wordPressWorkspace, workspace.worktree != runningSetupWorktree {
            // A Ready record without a digest comes from before 3e. It waits for its setup.
            switch workspace.state {
            case .ready where workspace.configurationDigest != nil:
                break
            case .notIsolated(let reason):
                throw RuntimeError.unsupported("nexus \(tool.rawValue) does not run in the workspace \(workspace.name), because it is not isolated. \(reason)")
            default:
                throw RuntimeError.unsupported("nexus \(tool.rawValue) does not run in the workspace \(workspace.name) yet, because Nexus still sets it up. Try again when it is ready.")
            }
        }

        do {
            return try await toolCommand(tool, folder: place.folder, location: place.location, state: place.state, installed: installed, inSetup: inSetup, debug: debug)
        } catch where !installed.contains(where: { $0.name == tool.package }) {
            throw ToolNotInstalled(description: ErrorText.plain(error))
        }
    }

    // A command of a setup is a PHP run of Nexus. So it gets no folder of the dump viewer.
    private func toolCommand(_ tool: ProjectTool, folder: URL, location: ProjectLocation?, state: EngineState, installed: [InstalledRuntime], inSetup: Bool, debug: Bool) async throws -> ToolCommand {
        if tool.runsPHP {
            let php = try installedPHP(try phpLine(for: location, state: state, installed: installed), in: installed)
            var command: ToolCommand

            switch tool {
            case .composer:
                command = try await phpCommand(php, script: try phar("composer", title: "Composer", in: installed))
            case .wp:
                command = try await wpCLICommand(php, installed: installed)
                command.wordPressCore = location.flatMap { WordPressCore.coreFolder(for: folder, in: $0.root) }
            default:
                command = try await phpCommand(php)
                command.dumpsFolder = inSetup ? nil : commandDumpsFolder(line: php.line)
            }

            if debug {
                command.xdebugFolder = try await xdebugFolder(of: php)
            }

            return command
        }

        let choice = nodeChoice(for: folder, in: location, state: state, installed: installed.filter { $0.name == "node" }.map(\.line))

        guard let node = installed.first(where: { $0.name == "node" && $0.line == choice.line }) else {
            throw RuntimeError.unsupported("Node \(choice.line) is not installed (\(choice.reason)). Run: nexus install node \(choice.line)")
        }

        let bin = node.folder.appending(path: "bin")
        let npm = node.folder.appending(path: "lib/node_modules/npm/bin/npm-cli.js")

        return ToolCommand(
            executable: bin.appending(path: "node").path(percentEncoded: false),
            arguments: tool == .npm ? [npm.path(percentEncoded: false)] : [],
            path: [bin.path(percentEncoded: false), commandLinks]
        )
    }

    struct ToolNotInstalled: Error, CustomStringConvertible {
        let description: String
    }

    // An MCP server of an editor can start php /Sites/shop/artisan from another folder. The folder
    // that the arguments name then decides when it is in a site. A script outside a site, for
    // example a phar in ~/bin, keeps the site of the current folder.
    static func toolFolder(_ path: String, argumentFolder: String?, sites: [Site]) -> (folder: URL, location: ProjectLocation?) {
        if let argumentFolder {
            let folder = URL(filePath: argumentFolder, directoryHint: .isDirectory)

            if let location = ProjectFolder.locate(folder, in: sites) {
                return (folder, location)
            }
        }

        let folder = URL(filePath: path, directoryHint: .isDirectory)
        return (folder, ProjectFolder.locate(folder, in: sites))
    }

    // A Node.js app or a proxy site uses no PHP. So its folder gets the PHP of a new site.
    func phpLine(for location: ProjectLocation?, state: EngineState, installed: [InstalledRuntime]) throws -> String {
        if let php = location?.site.usedPHP {
            return php
        }

        return try Self.phpLine(nil, installed: installed, defaults: state.siteDefaults)
    }

    // WP-CLI with a PHP version of its own, for a worktree that is no site of Nexus.
    func wpCLITool(php line: String) async throws -> ToolCommand {
        let installed = await installer.installedRuntimes()
        return try await wpCLICommand(try installedPHP(line, in: installed), installed: installed)
    }

    // Nexus serves each site over HTTPS. A wp-config.php can stop each request without HTTPS, and
    // WP-CLI then ends without output. The command line PHP puts the environment in $_SERVER. So
    // wp-config.php sees HTTPS as on a request of the browser.
    private func wpCLICommand(_ php: InstalledRuntime, installed: [InstalledRuntime]) async throws -> ToolCommand {
        var command = try await phpCommand(php, script: try Self.pathWithoutSpaces(for: try phar("wp-cli", title: "WP-CLI", in: installed), in: paths.pharLinks), settingsFolder: try wpCLISettings())
        command.environment["HTTPS"] = "on"
        return command
    }

    private func phar(_ name: String, title: String, in installed: [InstalledRuntime]) throws -> URL {
        guard let runtime = Self.newest(name, in: installed) else {
            throw RuntimeError.unsupported("\(title) is not installed. Run: nexus install \(name) 2")
        }

        return runtime.pharFile
    }

    // The workspace whose worktree holds the folder, with the key of its record. A worktree can be
    // inside the main checkout, for example in .claude/worktrees. ProjectFolder.locate then gives the
    // main site. So the folder decides, and not the root of the location.
    static func workspace(holding folder: URL, location: ProjectLocation?, state: EngineState) -> (key: String, workspace: Workspace)? {
        guard let location else {
            return nil
        }

        let key = ProjectFolder.workspaceKey(of: location.site)
        let path = RealPath.of(folder)
        let workspace = state.worktrees[key]?.workspaces.first { workspace in
            RealPath.contains(RealPath.of(URL(filePath: workspace.worktree, directoryHint: .isDirectory)), path)
        }

        return workspace.map { (key, $0) }
    }

    // WP-CLI 2.12 starts itself again for some commands, for example wp rewrite structure. It puts
    // its own path into a shell command without quotes (launch_self and runcommand). The path of
    // Nexus has a space. So that command failed. A link in the temporary folder of the user has no
    // space.
    static func pathWithoutSpaces(for phar: URL, in folder: URL) throws -> URL {
        let target = phar.path(percentEncoded: false)
        let link = folder.appending(path: "nexus-\(phar.deletingLastPathComponent().lastPathComponent)-\(phar.lastPathComponent)")
        let linkPath = link.path(percentEncoded: false)

        guard !linkPath.contains(where: \.isWhitespace) else {
            return phar
        }

        if (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != target {
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        }

        return link
    }

    private func wpCLISettings() throws -> URL {
        let folder = paths.wpCLIConfigFolder
        let file = folder.appending(path: WordPressCore.phpSettingsFileName)

        if (try? String(contentsOf: file, encoding: .utf8)) != WordPressCore.phpSettings {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(WordPressCore.phpSettings.utf8).write(to: file, options: .atomic)
        }

        return folder
    }

    func installedPHP(_ line: String, in installed: [InstalledRuntime]) throws -> InstalledRuntime {
        guard let php = installed.first(where: { $0.name == "php" && $0.line == line }) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed. Run: nexus install php \(line)")
        }

        return php
    }

    // The links of CommandLinks come after the folder of the runtime. So a Composer script that
    // runs node or npm gets them too, also without the PATH setting.
    var commandLinks: String {
        RealPath.trimmed(paths.bin.path(percentEncoded: false))
    }

    // The command line PHP reads the settings of its version, as PHP-FPM does. PHPRC and
    // PHP_INI_SCAN_DIR are in the environment and not in -c. So a PHP that the tool starts gets
    // them too. An example is a worker of a parallel test run. They also replace the PHPRC of
    // another tool in the shell of the user.
    func phpCommand(_ php: InstalledRuntime, script: URL? = nil, settingsFolder: URL? = nil) async throws -> ToolCommand {
        let folder = paths.phpConfigFolder(line: php.line)
        let confD = folder.appending(path: "conf.d")

        if !FileManager.default.fileExists(atPath: confD.appending(path: PHPConfig.nexusIniName).path(percentEncoded: false)) {
            _ = try await serialWeb { try await self.writePHPConfig(line: php.line, state: await self.stateStore.current()) }
        }

        let bin = php.folder.appending(path: "bin")

        return ToolCommand(
            executable: bin.appending(path: "php").path(percentEncoded: false),
            arguments: script.map { [$0.path(percentEncoded: false)] } ?? [],
            environment: ServiceCatalog.phpEnvironment.merging([
                "PHPRC": folder.appending(path: "php.ini").path(percentEncoded: false),
                "PHP_INI_SCAN_DIR": ([confD] + (settingsFolder.map { [$0] } ?? [])).map { $0.path(percentEncoded: false) }.joined(separator: ":"),
            ]) { _, new in new },
            path: [bin.path(percentEncoded: false), commandLinks],
            coverageFolder: folder.appending(path: PHPConfig.coverageFolderName).path(percentEncoded: false)
        )
    }

    // A line that the user chose wins. Else the files of the project decide, from the folder up
    // to the folder of the site (D21). Outside a site, the default for a new site applies. A
    // default that is not installed anymore gives the line of the files, as for a new site.
    private func nodeChoice(for folder: URL, in location: ProjectLocation?, state: EngineState, installed: [String]) -> NodeChoice {
        if let location {
            if let line = location.site.node {
                return NodeChoice(line: line, reason: "chosen for \(location.site.host)")
            }

            return NodeLines.choose(hint: NodeVersionFiles.hint(from: folder, upTo: location.root), installed: installed)
        }

        if let line = state.siteDefaults.node, installed.contains(line) {
            return NodeChoice(line: line, reason: "the default for new sites")
        }

        return NodeLines.choose(hint: NodeVersionFiles.hint(from: folder, upTo: URL(filePath: "/")), installed: installed)
    }

    // The word project gives nil: the line of the project applies then. A chosen line must be
    // installed, as for PHP.
    func nodeLine(_ requested: String) async throws -> String? {
        guard requested != NodeLines.fromProject else {
            return nil
        }

        guard await runtime(named: "node", line: requested) != nil else {
            throw RuntimeError.unsupported("Node \(requested) is not installed. Run: nexus install node \(requested)")
        }

        return requested
    }

    // A default that is not installed anymore gives the line of the project, as a PHP default
    // gives the newest PHP.
    func defaultNodeLine() async -> String? {
        guard let line = await stateStore.current().siteDefaults.node, await runtime(named: "node", line: line) != nil else {
            return nil
        }

        return line
    }
}
