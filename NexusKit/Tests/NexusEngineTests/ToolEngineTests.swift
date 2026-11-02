import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import Testing
@testable import NexusEngine

// nexus php, composer, node and npm, and the Node version of a site (step 7). The roots are in
// /tmp, because the path of a PHP socket has a limit of 103 bytes.
extension NexusEngineTests {
    private static let realToolRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    private func toolRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func toolCommand(_ engine: NexusEngine, _ tool: ProjectTool, in folder: URL) async throws -> ToolCommand {
        let response = await engine.handle(.tool(tool, folder: folder.path(percentEncoded: false)))

        guard case .tool(let command) = response else {
            Issue.record("No command: \(response)")
            throw CancellationError()
        }

        return command
    }

    private func project(_ path: String, in root: URL, nvmrc: String? = nil) throws -> URL {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "app"), withIntermediateDirectories: true)

        if let nvmrc {
            try Data("\(nvmrc)\n".utf8).write(to: folder.appending(path: ".nvmrc"))
        }

        return folder
    }

    private func runtimePath(_ engine: NexusEngine, _ name: String, _ line: String, _ file: String) async -> String {
        RealPath.of(await engine.paths.runtime(name, line: line)) + "/" + file
    }

    @Test func phpInAFolderOfASiteUsesThePHPAndTheSettingsOfThatSite() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("php", "8.5")])
        let config = await engine.paths.phpConfigFolder(line: "8.4")
        let links = RealPath.trimmed(await engine.paths.bin.path(percentEncoded: false))

        let command = try await toolCommand(engine, .php, in: shop.appending(path: "app"))

        #expect(command.executable == (await runtimePath(engine, "php", "8.4", "bin/php")))
        #expect(command.arguments.isEmpty)
        #expect(command.environment["PHPRC"] == config.appending(path: "php.ini").path(percentEncoded: false))
        #expect(command.environment["PHP_INI_SCAN_DIR"] == config.appending(path: "conf.d").path(percentEncoded: false))
        #expect(command.path == [await runtimePath(engine, "php", "8.4", "bin"), links])
        #expect(FileManager.default.fileExists(atPath: config.appending(path: "conf.d/00-nexus.ini").path(percentEncoded: false)))
    }

    @Test func outsideASiteTheToolsUseTheDefaultsForANewSite() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try project("other", in: root, nvmrc: "22")
        var state = EngineState()
        state.siteDefaults = SiteDefaults(php: "8.4", node: "24")
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("php", "8.5"), ("node", "22"), ("node", "24")])

        let php = try await toolCommand(engine, .php, in: other)
        let node = try await toolCommand(engine, .node, in: other)

        #expect(php.executable == (await runtimePath(engine, "php", "8.4", "bin/php")))
        #expect(node.executable == (await runtimePath(engine, "node", "24", "bin/node")))
    }

    @Test func outsideASiteWithoutANodeDefaultTheFilesOfTheFolderDecide() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try project("other", in: root, nvmrc: "22")
        let engine = try makeSiteEngine(root: root, runtimes: [("node", "22"), ("node", "24")])

        let node = try await toolCommand(engine, .node, in: other.appending(path: "app"))

        #expect(node.executable == (await runtimePath(engine, "node", "22", "bin/node")))
    }

    @Test func composerRunsItsPharWithThePHPOfTheSite() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("composer", "2")])

        let command = try await toolCommand(engine, .composer, in: shop)

        #expect(command.executable == (await runtimePath(engine, "php", "8.4", "bin/php")))
        #expect(command.arguments == [await runtimePath(engine, "composer", "2", "composer.phar")])
        #expect(command.environment["PHPRC"] != nil)
    }

    @Test func npmUsesTheNodeOfTheProjectUnlessTheSiteHasALine() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root, nvmrc: "24")
        let blog = try project("blog", in: root, nvmrc: "24")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5"), Site(host: "blog.test", folder: blog, php: "8.5", node: "22")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5"), ("node", "22"), ("node", "24")])

        let shopNPM = try await toolCommand(engine, .npm, in: shop.appending(path: "app"))
        let blogNode = try await toolCommand(engine, .node, in: blog)

        #expect(shopNPM.executable == (await runtimePath(engine, "node", "24", "bin/node")))
        #expect(shopNPM.arguments == [await runtimePath(engine, "node", "24", "lib/node_modules/npm/bin/npm-cli.js")])
        #expect(shopNPM.path.first == (await runtimePath(engine, "node", "24", "bin")))
        #expect(blogNode.executable == (await runtimePath(engine, "node", "22", "bin/node")))
    }

    @Test func aToolThatIsNotInstalledGivesTheInstallCommand() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root, nvmrc: "20.10.0")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.3", node: nil)]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])

        let node = await engine.handle(.tool(.npm, folder: shop.path(percentEncoded: false)))
        let php = await engine.handle(.tool(.php, folder: shop.path(percentEncoded: false)))
        let composer = await engine.handle(.tool(.composer, folder: root.path(percentEncoded: false)))

        #expect(node == .failure(message: "Node 22 is not installed (.nvmrc asks for 20.10.0). Run: nexus install node 22"))
        #expect(php == .failure(message: "PHP 8.3 is not installed. Run: nexus install php 8.3"))
        #expect(composer == .failure(message: "Composer is not installed. Run: nexus install composer 2"))
    }

    @Test func theSiteListShowsTheNodeOfTheProjectAndTheChosenLine() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root, nvmrc: "22")
        let blog = try project("blog", in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5"), Site(host: "blog.test", folder: blog, php: "8.5", node: "24")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5"), ("node", "22"), ("node", "24")])

        let missing = await engine.handle(.editSite(host: "shop.test", change: SiteChange(node: "26")))
        let sites = Dictionary(uniqueKeysWithValues: await engine.siteInfo().map { ($0.hosts[0], $0) })
        let chosen = await engine.handle(.editSite(host: "shop.test", change: SiteChange(node: "24")))
        let chosenInfo = await engine.siteInfo().first { $0.hosts[0] == "shop.test" }
        let back = await engine.handle(.editSite(host: "shop.test", change: SiteChange(node: NodeLines.fromProject)))

        #expect(chosen.doneMessage?.contains("nexus node and nexus npm use Node 24 in its folder.") == true)
        #expect(chosenInfo?.node == "24")
        #expect(back.doneMessage?.contains("nexus node and nexus npm use the Node version of the project in its folder.") == true)
        #expect(await engine.stateStore.current().sites.first { $0.host == "shop.test" }?.node == nil)
        #expect(missing == .failure(message: "Node 26 is not installed. Run: nexus install node 26"))
        #expect(sites["shop.test"]?.projectNode == NodeChoice(line: "22", reason: "from .nvmrc"))
        #expect(sites["shop.test"]?.node == "22")
        #expect(sites["blog.test"]?.projectNode == nil)
        #expect(sites["blog.test"]?.nodeSetting == "24")
    }

    @Test func theSiteListReadsAVersionFileAgainOnlyAfterItChanged() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root, nvmrc: "22")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("node", "22"), ("node", "24")])
        let nvmrc = shop.appending(path: ".nvmrc").path(percentEncoded: false)

        let first = await engine.siteInfo().first?.projectNode
        let cache = await engine.nodeHintCache
        let cached = cache[shop.path(percentEncoded: false)]?.hint
        try Data("24\n".utf8).write(to: shop.appending(path: ".nvmrc"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: nvmrc)
        let changed = await engine.siteInfo().first?.projectNode

        #expect(first == NodeChoice(line: "22", reason: "from .nvmrc"))
        #expect(cached == NodeVersionHint(file: ".nvmrc", text: "22"))
        #expect(changed == NodeChoice(line: "24", reason: "from .nvmrc"))
    }

    @Test func aNodeDefaultMustBeInstalled() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5"), ("node", "22")])

        let missing = await engine.handle(.setSiteDefaults(SiteDefaults(node: "24")))
        let set = await engine.handle(.setSiteDefaults(SiteDefaults(node: "22")))

        #expect(missing == .failure(message: "Node 24 is not installed. Run: nexus install node 24"))
        #expect(set == .done(message: "A new site gets nginx and the newest installed PHP version. It gets Node 22. The sites that exist do not change."))
        #expect(await engine.defaultNodeLine() == "22")
    }
}

// Real nginx and PHP with a Node line that only has its metadata. The real PHP reads the settings
// of Nexus, also when the shell has the PHPRC and PHP_INI_SCAN_DIR of another tool.
extension NexusEngineTests {
    @Test(.enabled(if: realToolRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealSiteGetsANewNodeLineAndItsPHPReadsTheSettingsOfNexus() async throws {
        let root = toolRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try project("shop", in: root)
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = freePort()
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("node", "24")])
        let paths = await engine.paths

        for runtime in ["nginx/1.30", "php/8.5"] {
            let parts = runtime.split(separator: "/").map(String.init)
            let link = paths.runtime(parts[0], line: parts[1])
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realToolRuntimes!).appending(path: runtime))
        }

        var edited, back: NexusResponse?
        var chosen, fromProject: String?
        var output = ""

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: nil, aliases: [], php: "8.5", server: nil))
            edited = await engine.handle(.editSite(host: "shop.test", change: SiteChange(node: "24")))
            chosen = await engine.siteInfo().first?.node
            back = await engine.handle(.editSite(host: "shop.test", change: SiteChange(node: NodeLines.fromProject)))
            fromProject = await engine.siteInfo().first?.nodeSetting

            let command = try await toolCommand(engine, .php, in: shop)
            let shell = ["PHPRC": "/Library/Other/php.ini", "PHP_INI_SCAN_DIR": "/Library/Other/conf.d"]
            let result = try await CommandRunner.run(Command(
                executable: URL(filePath: command.executable),
                arguments: command.arguments + ["-r", "echo PHP_MAJOR_VERSION, '.', PHP_MINOR_VERSION, ' ', ini_get('memory_limit'), ' ', extension_loaded('redis') ? 'redis' : '-';"],
                environment: shell.merging(command.environment) { _, new in new }
            ))
            output = result.standardOutput
        }

        guard case .done(let message) = edited else {
            Issue.record("The Node line did not change: \(String(describing: edited))")
            return
        }
        #expect(message.contains("nexus node and nexus npm use Node 24 in its folder."))
        #expect(chosen == "24")
        #expect(back?.doneMessage != nil)
        #expect(fromProject == nil)
        #expect(output == "8.5 1024M redis")
    }
}

private extension NexusResponse {
    var doneMessage: String? {
        guard case .done(let message) = self else {
            return nil
        }

        return message
    }
}
