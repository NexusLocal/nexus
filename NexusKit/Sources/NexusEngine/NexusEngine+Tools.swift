import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime

// nexus php, composer, node and npm (D38). Each one uses the versions of the site that holds the
// folder. Outside a site, the defaults for a new site apply. nexusd only says what to run. The
// nexus command runs it in the terminal. The program then gets the terminal and the exit code.
extension NexusEngine {
    func toolCommand(_ tool: ProjectTool, folder path: String) async throws -> ToolCommand {
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        let state = await stateStore.current()
        let location = ProjectFolder.locate(folder, in: resolvedSites(state).map(\.site))
        let installed = await installer.installedRuntimes()

        switch tool {
        case .php, .composer:
            let php = try installedPHP(try phpLine(for: location, state: state, installed: installed), in: installed)

            guard tool == .composer else {
                return try await phpCommand(php)
            }

            guard let composer = Self.newest("composer", in: installed) else {
                throw RuntimeError.unsupported("Composer is not installed. Run: nexus install composer 2")
            }

            return try await phpCommand(php, script: composer.folder.appending(path: "composer.phar"))
        case .node, .npm:
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
    }

    func phpLine(for location: ProjectLocation?, state: EngineState, installed: [InstalledRuntime]) throws -> String {
        if let location {
            return location.site.php
        }

        return try Self.phpLine(nil, installed: installed, defaults: state.siteDefaults)
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
    func phpCommand(_ php: InstalledRuntime, script: URL? = nil) async throws -> ToolCommand {
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
                "PHP_INI_SCAN_DIR": confD.path(percentEncoded: false),
            ]) { _, new in new },
            path: [bin.path(percentEncoded: false), commandLinks]
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
