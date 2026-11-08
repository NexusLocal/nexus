import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func wordPressRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func runGit(_ arguments: String..., in folder: URL) async throws {
        _ = try await CommandRunner.run(Command(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Nexus", "-c", "user.email=nexus@example.test", "-C", folder.path(percentEncoded: false)] + arguments
        ))
    }

    private func file(_ text: String, at path: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func wordPressRepository(in root: URL) async throws -> URL {
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try file("<?php define('DB_NAME', 'shop');", at: "wp-config.php", in: shop)
        try file("<?php", at: "wp-load.php", in: shop)
        try file("<?php", at: "index.php", in: shop)
        try await runGit("init", "-q", "-b", "main", in: shop)
        try await runGit("add", "-A", in: shop)
        try await runGit("commit", "-q", "-m", "WordPress", in: shop)
        return shop
    }

    private func settleWorkspaces(_ engine: NexusEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        await engine.reconcileWorkspaces()

        while await engine.workspaceWorkRuns {
            try #require(ContinuousClock.now < deadline, "The workspaces did not settle in 30 seconds.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aWorkspaceOfAWordPressSiteIsNotIsolatedAndRunsNoPHP() async throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await wordPressRepository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("wp-cli", "2")])
        try await settleWorkspaces(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await runGit("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settleWorkspaces(engine)

        let current = await engine.stateStore.current()
        let workspace = try #require(current.worktrees[RealPath.of(shop)]?.workspaces.first)
        let hosts = await engine.workspaceSites(current).noticeHosts
        let inWorktree = await engine.handle(.tool(.wp, folder: worktree.path(percentEncoded: false)))
        let php = await engine.handle(.tool(.php, folder: worktree.path(percentEncoded: false)))
        let composer = await engine.handle(.tool(.composer, folder: worktree.path(percentEncoded: false)))
        let npm = await engine.handle(.tool(.npm, folder: worktree.path(percentEncoded: false)))
        let inMain = await engine.handle(.tool(.wp, folder: shop.path(percentEncoded: false)))

        #expect(workspace.state == NexusEngine.wordPressWorkspaceState)
        #expect(hosts == ["shop-fix.test"])
        #expect(inWorktree == .failure(message: "nexus wp does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))
        #expect(php == .failure(message: "nexus php does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))
        #expect(composer == .failure(message: "nexus composer does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))
        #expect(npm != .failure(message: "nexus npm does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))

        guard case .tool = inMain else {
            Issue.record("nexus wp refused the main checkout: \(inMain)")
            return
        }
    }

    @Test func aWorktreeInsideTheMainCheckoutRunsNoPHPEither() async throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await wordPressRepository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("wp-cli", "2")])
        try await settleWorkspaces(engine)
        let worktree = shop.appending(path: ".claude/worktrees/fix", directoryHint: .isDirectory)

        try await runGit("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settleWorkspaces(engine)

        let inWorktree = await engine.handle(.tool(.wp, folder: worktree.path(percentEncoded: false)))

        #expect(await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.map(\.name) == ["fix"])
        #expect(inWorktree == .failure(message: "nexus wp does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))
    }

    @Test func aWorkspaceThatAnOlderNexusSetToReadyRunsNoPHPEither() async throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await wordPressRepository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settleWorkspaces(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await runGit("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settleWorkspaces(engine)
        try await engine.stateStore.update { state in
            state.worktrees[RealPath.of(shop)]?.workspaces[0].state = .ready
        }

        let current = await engine.stateStore.current()
        let info = await engine.siteInfo().first { $0.hosts == ["shop.test"] }?.workspaces?.first
        let inWorktree = await engine.handle(.tool(.wp, folder: worktree.path(percentEncoded: false)))
        let inMain = await engine.handle(.tool(.wp, folder: shop.path(percentEncoded: false)))

        #expect(current.worktrees[RealPath.of(shop)]?.workspaces.first?.state == .ready)
        #expect(await engine.workspaceSites(current).noticeHosts == ["shop-fix.test"])
        #expect(info?.state == NexusEngine.wordPressWorkspaceState)
        #expect(inWorktree == .failure(message: "nexus wp does not run in the workspace fix. \(NexusEngine.wordPressWorkspaceReason)"))
        #expect(inMain == .toolNotInstalled(message: "WP-CLI is not installed. Run: nexus install wp-cli 2"))
    }

    @Test func nginxIsWrittenAgainWhenASiteBecomesWordPressOrGetsTheNotice() throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        try file("<?php", at: "index.php", in: blog)
        let site = Site(host: "blog.test", folder: blog, php: "8.4")

        let plain = NexusEngine.signature(of: [site], appPorts: [:], noticeHosts: [], layouts: SiteLayout.of([site]))
        try file("<?php", at: "wp-load.php", in: blog)
        let wordPress = NexusEngine.signature(of: [site], appPorts: [:], noticeHosts: [], layouts: SiteLayout.of([site]))
        let notice = NexusEngine.signature(of: [site], appPorts: [:], noticeHosts: ["blog.test"], layouts: [:])

        #expect(plain != wordPress)
        #expect(wordPress != notice)
    }

    @Test func theRecordOfABedrockSiteOnWebMovesToTheKeyOfItsProject() throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bedrock = root.appending(path: "bedrock", directoryHint: .isDirectory)
        let plain = root.appending(path: "plain", directoryHint: .isDirectory)
        try file(#"{"require": {"roots/bedrock-autoloader": "^1.0"}}"#, at: "composer.json", in: bedrock)
        try file("<?php", at: "web/index.php", in: bedrock)
        try file("<?php", at: "web/index.php", in: plain)
        let web = bedrock.appending(path: "web", directoryHint: .isDirectory)
        let plainWeb = plain.appending(path: "web", directoryHint: .isDirectory)
        let fix = Workspace(name: "fix", worktree: "/worktrees/fix", folder: "/worktrees/fix/web")
        let docs = Workspace(name: "docs", worktree: "/worktrees/docs", folder: "/worktrees/docs/web")
        let record = SiteWorktrees(listed: ["/worktrees/fix"], workspaces: [fix])
        let both = SiteWorktrees(listed: ["/worktrees/fix", "/worktrees/docs"], workspaces: [fix, docs])
        let sites = [Site(host: "shop.test", folder: web, php: "8.4"), Site(host: "plain.test", folder: plainWeb, php: "8.4")]

        let moved = NexusEngine.movingOldKeys(of: [RealPath.of(web): record, RealPath.of(plainWeb): record], sites: sites)
        let merged = NexusEngine.movingOldKeys(of: [RealPath.of(web): both, RealPath.of(bedrock): record], sites: sites)
        let again = NexusEngine.movingOldKeys(of: merged, sites: sites)

        #expect(moved == [RealPath.of(bedrock): record, RealPath.of(plainWeb): record])
        #expect(merged[RealPath.of(bedrock)] == SiteWorktrees(listed: ["/worktrees/fix", "/worktrees/docs"], workspaces: [fix, docs]))
        #expect(merged[RealPath.of(web)] == SiteWorktrees(listed: ["/worktrees/fix", "/worktrees/docs"], workspaces: [fix]))
        #expect(again == merged)
    }

    @Test func aNewWordPressSiteGetsApacheAndPHP84WhenTheyAreInstalled() async throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        let app = root.appending(path: "app", directoryHint: .isDirectory)
        try file("<?php", at: "wp-load.php", in: blog)
        try file("", at: "artisan", in: app)
        try file("<?php", at: "bootstrap/app.php", in: app)
        let full = try makeSiteEngine(root: root.appending(path: "full"), runtimes: [("php", "8.4"), ("php", "8.5"), ("httpd", "2.4")])
        let bare = try makeSiteEngine(root: root.appending(path: "bare"), runtimes: [("php", "8.5")])

        let wordPress = await full.wordPressDefaults(for: Site(host: "blog.test", folder: blog, php: ""))
        let laravel = await full.wordPressDefaults(for: Site(host: "app.test", folder: app, php: ""))
        let missing = await bare.wordPressDefaults(for: Site(host: "blog.test", folder: blog, php: ""))

        #expect(wordPress.server == .apache)
        #expect(wordPress.php == "8.4")
        #expect(laravel.server == nil && laravel.php == nil)
        #expect(missing.server == nil && missing.php == nil)
    }

    @Test func theWordPressValuesOfSettingsSitesWin() async throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        try file("<?php", at: "wp-load.php", in: blog)
        var state = EngineState()
        state.siteDefaults = SiteDefaults(wordPress: WordPressDefaults(server: .nginx, php: nil))
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("php", "8.5"), ("httpd", "2.4")])

        let defaults = await engine.wordPressDefaults(for: Site(host: "blog.test", folder: blog, php: ""))
        let missing = await engine.handle(.setSiteDefaults(SiteDefaults(wordPress: WordPressDefaults(server: .apache, php: "8.2"))))

        #expect(defaults.server == .nginx)
        #expect(defaults.php == "8.5")
        #expect(missing == .failure(message: "PHP 8.2 is not installed. Run: nexus install php 8.2"))
    }
}
