import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Synchronization
import Testing
@testable import NexusEngine

// The answers of a fake probe of F1. An empty list gives the answer of a page without a redirect.
final class FakeRedirectProbe: Sendable {
    private let state: Mutex<(answers: [String?], asked: Int)>

    init(_ answers: [String?] = []) {
        state = Mutex((answers, 0))
    }

    var asked: Int {
        state.withLock { $0.asked }
    }

    var probe: @Sendable (String, Int) async -> String? {
        { _, _ in
            self.state.withLock { state in
                state.asked += 1
                return state.answers.isEmpty ? "" : state.answers.removeFirst()
            }
        }
    }
}

extension NexusEngine {
    func useRedirectProbe(_ probe: @escaping @Sendable (String, Int) async -> String?) {
        shareRedirectProbe = probe
    }

    func useHostPlan(_ plan: ShareHostPlan, for id: String) {
        shareHostPlans[id] = plan
    }

    func hostPlan(of id: String) -> ShareHostPlan? {
        shareHostPlans[id]
    }

    func useMainProcessPlan(_ plan: MainProcessPlan, for key: String) {
        mainProcessPlans[key] = plan
    }
}

@Suite(.serialized)
struct ShareHostsEngineTests {
    private let base = NexusEngineTests()
    private static let id = "0123456789abcdef0123456789abcdef"
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"
    private static let reverbEnv = "BROADCAST_CONNECTION=reverb\nREVERB_APP_ID=123456\nREVERB_APP_KEY=app-key\n"

    private func folder(_ name: String, in root: URL, files: [String: String]) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)

        for (path, text) in files {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func engine(root: URL, state: EngineState, njs: Bool = true, php: [String] = [], dumpLibrary: URL? = nil) async throws -> NexusEngine {
        var state = state
        state.ports[ServiceCatalog.httpsPortKey] = state.ports[ServiceCatalog.httpsPortKey] ?? 30443
        state.ports[ServiceCatalog.httpPortKey] = state.ports[ServiceCatalog.httpPortKey] ?? 30080
        let engine = try base.makeSiteEngine(root: root, state: state, runtimes: [("nginx", "1.30")] + php.map { ("php", $0) }, dumpLibrarySource: dumpLibrary)

        if njs {
            let module = await engine.paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so")
            try FileManager.default.createDirectory(at: module.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: module)
        }

        return engine
    }

    private func record(_ host: String, mode: ShareHostMode, state: ShareState = .starting(.openLink), publicHost: String? = nil) -> ShareRecord {
        ShareRecord(id: Self.id, host: host, site: host, options: .standard, mode: mode, publicHost: publicHost, started: .now, state: state)
    }

    // The step of 4c for a link that starts. Each step checks that its link still starts.
    private func prepare(_ engine: NexusEngine, target: ShareTarget, mode: ShareHostMode) async throws {
        let link = record(target.host, mode: mode)

        try await engine.stateStore.update { state in
            state.shares = [link]
        }

        try await engine.prepareShareHosts(link, target: target, project: project(engine, target))
    }

    private func project(_ engine: NexusEngine, _ target: ShareTarget) async -> ShareProject? {
        await engine.shareProject(of: target, in: engine.stateStore.current())
    }

    private func hostMode(_ engine: NexusEngine, _ target: ShareTarget) async -> ShareHostMode {
        await engine.linkHostMode(of: target, project: project(engine, target))
    }

    private func plan(reverb: ShareReverb? = nil, envValues: [String: String] = [:], usesWordPress: Bool = false, php: String? = "8.5", phpInNginx: Bool = true) -> ShareHostPlan {
        ShareHostPlan(redirectHost: nil, extraHosts: [], envValues: envValues, reverb: reverb, usesWordPress: usesWordPress, php: php, phpInNginx: phpInNginx)
    }

    // MARK: The mode

    @Test func onlyLaravelInNginxWithoutACachedConfigSeesThePublicHost() throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let laravel = ["artisan": "", "bootstrap/app.php": "<?php\n", "composer.json": "{\"require\":{\"laravel/framework\":\"^13.0\"}}", "public/index.php": "<?php\n"]
        let laravelFolder = try folder("laravel", in: root, files: laravel)
        let cached = try folder("cached", in: root, files: laravel.merging(["bootstrap/cache/config.php": "<?php return [];\n"]) { first, _ in first })
        let statamic = try folder("statamic", in: root, files: ["artisan": "", "bootstrap/app.php": "<?php\n"])
        let worktree = try folder("worktrees/fix", in: root, files: laravel)
        let wordPress = try folder("wordpress", in: root, files: ["wp-load.php": "<?php\n", "wp-config.php": "<?php\n"])
        let bedrock = try folder("bedrock", in: root, files: ["composer.json": "{\"require\":{\"roots/bedrock-autoloader\":\"^1.0\"}}", "web/index.php": "<?php\n"])
        let plain = try folder("plain", in: root, files: ["index.php": "<?php\n"])
        let node = try folder("node", in: root, files: ["package.json": "{\"devDependencies\":{\"vite\":\"^8.0.0\"}}"])
        let mode = { (site: Site, isNotice: Bool) in NexusEngine.hostMode(of: site, layout: SiteLayout(of: site), isNotice: isNotice) }

        #expect(mode(Site(host: "laravel.test", folder: laravelFolder, php: "8.5"), false) == .publicHost)
        #expect(mode(Site(host: "statamic.test", folder: statamic, php: "8.5"), false) == .publicHost)
        #expect(mode(Site(host: "fix.laravel.test", folder: worktree, php: "8.5"), false) == .publicHost)
        #expect(mode(Site(host: "cached.test", folder: cached, php: "8.5"), false) == .localHost)
        #expect(mode(Site(host: "laravel.test", folder: laravelFolder, php: "8.5", server: .apache), false) == .localHost)
        #expect(mode(Site(host: "laravel.test", folder: laravelFolder, php: "8.5"), true) == .localHost)
        #expect(mode(Site(host: "wp.test", folder: wordPress, php: "8.4"), false) == .localHost)
        #expect(mode(Site(host: "wp.test", folder: wordPress, php: "8.4", server: .apache), false) == .localHost)
        #expect(mode(Site(host: "bedrock.test", folder: bedrock, php: "8.4"), false) == .localHost)
        #expect(mode(Site(host: "plain.test", folder: plain, php: "8.5"), false) == .localHost)
        #expect(mode(Site(host: "app.test", folder: node, php: "8.5", runsAs: .node, command: "npm run dev"), false) == .localHost)
        #expect(mode(Site(host: "octane.test", folder: laravelFolder, php: "8.5", runsAs: .proxy, address: "http://127.0.0.1:8000"), false) == .localHost)
    }

    // MARK: The values of the .env

    @Test func thePublicValuesOfTheEnvNameTheWholeLocalHostOnly() {
        let env = [
            "APP_DOMAIN": "shop.test",
            "ADMIN_DOMAIN": "admin.shop.test",
            "CMS_URL": "https://shop.test:30443/cms",
            "OLD_URL": "http://shop.test:30080/old",
            "PLAIN_URL": "http://SHOP.test/plain",
            "SANCTUM_STATEFUL_DOMAINS": "shop.test,localhost",
            "OTHER_SITE": "https://shop.test.example.com",
            "MAIL_USERNAME": "shop.test",
            "DB_HOST": "shop.test",
            "REDIS_HOST": "shop.test",
            "SESSION_DOMAIN": ".shop.test",
            "APP_URL": "https://shop.test:30443",
            "REVERB_HOST": "shop.test",
            "WITH_DOLLAR": "https://shop.test/${PATH}",
            "WITH_QUOTE": "shop.test\"",
            "WITH_BACKSLASH": "shop.test\\x",
            "KEY.WITH.DOT": "shop.test",
        ]

        #expect(NexusEngine.publicEnvValues(in: env, host: "shop.test", httpsPort: 30443, httpPort: 30080) == [
            "APP_DOMAIN": "$http_x_nexus_share_host",
            "CMS_URL": "https://$http_x_nexus_share_host/cms",
            "OLD_URL": "https://$http_x_nexus_share_host/old",
            "PLAIN_URL": "https://$http_x_nexus_share_host/plain",
            "SANCTUM_STATEFUL_DOMAINS": "$http_x_nexus_share_host,localhost",
            "REVERB_HOST": "$http_x_nexus_share_host",
        ])
    }

    @Test func aSiteWithReverbSendsItsOwnValuesOfReverbAndNotThoseOfTheEnv() {
        let env = EnvFile.values(in: Self.reverbEnv + "REVERB_HOST=shop.test\nREVERB_SCHEME=https\nAPP_DOMAIN=shop.test\n")

        #expect(NexusEngine.publicEnvValues(in: env, host: "shop.test", httpsPort: 30443, httpPort: 30080) == ["APP_DOMAIN": "$http_x_nexus_share_host"])
    }

    @Test func theEnvNamesAHostOfNexusOnlyAsAWholeHost() {
        let env = ["CMS_URL": "https://cms.shop.test:30443/x", "API": "api.shop.test", "OTHER": "https://example.com/blog.test"]

        #expect(NexusEngine.envHosts(in: env, known: ["cms.shop.test", "shop.test", "nowhere.test", "blog.test"]) == ["blog.test", "cms.shop.test"])
        #expect(NexusEngine.envHosts(in: ["API": "api.shop.test"], known: ["shop.test"]).isEmpty)
    }

    @Test func reverbNeedsItsDriverAndSafeKeysAndTakesTheKnownPortFirst() {
        let env = EnvFile.values(in: Self.reverbEnv)
        let withPort = EnvFile.values(in: Self.reverbEnv + "REVERB_SERVER_PORT=8090\n")

        #expect(NexusEngine.reverb(in: env, port: nil) == ShareReverb(port: 8080, key: "app-key", appID: "123456"))
        #expect(NexusEngine.reverb(in: withPort, port: nil)?.port == 8090)
        #expect(NexusEngine.reverb(in: withPort, port: 6001)?.port == 6001)
        #expect(NexusEngine.reverb(in: EnvFile.values(in: "BROADCAST_DRIVER=reverb\nREVERB_APP_ID=1\nREVERB_APP_KEY=k\n"), port: nil) != nil)
        #expect(NexusEngine.reverb(in: EnvFile.values(in: Self.reverbEnv.replacingOccurrences(of: "=reverb", with: "=log")), port: nil) == nil)
        #expect(NexusEngine.reverb(in: EnvFile.values(in: Self.reverbEnv.replacingOccurrences(of: "app-key", with: "app/key")), port: nil) == nil)
        #expect(NexusEngine.reverb(in: EnvFile.values(in: "BROADCAST_CONNECTION=reverb\nREVERB_APP_ID=1\nREVERB_APP_KEY=\n"), port: nil) == nil)
    }

    // MARK: The probe of F1

    @Test func onlyARedirectToAnotherNameOfTheSameSiteGivesAHost() {
        let names = ["shop.test", "www.shop.test"]

        #expect(NexusEngine.redirectHost(from: "https://www.shop.test:30443/", names: names, host: "shop.test") == "www.shop.test")
        #expect(NexusEngine.redirectHost(from: "https://WWW.shop.test/", names: names, host: "shop.test") == "www.shop.test")
        #expect(NexusEngine.redirectHost(from: "https://example.com/", names: names, host: "shop.test") == nil)
        #expect(NexusEngine.redirectHost(from: "https://shop.test:30443/login", names: names, host: "shop.test") == nil)
        #expect(NexusEngine.redirectHost(from: "", names: names, host: "shop.test") == nil)
    }

    @Test func theAnswerOfCurlGivesTheURLOfARedirectAndNilForASiteThatStarts() {
        #expect(NexusEngine.probeAnswer("301 https://www.shop.test:30443/") == "https://www.shop.test:30443/")
        #expect(NexusEngine.probeAnswer("302 https://shop.test/login\n") == "https://shop.test/login")
        #expect(NexusEngine.probeAnswer("200 ") == "")
        #expect(NexusEngine.probeAnswer("404 ") == "")
        #expect(NexusEngine.probeAnswer("302 ") == "")
        #expect(NexusEngine.probeAnswer("502 ") == nil)
        #expect(NexusEngine.probeAnswer("503 ") == nil)
        #expect(NexusEngine.probeAnswer("504 ") == nil)
        #expect(NexusEngine.probeAnswer("000 ") == nil)
        #expect(NexusEngine.probeAnswer("") == nil)
    }

    private func linkState(_ root: URL) throws -> EngineState {
        let shop = try folder("shop", in: root, files: ["index.php": "<?php\n", ".env": "CMS_URL=https://cms.test:30443/x\nAPI_URL=https://api.test/v1\nFAR=https://example.com\n"])
        let cms = try folder("cms", in: root, files: ["index.php": "<?php\n"])
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, aliases: ["www.shop.test", "admin.shop.test", "*.shop.test"], php: "8.5"),
            Site(host: "cms.test", folder: cms, php: "8.5"),
        ]
        return state
    }

    @Test func localModeAsksTheProbeOneTimeAndThePlanHoldsTheOtherHostsSorted() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try linkState(root)
        let engine = try await engine(root: root, state: state)
        let probe = FakeRedirectProbe(["https://www.shop.test:30443/"])
        await engine.useRedirectProbe(probe.probe)
        let target = try await engine.shareTarget(naming: "shop.test", in: engine.stateStore.current())

        try await prepare(engine, target:target, mode: .localHost)
        let plan = try #require(await engine.hostPlan(of: Self.id))

        #expect(probe.asked == 1)
        #expect(plan.redirectHost == "www.shop.test")
        #expect(plan.extraHosts == ["admin.shop.test", "cms.test"])
        #expect(plan.envValues.isEmpty)
        #expect(plan.php == "8.5")
        #expect(plan.phpInNginx)
        #expect(!plan.usesWordPress)
        let current = await engine.stateStore.current()
        #expect(await engine.sharePreviewHosts(of: target, project: engine.shareProject(of: target, in: current), targets: engine.shareTargets(current)) == ["admin.shop.test", "cms.test", "www.shop.test"])
    }

    @Test func publicModeDoesNotAskTheProbeAndKeepsTheValuesOfTheEnv() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root, files: ["artisan": "", "bootstrap/app.php": "<?php\n", ".env": "APP_DOMAIN=shop.test\n"])
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try await engine(root: root, state: state)
        let probe = FakeRedirectProbe()
        await engine.useRedirectProbe(probe.probe)
        let target = try await engine.shareTarget(naming: "shop.test", in: engine.stateStore.current())

        #expect(await hostMode(engine, target) == .publicHost)

        try await prepare(engine, target:target, mode: .publicHost)

        #expect(probe.asked == 0)
        #expect(await engine.hostPlan(of: Self.id)?.envValues == ["APP_DOMAIN": "$http_x_nexus_share_host"])
        #expect(await engine.hostPlan(of: Self.id)?.redirectHost == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theProbeTriesAgainWhileTheSiteStarts() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await engine(root: root, state: try linkState(root))
        let probe = FakeRedirectProbe([nil, nil, nil, "https://www.shop.test:30443/"])
        await engine.useRedirectProbe(probe.probe)
        let target = try await engine.shareTarget(naming: "shop.test", in: engine.stateStore.current())

        try await prepare(engine, target:target, mode: .localHost)

        #expect(probe.asked == 4)
        #expect(await engine.hostPlan(of: Self.id)?.redirectHost == "www.shop.test")
    }

    @Test func theReverbPortComesFromTheWorkspaceOrFromThePlanOfTheMainCheckout() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop", in: root, files: ["artisan": "", "bootstrap/app.php": "<?php\n", ".env": Self.reverbEnv + "REVERB_SERVER_PORT=8090\n"])
        let worktree = try folder("fix", in: root, files: ["artisan": "", "bootstrap/app.php": "<?php\n", ".env": Self.reverbEnv + "REVERB_SERVER_PORT=8091\n"])
        let site = Site(host: "shop.test", folder: shop, php: "8.5")
        let key = ProjectFolder.workspaceKey(of: site)
        var state = EngineState()
        state.sites = [site]
        state.worktrees[key] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: worktree.path(percentEncoded: false), folder: worktree.path(percentEncoded: false), state: .ready, ports: ["reverb": 6002])])
        let engine = try await engine(root: root, state: state)
        let current = await engine.stateStore.current()
        let main = try await engine.shareTarget(naming: "shop.test", in: current)
        let workspace = try await engine.shareTarget(naming: HostName.workspaceHost("shop.test", workspace: "fix", tld: current.tld), in: current)

        try await prepare(engine, target:main, mode: .publicHost)
        let fromEnv = await engine.hostPlan(of: Self.id)?.reverb

        await engine.useMainProcessPlan(MainProcessPlan(folder: shop.path(percentEncoded: false), preset: [], database: nil, reverbPort: 7001), for: key)
        try await prepare(engine, target:main, mode: .publicHost)
        let fromConfiguration = await engine.hostPlan(of: Self.id)?.reverb?.port

        await engine.useMainProcessPlan(MainProcessPlan(folder: shop.path(percentEncoded: false), preset: [], database: nil, reverbPort: 7001, ports: ["reverb": 7002]), for: key)
        try await prepare(engine, target:main, mode: .publicHost)
        let fromPorts = await engine.hostPlan(of: Self.id)?.reverb?.port

        try await prepare(engine, target:workspace, mode: .publicHost)
        let fromWorkspace = await engine.hostPlan(of: Self.id)?.reverb?.port

        #expect(fromEnv == ShareReverb(port: 8090, key: "app-key", appID: "123456"))
        #expect(fromConfiguration == 7001)
        #expect(fromPorts == 7002)
        #expect(fromWorkspace == 6002)
        #expect(await hostMode(engine, workspace) == .publicHost)
    }

    @Test func withoutNjsEachLinkGetsTheTextOfTheModuleAndNoPlan() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await engine(root: root, state: try linkState(root), njs: false)
        let target = try await engine.shareTarget(naming: "shop.test", in: engine.stateStore.current())
        let gone = ShareTarget(host: "gone.test", site: "gone.test", workspace: nil, owner: "gone", names: ["gone.test"])

        await #expect(throws: RuntimeError.unsupported(ShareText.njsMissing)) {
            try await prepare(engine, target:target, mode: .localHost)
        }
        await #expect(throws: RuntimeError.unsupported(ShareText.njsMissing)) {
            try await prepare(engine, target:gone, mode: .localHost)
        }
        #expect(await engine.hostPlan(of: Self.id) == nil)
    }

    @Test func aTargetWithoutASiteGetsThePlainPlan() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await engine(root: root, state: try linkState(root))
        let gone = ShareTarget(host: "gone.test", site: "gone.test", workspace: nil, owner: "gone", names: ["gone.test"])

        try await prepare(engine, target:gone, mode: .localHost)

        #expect(await engine.hostPlan(of: Self.id) == .plain)
        #expect(await hostMode(engine, gone) == .localHost)
    }

    // MARK: The values of the site block

    @Test func publicModeGivesTheValuesOfTheHostAndReverbAndLocalModeOnlyTheHostOfTheLink() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await engine(root: root, state: EngineState())
        let host = "$http_x_nexus_share_host"

        await engine.useHostPlan(plan(reverb: ShareReverb(port: 8080, key: "k", appID: "1"), envValues: ["APP_DOMAIN": host, "APP_URL": "x"]), for: Self.id)
        let publicValues = await engine.shareFastCGIValues(of: record("shop.test", mode: .publicHost))
        let localValues = await engine.shareFastCGIValues(of: record("shop.test", mode: .localHost))

        await engine.useHostPlan(plan(phpInNginx: false), for: Self.id)
        let apache = await engine.shareFastCGIValues(of: record("shop.test", mode: .localHost))

        #expect(publicValues == [
            "NEXUS_SHARE_HOST": host,
            "HTTP_HOST": host,
            "SERVER_NAME": host,
            "SERVER_PORT": "443",
            "APP_URL": "https://\(host)",
            "SESSION_DOMAIN": "null",
            "REVERB_HOST": host,
            "REVERB_PORT": "443",
            "REVERB_SCHEME": "https",
            "APP_DOMAIN": host,
        ])
        #expect(localValues == ["NEXUS_SHARE_HOST": host])
        #expect(apache.isEmpty)
    }

    @Test func theBuildOfALinkGetsThePublicHostOfReverbOnlyWithReverbAndAPublicHost() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await engine(root: root, state: EngineState())

        await engine.useHostPlan(plan(reverb: ShareReverb(port: 8080, key: "k", appID: "1")), for: Self.id)

        #expect(NexusEngine.viteReverbValues(publicHost: Self.publicHost, usesReverb: true) == ["VITE_REVERB_HOST": Self.publicHost, "VITE_REVERB_PORT": "443", "VITE_REVERB_SCHEME": "https"])
        #expect(NexusEngine.viteReverbValues(publicHost: Self.publicHost, usesReverb: false).isEmpty)
        #expect(await engine.viteEnvironment(of: record("shop.test", mode: .publicHost)).isEmpty)
        #expect(await engine.viteEnvironment(of: record("shop.test", mode: .publicHost, publicHost: Self.publicHost))["VITE_REVERB_HOST"] == Self.publicHost)
    }

    @Test func njsLoadsOnlyWithALinkAndOnlyWhenTheRuntimeHasIt() {
        let available: Set<String> = ["ngx_http_js_module", "ngx_stream_module"]

        #expect(NexusEngine.modules(["ngx_stream_module"], available: available, withShares: true) == ["ngx_stream_module", "ngx_http_js_module"])
        #expect(NexusEngine.modules(["ngx_stream_module"], available: available, withShares: false) == ["ngx_stream_module"])
        #expect(NexusEngine.modules([], available: ["ngx_stream_module"], withShares: true).isEmpty)
        #expect(NexusEngine.modules(["ngx_http_js_module"], available: available, withShares: true) == ["ngx_http_js_module"])
    }

    // MARK: The stub of WordPress

    private func fakeDumpLibrary(in root: URL) throws -> URL {
        try folder("Nexus.app/Contents/Resources/php/dumps", in: root, files: [
            "prepend.php": "<?php\n",
            "src/PublicLink.php": "<?php\n",
            "vendor/var-dumper/VERSION": "v7.4.22\n",
            "HASH": "0123456789ab\n",
        ])
    }

    @Test func aLinkOfAWordPressSiteWritesTheStubOfItsPHPVersionOnlyWhileItIsOpen() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = EngineState()
        state.shares = [record("wp.test", mode: .localHost, state: .open)]
        let engine = try await engine(root: root, state: state, php: ["8.4", "8.5"], dumpLibrary: try fakeDumpLibrary(in: root))
        let paths = await engine.paths
        let stub = { (line: String) in paths.phpConfigFolder(line: line).appending(path: PHPConfig.dumpStubName) }
        let commands = paths.phpConfigFolder(line: "8.4").appending(path: "\(PHPConfig.dumpsFolderName)/\(PHPConfig.dumpsIniName)")

        await engine.useHostPlan(plan(usesWordPress: true, php: "8.4"), for: Self.id)
        _ = try await engine.writePHPConfig(line: "8.4", state: await engine.stateStore.current())
        _ = try await engine.writePHPConfig(line: "8.5", state: await engine.stateStore.current())
        let pool = try String(contentsOf: paths.phpConfigFolder(line: "8.4").appending(path: "php-fpm.conf"), encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: stub("8.4").path(percentEncoded: false)))
        #expect(pool.contains(stub("8.4").path(percentEncoded: false)))
        #expect(try String(contentsOf: stub("8.4"), encoding: .utf8).contains("'dumps' => false"))
        #expect(!FileManager.default.fileExists(atPath: commands.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stub("8.5").path(percentEncoded: false)))

        try await engine.stateStore.update { $0.shares[0].state = .ended(.stopped) }
        _ = try await engine.writePHPConfig(line: "8.4", state: await engine.stateStore.current())

        #expect(!FileManager.default.fileExists(atPath: stub("8.4").path(percentEncoded: false)))
    }
}

// Real nginx and PHP, only when NEXUS_REAL_RUNTIMES names the runtimes folder. The fake cloudflared
// and the fake checks of 4b. Each request goes to the port of the share block on 127.0.0.1.
extension ShareHostsEngineTests {
    private static let page = #"""
        <?php

        $uri = strtok($_SERVER['REQUEST_URI'], '?');
        $local = 'https://'.$_SERVER['HTTP_HOST'];

        if ($uri === '/go') {
            header("Location: {$local}/login", true, 302);
            exit;
        }

        if ($uri === '/page') {
            setcookie('nexus', '1', ['domain' => '.'.$_SERVER['SERVER_NAME'], 'path' => '/']);
            header("Link: <{$local}/style.css>; rel=preload; as=style");
            $json = str_replace('/', '\/', $local);
            $query = rawurlencode($local);
            $relative = substr($local, 6);
            echo "<a href=\"{$local}/x\">plain</a>\n<script>var u = \"{$json}\/x\";</script>\n<a href=\"/r?to={$query}%2Fx\">query</a>\n<img src=\"{$relative}/y.png\">\n";
            exit;
        }

        header('Content-Type: application/json');
        echo json_encode(array_map('base64_encode', [
            'host' => $_SERVER['HTTP_HOST'] ?? '',
            'port' => $_SERVER['SERVER_PORT'] ?? '',
            'name' => $_SERVER['SERVER_NAME'] ?? '',
            'appUrl' => (string) getenv('APP_URL'),
            'sessionDomain' => (string) getenv('SESSION_DOMAIN'),
            'shareHost' => (string) getenv('NEXUS_SHARE_HOST'),
            'body' => (string) file_get_contents('php://input'),
            'origin' => $_SERVER['HTTP_ORIGIN'] ?? '',
            'referer' => $_SERVER['HTTP_REFERER'] ?? '',
        ]));

        """#

    private func send(_ port: Int, _ path: String, headers: [String] = [], body: String? = nil) async -> (head: String, body: String) {
        let curl = Process()
        curl.executableURL = URL(filePath: "/usr/bin/curl")
        curl.arguments = ["-s", "-i", "--max-time", "5", "-H", "Host: \(Self.publicHost)"]
            + headers.flatMap { ["-H", $0] }
            + (body.map { ["--data-binary", $0] } ?? [])
            + ["http://127.0.0.1:\(port)\(path)"]
        let output = Pipe()
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        try? curl.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n")
        return (parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func values(_ body: String) -> [String: String] {
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: String] ?? [:]
        return json.compactMapValues { Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) } }
    }

    private func rawBody(_ body: String) -> Data? {
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: String]
        return json?["body"].flatMap { Data(base64Encoded: $0) }
    }

    private func installFakeCloudflared(in paths: NexusPaths) throws {
        let folder = paths.runtime("cloudflared", line: "1")
        let binary = folder.appending(path: "bin/cloudflared")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec /bin/sleep 600\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(InstalledRuntime(name: "cloudflared", line: "1", version: "2026.11.0", revision: 1, sha256: "fake-cloudflared", installedAt: .now, folder: folder)).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
    }

    private func realEngine(root: URL, paths: NexusPaths, answers: FakeLinkAnswers) async -> NexusEngine {
        let package = ManifestPackage(name: "cloudflared", version: "2026.11.0", line: "1", revision: 1, url: URL(filePath: "/nonexistent/cloudflared.tar.xz"), sha256: "fake-cloudflared", format: .tarXZ)
        let engine = NexusEngine(
            paths: paths,
            helper: base.helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: base.keyStore),
            processSupervisor: ProcessSupervisor(),
            manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [package])),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero
        )
        let waits = ShareWaits(poll: .milliseconds(20), blockLimit: .seconds(5), hostLimit: .seconds(2), readyLimit: .seconds(2), addressInterval: .milliseconds(20), addressLimit: .seconds(1), noAnswerLimit: .milliseconds(200), openWithoutAnswer: .milliseconds(600), connectionInterval: .seconds(600))

        await engine.useShareFakes(answers.checks, waits: waits, wakeLimit: 600, connectionLimit: 600)
        return engine
    }

    private func openLink(_ engine: NexusEngine, host: String) async throws -> ShareRecord {
        guard case .share = await engine.handle(.startShare(ShareStart(host: host))) else {
            throw RuntimeError.unsupported("The link to \(host) did not open.")
        }

        return try #require(await engine.stateStore.current().shares.first { $0.host == host })
    }

    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealLinkGivesEachKindOfSiteItsHostAndChangesTheAnswersAndTheBodies() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        try paths.createFolders()
        try base.linkRealRuntimes(in: paths)
        try installFakeCloudflared(in: paths)

        let httpsPort = base.freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = base.freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let app = try folder("projects/g4app", in: root, files: ["artisan": "", "bootstrap/app.php": "<?php\n", "public/index.php": Self.page])
        let plain = try folder("projects/g4plain", in: root, files: ["index.php": Self.page, ".env": "CMS_URL=https://g4cms.test:\(httpsPort)/x\n"])
        let cms = try folder("projects/g4cms", in: root, files: ["index.php": Self.page])
        let local = "https://g4plain.test:\(httpsPort)"
        let cmsPath = "/_nexus/host/g4cms.test"
        let engine = await realEngine(root: root, paths: paths, answers: FakeLinkAnswers())

        try await base.whileRunning(engine) {
            await engine.startEnabledServices()
            _ = await engine.handle(.addSite(folder: app.path(percentEncoded: false), host: "g4app.test", aliases: [], php: "8.5", server: nil))
            _ = await engine.handle(.addSite(folder: plain.path(percentEncoded: false), host: "g4plain.test", aliases: [], php: "8.5", server: nil))
            _ = await engine.handle(.addSite(folder: cms.path(percentEncoded: false), host: "g4cms.test", aliases: [], php: "8.5", server: nil))
            let ready = await eventually { await !base.curl(["https://g4cms.test:\(httpsPort)/info"], host: "g4cms.test", port: httpsPort).isEmpty }

            #expect(ready)

            let appLink = try await openLink(engine, host: "g4app.test")
            let answers = await eventually { await !values(send(appLink.port, "/info").body).isEmpty }
            let publicValues = values(await send(appLink.port, "/info").body)
            let localValues = values(await base.curl(["https://g4app.test:\(httpsPort)/info"], host: "g4app.test", port: httpsPort))

            #expect(appLink.mode == .publicHost)
            #expect(answers)
            #expect(publicValues["host"] == Self.publicHost)
            #expect(publicValues["name"] == Self.publicHost)
            #expect(publicValues["port"] == "443")
            #expect(publicValues["appUrl"] == "https://\(Self.publicHost)")
            #expect(publicValues["sessionDomain"] == "null")
            #expect(publicValues["shareHost"] == Self.publicHost)
            #expect(localValues["host"] == "g4app.test:\(httpsPort)")
            #expect(localValues["port"] == "\(httpsPort)")
            #expect(localValues["appUrl"] == "")
            #expect(localValues["shareHost"] == "")

            let plainLink = try await openLink(engine, host: "g4plain.test")
            _ = await eventually { await !values(send(plainLink.port, "/info").body).isEmpty }
            let page = await send(plainLink.port, "/page")
            let redirect = await send(plainLink.port, "/go")
            let withCookie = values(await send(plainLink.port, "/info", headers: ["Cookie: a=1", "Content-Type: application/json"], body: #"{"a":"https://\#(Self.publicHost)/a","b":"https:\\/\\/\#(Self.publicHost)\\/b","c":"https://\#(Self.publicHost).example.com"}"#).body)
            let withoutCookie = values(await send(plainLink.port, "/info", headers: ["Content-Type: application/json"], body: #"{"a":"https://\#(Self.publicHost)/a"}"#).body)
            let latin = root.appending(path: "latin.txt")
            let latinBody = Data("a=https://\(Self.publicHost)/a&n=caf".utf8) + Data([0xE9])
            try latinBody.write(to: latin)
            let notUTF8 = await send(plainLink.port, "/info", headers: ["Cookie: a=1", "Content-Type: application/x-www-form-urlencoded"], body: "@\(latin.path(percentEncoded: false))")
            let replacement = root.appending(path: "replacement.txt")
            try Data("a=https://\(Self.publicHost)/a&n=caf\u{FFFD}".utf8).write(to: replacement)
            let withReplacement = await send(plainLink.port, "/info", headers: ["Cookie: a=1", "Content-Type: application/x-www-form-urlencoded"], body: "@\(replacement.path(percentEncoded: false))")
            let emptyBody = values(await send(plainLink.port, "/info", headers: ["Cookie: a=1", "Content-Type: application/x-www-form-urlencoded"], body: "").body)
            let fromBrowser = values(await send(plainLink.port, "/info", headers: ["Origin: https://\(Self.publicHost)", "Referer: https://\(Self.publicHost)/page"]).body)
            let fromOtherSite = values(await send(plainLink.port, "/info", headers: ["Origin: https://example.com", "Referer: https://example.com/page"]).body)

            #expect(plainLink.mode == .localHost)
            #expect(page.body.contains("https://\(Self.publicHost)/x"))
            #expect(page.body.contains(#"https:\/\/\#(Self.publicHost)\/x"#))
            #expect(page.body.contains("https%3A%2F%2F\(Self.publicHost)%2Fx"))
            #expect(page.body.contains("\"//\(Self.publicHost)/y.png\""))
            #expect(!page.body.contains("g4plain.test"))
            #expect(page.head.contains("Link: <https://\(Self.publicHost)/style.css>; rel=preload; as=style"))
            #expect(page.head.lowercased().contains("set-cookie: nexus=1; path=/; domain=.\(Self.publicHost)"))
            #expect(redirect.head.contains("Location: https://\(Self.publicHost)/login"))
            #expect(withCookie["body"] == #"{"a":"\#(local)/a","b":"https:\\/\\/g4plain.test:\#(httpsPort)\\/b","c":"https://\#(Self.publicHost).example.com"}"#)
            #expect(withoutCookie["body"] == #"{"a":"https://\#(Self.publicHost)/a"}"#)
            #expect(rawBody(notUTF8.body) == latinBody)
            #expect(rawBody(withReplacement.body) == Data("a=\(local)/a&n=caf\u{FFFD}".utf8))
            #expect(emptyBody["body"] == "")
            #expect(fromBrowser["origin"] == local)
            #expect(fromBrowser["referer"] == "\(local)/page")
            #expect(fromBrowser["host"] == "g4plain.test:\(httpsPort)")
            #expect(fromBrowser["shareHost"] == Self.publicHost)
            #expect(fromOtherSite["origin"] == "https://example.com")
            #expect(fromOtherSite["referer"] == "https://example.com/page")

            let cmsValues = values(await send(plainLink.port, "\(cmsPath)/info", headers: ["Cookie: a=1", "Content-Type: application/x-www-form-urlencoded", "Referer: https://\(Self.publicHost)\(cmsPath)/page"], body: "to=https%3A%2F%2F\(Self.publicHost)%2F_nexus%2Fhost%2Fg4cms.test%2Fa&home=https%3A%2F%2F\(Self.publicHost)%2F").body)
            let cmsRedirect = await send(plainLink.port, "\(cmsPath)/go")
            let cmsPage = await send(plainLink.port, "\(cmsPath)/page")

            #expect(cmsValues["host"] == "g4cms.test:\(httpsPort)")
            #expect(cmsValues["shareHost"] == "")
            #expect(cmsValues["body"] == "to=https%3A%2F%2Fg4cms.test%3A\(httpsPort)%2Fa&home=https%3A%2F%2Fg4plain.test%3A\(httpsPort)%2F")
            #expect(cmsValues["referer"] == "https://g4cms.test:\(httpsPort)/page")
            #expect(cmsRedirect.head.contains("Location: https://\(Self.publicHost)\(cmsPath)/login"))
            #expect(cmsPage.body.contains("https://\(Self.publicHost)\(cmsPath)/x"))
            #expect(!cmsPage.body.contains("g4cms.test:"))

            _ = await engine.handle(.stopAllShares(appQuit: false))

            #expect(!FileManager.default.fileExists(atPath: paths.shareScript(plainLink.id).path(percentEncoded: false)))
            #expect(!(try String(contentsOf: paths.nginxConfig, encoding: .utf8)).contains("js_import"))

            _ = await engine.handle(.stopAll)
        }
    }
}
