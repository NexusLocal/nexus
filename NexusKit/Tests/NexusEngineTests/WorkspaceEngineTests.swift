import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func workspaceRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func git(_ arguments: String..., in folder: URL) async throws {
        _ = try await CommandRunner.run(Command(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Nexus", "-c", "user.email=nexus@example.test", "-C", folder.path(percentEncoded: false)] + arguments
        ))
    }

    private func repository(in root: URL) async throws -> URL {
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        return shop
    }

    private func settle(_ engine: NexusEngine) async throws {
        await engine.reconcileWorkspaces()

        while await engine.workspaceWorkRuns {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func workspaces(_ engine: NexusEngine) async -> [WorkspaceInfo] {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return []
        }

        return sites.flatMap { $0.workspaces ?? [] }
    }

    private func worktreeEngine(root: URL, shop: URL, automatic: Bool? = nil, runtimes: [(name: String, line: String)] = []) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", automaticWorkspaces: automatic)]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: runtimes)
        try await settle(engine)
        return engine
    }

    @Test func gitWorktreeAddGivesAWorkspaceAndGitWorktreeRemoveEndsIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "TICKET-123", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "ticket", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let path = RealPath.of(worktree)
        #expect(await workspaces(engine) == [WorkspaceInfo(name: "ticket-123", worktree: path, folder: path, branch: "ticket", hosts: ["shop-ticket-123.test"], problem: "Every site needs nginx, and nginx is not installed. Run: nexus install nginx 1.30", state: .ready)])

        try await git("worktree", "remove", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    private func writeFile(_ text: String, to path: String, in folder: URL) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func committedLaravelApplication(in root: URL, ignoring ignored: String) async throws -> URL {
        let shop = try await repository(in: root)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("{}", to: "composer.json", in: shop)
        try writeFile(ignored, to: ".gitignore", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile(#"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE', 'forge')],
            ],
            'redis' => [
                'default' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_DB', 0)],
            ],
        ];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "application", in: shop)
        try writeFile(Self.bootstrappers, to: "vendor/autoload.php", in: shop)
        return shop
    }

    @Test func aSiteThatIsNoLaravelApplicationIsReadyWithoutAnEnvFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
    }

    @Test func aWorkspaceThatWaitsFromBeforeARestartGetsItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        let path = RealPath.of(worktree)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(listed: [RealPath.of(shop), path], workspaces: [Workspace(name: "fix", worktree: path, folder: path, branch: "fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
    }

    @Test func aWorkspaceWithoutItsFoldersWaitsForItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shop = root.appending(path: "disk/shop", directoryHint: .isDirectory)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/disk/fix", folder: "/disk/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.preparing])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWithItsOwnCachedConfigurationIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: worktree)
        try await settle(engine)

        #expect(await workspaces(engine).first?.isolationProblem?.contains("The worktree has bootstrap/cache/config.php") == true)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealKeyOfTheSiteThatReplacesADatabaseNameIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("DB_PORT=13999\nDB_DATABASE=shop\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "DB_DATABASE", value: "shop")])]
        state.ports["mysql-8.4"] = 13999
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated("The key DB_DATABASE of the site replaces the value that isolates this workspace.")])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNewKeyOfASiteReachesAWorkspaceThatExistsAndKeepsItsPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")])]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let store = await engine.stateStore
        let port = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first?.ports["scout"])
        let keys = [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}"), WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]

        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: keys)))
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SCOUT_PORT=\(port)\n"))
        #expect(text.contains("SECOND=fix\n"))
    }

    @Test func aWrongEnvKeyNameGivesAnErrorAndChangesNothing() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: [WorkspaceEnvKey(key: "TWO WORDS", value: "1")])))

        #expect(response == .failure(message: "TWO WORDS is not a valid env key. Use letters, digits and underscores, for example SCOUT_PORT."))
        let store = await engine.stateStore
        #expect(await store.current().sites.first?.workspaceKeys == nil)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceKeepsAnEnvFileThatNexusCannotRead() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let unreadable = Data("APP_NAME=Caf".utf8) + [0xE9]

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try unreadable.write(to: worktree.appending(path: ".env"))
        try await settle(engine)

        #expect(try Data(contentsOf: worktree.appending(path: ".env")) == unreadable)
        #expect(await workspaces(engine).map(\.state) == [.notIsolated("Nexus cannot read \(RealPath.of(worktree))/.env as UTF-8 text, so it does not write the .env of this workspace.")])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsTheKeysOfEverySiteOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("<?php", to: "public/index.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.5"),
            Site(host: "b.test", folder: shop.appending(path: "public", directoryHint: .isDirectory), php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SECOND=fix\n"))
    }

    @Test func aRetryAfterTheFixOfTheCauseClearsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        let unknown = await engine.handle(.retryWorkspace(host: "shop.test", name: "other"))
        let retried = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(unknown == .failure(message: "shop.test has no workspace other."))
        #expect(retried == .done(message: "Nexus sets up the workspace fix again."))
        #expect(await workspaces(engine).first?.state != .preparing)
    }

    @Test func aCachedConfigurationOfTheMainCheckoutGivesAWorkspaceThatIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated(ProbeError.cachedConfiguration.description)])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsAnEnvFileWithOnlyTheExpectedChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("""
        APP_NAME=Shop
        APP_URL=https://my.shop.test
        SESSION_DOMAIN=.shop.test
        SESSION_DRIVER=redis
        DB_PORT=13999
        DB_DATABASE=shop
        REDIS_PORT=16999

        """, to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "my.shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")])]
        state.ports["mysql-8.4"] = 13999
        state.ports["redis-8.2"] = 16999
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let store = await engine.stateStore
        let workspace = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first)
        let port = try #require(workspace.ports["scout"])
        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(workspace.state == .ready)
        #expect(workspace.redisIndexes == ["REDIS_DB": 16])
        #expect(text == """
        APP_NAME=Shop
        APP_URL=https://my.shop-fix.test
        SESSION_DOMAIN=.shop-fix.test
        SESSION_DRIVER=redis
        DB_PORT=13999
        DB_DATABASE=shop_fix
        REDIS_PORT=16999
        REDIS_DB=16
        SCOUT_PORT=\(port)

        """)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWritesNoEnvFileThatGitSees() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: "vendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore .env, so Nexus does not write that file.")])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
    }

    @Test func aFailedAutomaticChangeShowsAtTheWorkspaceThatItLeftOut() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop, runtimes: [("php", "8.4"), ("nginx", "1.30")])
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        await engine.recordAutomaticFailure("nginx refused the file.")

        #expect(await workspaces(engine).first?.problem == "The web configuration did not change. nginx refused the file.")
        #expect(await workspaces(engine).first?.url == nil)
    }

    @Test func aWorkspaceThatCanRunHasAURL() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.problem == nil)
        #expect(workspace?.url == "https://shop-fix.test")
    }

    @Test func aWorkspaceWithoutItsPHPVersionHasNoURLAndSaysWhy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "PHP 8.4 is not installed. Run: nexus install php 8.4")
    }

    @Test func aWorkspaceRunsAsASiteWithThePHPAndTheServerOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "my.shop.test", folder: root, aliases: ["blog.local"], php: "8.4", server: .apache)]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "ticket-1", worktree: "/w/ticket-1", folder: "/w/ticket-1")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.conflicts.isEmpty)
        #expect(workspaces.sites == [Site(host: "my.shop-ticket-1.test", folder: URL(filePath: "/w/ticket-1", directoryHint: .isDirectory), aliases: ["blog-ticket-1.test"], php: "8.4", server: .apache)])
    }

    @Test func aWorkspaceWhoseHostIsTakenIsLeftOutWithAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, php: "8.4"),
            Site(host: "shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.isEmpty)
        #expect(Array(workspaces.conflicts.values) == ["The workspace fix does not run, because another site has the host shop-fix.test already."])
    }

    @Test func aWorkspaceThatDoesNotRunHasNoURLAndNamesTheHostThatIsTaken() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, aliases: ["www.shop.test"], php: "8.4"),
            Site(host: "www.shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state)

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "The workspace fix does not run, because another site has the host www.shop-fix.test already.")
    }

    @Test func aHostThatIsTooLongStopsOnlyItsOwnSite() throws {
        let runtime = InstalledRuntime(name: "php", line: "8.4", version: "8.4.0", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/php"))
        let site = Site(host: "\(String(repeating: "a.", count: 130))test", folder: URL(filePath: "/shop"), php: "8.4")

        let problem = NexusEngine.problem(of: site, installed: [runtime], checksNginx: false)

        #expect(problem?.contains("is not a valid host name") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCheckoutInAnEmptyWorktreeGivesADocumentRootInItsPublicFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", worktree.path(percentEncoded: false), "reset", "-q", "--hard", in: shop)
        let documentRoot = "\(RealPath.of(worktree))/public/"

        while await !(engine.appliedSites ?? []).contains(where: { $0.contains(documentRoot) }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func twoSitesOfOneProjectShareOneBlockForAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publicFolder = root.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "a.test", folder: root, php: "8.4"), Site(host: "b.test", folder: publicFolder, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.map(\.hosts) == [["a-fix.test", "b-fix.test"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func aMergeInAWorktreeThatAddsThePublicFolderChangesTheDocumentRoot() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("switch", "-q", "-c", "with-public", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: shop.appending(path: "public/index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        try await git("-C", worktree.path(percentEncoded: false), "merge", "-q", "with-public", in: shop)

        while await engine.appliedSites?.contains(where: { $0.contains("/fix/public") }) != true {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceDoesNotStartAWebServerThatTheUserStopped() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = freePort()
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        var whileStopped, afterStart: Bool?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)
            _ = await engine.handle(.stop(service: ServiceCatalog.nginxID))
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            whileStopped = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
            _ = await engine.handle(.start(service: ServiceCatalog.nginxID))
            afterStart = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
        }

        #expect(whileStopped != true)
        #expect(afterStart == true)
        #expect(await engine.stateStore.current().stoppedByStopAll.isEmpty)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceOpensOverHTTPSWithTheFilesOfItsWorktree() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)

        var main, workspace, gone: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "my.shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)

            let worktree = root.appending(path: "test-1", directoryHint: .isDirectory)
            try await git("worktree", "add", "-q", "-b", "test-1", worktree.path(percentEncoded: false), in: shop)
            try Data("<?php echo 'workspace';".utf8).write(to: worktree.appending(path: "public/index.php"))
            try await settle(engine)

            main = await page("my.shop.test", port: httpsPort, expecting: "main")
            workspace = await page("my.shop-test-1.test", port: httpsPort, expecting: "workspace")

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            gone = await page("my.shop-test-1.test", port: httpsPort, expecting: "main")
        }

        #expect(main == "main")
        #expect(workspace == "workspace")
        #expect(gone != "workspace")
    }

    @Test func aWorktreeThatStaysLockedAfterItsCheckoutGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "claude-test").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "-b", "worktree-claude-test", worktree, in: shop)
        try await git("worktree", "lock", "--reason", "claude agent", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["claude-test"])
    }

    @Test func aLockedWorktreeWithoutACheckoutWaits() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree, in: shop)
        try await git("worktree", "lock", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aWorktreeThatWasThereBeforeTheSiteGetsNoWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try await git("worktree", "add", "-q", "-b", "old", root.appending(path: "old").path(percentEncoded: false), in: shop)

        let engine = try await worktreeEngine(root: root, shop: shop)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aFolderThatGitNoLongerReadsKeepsItsWorkspaces() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let head = shop.appending(path: ".git/HEAD")
        let stored = try Data(contentsOf: head)
        try FileManager.default.removeItem(at: head)

        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        try stored.write(to: head)
    }

    @Test func theSettingOfASiteChangesWithAnEditWithoutANewWebConfiguration() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(automaticWorkspaces: false)))
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        guard case .done = response else {
            Issue.record("No change: \(response)")
            return
        }

        guard case .sites(let sites) = await engine.handle(.sites) else {
            Issue.record("No sites")
            return
        }

        #expect(sites.first?.automaticWorkspaces == false)
        #expect(sites.first?.workspaces == [])
    }

    @Test func aRemovedSiteTakesItsWorkspaceRecordWithIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore

        try await store.update { $0.sites = [] }
        try await settle(engine)

        #expect(await store.current().worktrees.isEmpty)
    }

    @Test func aRemovedSiteTakesItsRecordAlsoWhenAnotherSiteIsInItsFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let backend = shop.appending(path: "backend", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, php: "8.4"),
            Site(host: "backend.test", folder: backend, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        let store = await engine.stateStore

        try await store.update { $0.sites.removeAll { $0.host == "shop.test" } }
        try await settle(engine)

        #expect(await store.current().worktrees.keys.sorted() == [RealPath.of(backend)])
    }

    @Test func theMessageOfTheSettingCountsTheOtherSiteOfTheProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.4"),
            Site(host: "b.test", folder: publicFolder, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)

        let response = await engine.handle(.editSite(host: "b.test", change: SiteChange(automaticWorkspaces: false)))

        guard case .done(let message) = response else {
            Issue.record("No change: \(response)")
            return
        }

        #expect(message.contains("A new worktree gets a workspace."))
    }

    @Test func aSiteOnAPublicFolderKeepsItsWorkspacesWhileComposerJSONIsGone() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        let composerFile = shop.appending(path: "composer.json")
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: composerFile)
        let engine = try await worktreeEngine(root: root, shop: publicFolder)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let store = await engine.stateStore

        try FileManager.default.removeItem(at: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix")) + "/public"])

        try Data("{}".utf8).write(to: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix"))])
        #expect(await store.current().worktrees.count == 1)
    }

    @Test func aWorktreeAfterALaterGitInitGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)

        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfASiteFindsAGitInitWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("init", "-q", "-b", "main", in: shop)

        while await engine.watchedRepositories.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aFolderThatDoesNotExistKeepsItsWorkspaceRecord() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore
        let record = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/nexus/no/such/fix", folder: "/nexus/no/such/fix")])

        try await store.update { $0.worktrees["/nexus/no/such/shop"] = record }
        try await settle(engine)

        #expect(await store.current().worktrees["/nexus/no/such/shop"] == record)
    }

    @Test(arguments: [("a.test", "b.test"), ("b.test", "a.test")])
    func twoSitesOfOneProjectGiveAWorkspaceWhenOneHasTheSettingOn(on: String, off: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: on, folder: shop, php: "8.4", automaticWorkspaces: true),
            Site(host: off, folder: publicFolder, php: "8.4", automaticWorkspaces: false),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix", "fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfTheGitFolderFindsANewWorktreeWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(await workspaces(engine).map(\.name) == ["fix"])

        let moved = root.appending(path: "other/fix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git("worktree", "move", root.appending(path: "fix").path(percentEncoded: false), moved.path(percentEncoded: false), in: shop)

        while await workspaces(engine).first?.folder != RealPath.of(moved) {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", moved.path(percentEncoded: false), "switch", "-q", "-c", "second", in: shop)

        while await workspaces(engine).first?.branch != "second" {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("worktree", "remove", moved.path(percentEncoded: false), in: shop)

        while await !workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

extension NexusEngine {
    func recordAutomaticFailure(_ failure: String) {
        appliedSites = []
        automaticWebFailure = failure
    }
}

extension NexusEngine {
    var workspaceWorkRuns: Bool {
        reconcilingWorkspaces || settingUpWorkspaces
    }
}
