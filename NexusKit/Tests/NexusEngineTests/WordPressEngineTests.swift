import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
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

    @Test func aWorkspaceOfAWordPressSiteThatIsNotIsolatedRunsNoPHP() async throws {
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

        guard case .notIsolated(let reason) = workspace.state else {
            Issue.record("The workspace is \(workspace.state), not Not isolated.")
            return
        }

        #expect(workspace.configurationDigest != nil)
        #expect(hosts == ["shop-fix.test"])
        #expect(inWorktree == .failure(message: "nexus wp does not run in the workspace fix, because it is not isolated. \(reason)"))
        #expect(php == .failure(message: "nexus php does not run in the workspace fix, because it is not isolated. \(reason)"))
        #expect(composer == .failure(message: "nexus composer does not run in the workspace fix, because it is not isolated. \(reason)"))

        if case .failure(let message) = npm {
            #expect(!message.contains("does not run in the workspace fix"))
        }

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

        guard case .failure(let message) = inWorktree else {
            Issue.record("nexus wp ran in the workspace: \(inWorktree)")
            return
        }

        #expect(message.hasPrefix("nexus wp does not run in the workspace fix, because it is not isolated."))
    }

    @Test func aReadyWorkspaceOfAWordPressSiteRunsPHP() async throws {
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
        let inWorktree = await engine.handle(.tool(.wp, folder: worktree.path(percentEncoded: false)))

        #expect(await engine.workspaceSites(current).noticeHosts.isEmpty)

        if case .failure(let message) = inWorktree {
            #expect(!message.contains("does not run in the workspace"))
        }
    }

    @Test func aWorkspaceOfAWordPressSiteFromBeforeItsSetupGetsTheSetup() async throws {
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
            state.worktrees[RealPath.of(shop)]?.workspaces[0].configurationDigest = nil
        }

        try await settleWorkspaces(engine)

        let workspace = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first

        #expect(workspace?.state.isNotIsolated == true)
        #expect(workspace?.configurationDigest != nil)
    }

    private func write(network: (from: String, to: String)? = nil, redisIndex: Int? = nil) -> NexusEngine.WordPressWrite {
        let runtime = InstalledRuntime(name: "mysql", line: "8.4", version: "8.4.0", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/tmp/mysql"))

        return NexusEngine.WordPressWrite(
            core: URL(filePath: "/w/fix", directoryHint: .isDirectory),
            php: "8.4",
            tools: DatabaseTools(id: "mysql-8.4", kind: .mysql, runtime: runtime),
            serverPort: 20001,
            mainPort: 13307,
            url: "https://blog-fix.test",
            siteURL: "https://blog-fix.test",
            mainURL: "https://blog.test",
            network: network,
            database: "blog",
            tablePrefix: "wp_",
            redisIndex: redisIndex,
            isBedrock: false,
            configName: "wp-config.php"
        )
    }

    @Test func theCheckAcceptsAWorkspaceOnItsOwnServerAndURL() {
        let answer = NexusEngine.WorkspaceCheck(host: "127.0.0.1:20001", home: "https://blog-fix.test/", network: nil, redis: 17, storedHome: "https://blog.test")

        #expect(NexusEngine.workspaceCheckProblems(answer, write: write(redisIndex: 17)).isEmpty)
    }

    @Test func theCheckRefusesTheServerTheURLAndTheRedisIndexOfTheMainSite() {
        let answer = NexusEngine.WorkspaceCheck(host: "127.0.0.1:13307", home: "https://blog.test", network: nil, redis: nil, storedHome: "https://blog.test")

        #expect(NexusEngine.workspaceCheckProblems(answer, write: write(redisIndex: 17)) == [
            "WordPress in this workspace connects to 127.0.0.1:13307. That is the server of the main site, not the server of the workspace.",
            "WordPress in this workspace uses the URL https://blog.test, not the URL https://blog-fix.test of the workspace.",
            "WordPress in this workspace uses the Redis database 0, not the database 17 of the workspace.",
        ])
    }

    @Test func aNetworkMustHaveTheDomainOfTheWorkspace() {
        let moved = NexusEngine.WorkspaceCheck(host: "127.0.0.1:20001", home: "https://blog.test", network: "blog-fix.test", redis: nil, storedHome: "https://blog.test")
        let notMoved = NexusEngine.WorkspaceCheck(host: "127.0.0.1:20001", home: "https://blog.test", network: "blog.test", redis: nil, storedHome: "https://blog.test")

        #expect(NexusEngine.workspaceCheckProblems(moved, write: write(network: ("blog.test", "blog-fix.test"))).isEmpty)
        #expect(NexusEngine.workspaceCheckProblems(notMoved, write: write(network: ("blog.test", "blog-fix.test"))) == ["The network in this workspace has the domain blog.test, not the domain blog-fix.test of the workspace."])
        #expect(NexusEngine.workspaceCheckProblems(notMoved, write: write()) == ["This site is a network, but Nexus cannot read MULTISITE in wp-config.php as plain text. So the network keeps the domain blog.test in this workspace."])
    }

    @Test(arguments: [
        ("127.0.0.1:13307", [String]()),
        ("localhost", ["DB_HOST of the main site is localhost. PHP then uses a socket, and a socket ignores the port of the server of the workspace. Use \"Set DB_HOST…\" in the section WordPress."]),
        ("db.example.com", ["DB_HOST names db.example.com. Nexus did not make that server, so it cannot give this workspace its own copy."]),
        ("127.0.0.1:8889", ["DB_HOST names 127.0.0.1:8889. Nexus did not make that server, so it cannot give this workspace its own copy."]),
    ])
    func dbHostMustNameANexusInstanceWithItsPort(dbHost: String, problems: [String]) {
        #expect(NexusEngine.dbHostProblems(WordPressConfig(host: dbHost), file: "wp-config.php", mysqlPorts: [13307]) == problems)
    }

    @Test func aNetworkMovesFromItsDomainToTheDomainOfTheWorkspace() {
        let classic = NexusEngine.networkDomains(of: WordPressConfig(multisite: true, domainCurrentSite: "shop.test"), type: .wordpress, mainURL: "https://shop.test", url: "https://shop-fix.test:8443")
        let bedrock = NexusEngine.networkDomains(of: WordPressConfig(domainCurrentSite: "shop.test"), type: .bedrock, mainURL: "https://shop.test", url: "https://shop-fix.test")

        #expect(classic?.from == "shop.test")
        #expect(classic?.to == "shop-fix.test:8443")
        #expect(bedrock?.to == "shop-fix.test")
        #expect(NexusEngine.networkDomains(of: WordPressConfig(domainCurrentSite: "shop.test"), type: .wordpress, mainURL: "https://shop.test", url: "https://shop-fix.test") == nil)
    }

    @Test func aWorkspaceGetsTheAccountOfTheMainSiteWithItsServer() {
        let config = WordPressConfig(database: "blog", user: "root", password: "secret")
        let site = NexusEngine.workspaceValues(config: config, databaseHost: "127.0.0.1:20001", url: "https://blog-fix.test", siteURL: "https://blog-fix.test/wp", network: nil, redisIndex: 16)
        let network = NexusEngine.workspaceValues(config: WordPressConfig(database: "blog"), databaseHost: "127.0.0.1:20001", url: "https://blog-fix.test", siteURL: "https://blog-fix.test", network: ("blog.test", "blog-fix.test"), redisIndex: nil)

        #expect(site.map(\.name) == ["DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST", "WP_HOME", "WP_SITEURL", "WP_REDIS_DATABASE"])
        #expect(site.map(\.value) == ["blog", "root", "secret", "127.0.0.1:20001", "https://blog-fix.test", "https://blog-fix.test/wp", "16"])
        #expect(network.map(\.name) == ["DB_NAME", "DB_HOST", "DOMAIN_CURRENT_SITE"])
    }

    @Test func theNetworkRowNamesTheKindTheNumberAndASecondSite() throws {
        let root = wordPressRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try file("<?php\ndefine( 'MULTISITE', true );\ndefine( 'SUBDOMAIN_INSTALL', true );\n", at: "wp-config.php", in: root.appending(path: "sub"))
        try file("<?php", at: "wp-load.php", in: root.appending(path: "sub"))
        try file("<?php\ndefine( 'MULTISITE', true );\n", at: "wp-config.php", in: root.appending(path: "folders"))
        try file("<?php", at: "wp-load.php", in: root.appending(path: "folders"))
        let sub = Site(host: "shop.test", folder: root.appending(path: "sub"), php: "8.4")
        let folders = Site(host: "shop.test", folder: root.appending(path: "folders"), php: "8.4")
        let local = Site(host: "shop.local", folder: root.appending(path: "sub"), php: "8.4")
        let network = { (count: Int?, blogs: [[String]]?, site: Site) in NexusEngine.network(count: count, blogs: blogs, site: site, configName: "wp-config.php", tld: "test") }

        let subdomains = try #require(network(3, [["shop.test:8443", "/"], ["blog.shop.test:8443", "/"]], sub))
        let subfolders = try #require(network(2, [["shop.test", "/"], ["shop.test", "/blog/"]], folders))
        let unread = try #require(network(2, [["shop.test", "/"], ["blog.shop.test", "/"]], folders))
        let outside = try #require(network(2, [["shop.local", "/"], ["blog.shop.local", "/"]], local))

        #expect(subdomains == WordPressNetwork(host: "shop.test", subdomains: true, sites: 3, example: "blog.shop.test"))
        #expect(subdomains.summary == "3 sites on subdomains, for example blog.shop.test")
        #expect(subdomains.servedText == "Nexus serves each name below shop.test with HTTPS, for example blog.shop.test.")
        #expect(subfolders.summary == "2 sites in subfolders, for example shop.test/blog")
        #expect(subfolders.servedText == nil)
        #expect(unread.problem?.hasPrefix("The sites of this network are on subdomains, but Nexus cannot read SUBDOMAIN_INSTALL") == true)
        #expect(outside.problem?.hasPrefix("The sites of this network need the names below shop.local.") == true)
        #expect(network(1, [["shop.test", "/"]], sub)?.summary == "1 site on subdomains")
        #expect(network(nil, nil, sub) == nil)
    }

    @Test func eachSiteOfASubdomainNetworkMovesWithTheDomainOfTheNetwork() {
        let moves = NexusEngine.subsiteMoves(of: ["example.com", "blog.example.com", "brand.test", "news.example.com"], from: "example.com", to: "shop.test:8443")

        #expect(moves == [
            WorkspaceLinks.Move(from: "https://blog.example.com", to: "https://blog.shop.test:8443"),
            WorkspaceLinks.Move(from: "https://news.example.com", to: "https://news.shop.test:8443"),
        ])
    }

    @Test func onlyAWordPressRecordWithoutADigestGetsANewSetup() {
        let old = Workspace(name: "old", worktree: "/w/old", folder: "/w/old", state: .ready)
        let checked = Workspace(name: "checked", worktree: "/w/checked", folder: "/w/checked", state: .ready, configurationDigest: "digest")
        let waiting = Workspace(name: "waiting", worktree: "/w/waiting", folder: "/w/waiting")
        let worktrees = ["/shop": SiteWorktrees(listed: [], workspaces: [old, checked, waiting]), "/app": SiteWorktrees(listed: [], workspaces: [old])]

        let changed = NexusEngine.settingUpOldWordPressWorkspaces(of: worktrees, keys: ["/shop"])

        #expect(changed?["/shop"]?.workspaces.map(\.state) == [.preparing, .ready, .preparing])
        #expect(changed?["/app"]?.workspaces.map(\.state) == [.ready])
        #expect(NexusEngine.settingUpOldWordPressWorkspaces(of: worktrees, keys: []) == nil)
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
