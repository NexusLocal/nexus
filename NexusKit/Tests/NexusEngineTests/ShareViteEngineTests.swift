import Darwin
import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

extension NexusEngine {
    func useShareBuild(_ command: @escaping @Sendable (String) -> String, limit: Duration = .seconds(30)) {
        shareBuildCommand = command
        shareBuildTimeLimit = limit
    }
}

@Suite(.serialized)
struct ShareViteEngineTests {
    private let base = NexusEngineTests()
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"
    private static let cloudflaredBuild = (version: "2026.11.0", revision: 1, sha256: "fake-cloudflared")
    private static let devServer = "echo 'http://[::1]:{port:vite}' > public/hot; trap 'rm -f public/hot; exit 0' TERM; while true; do sleep 1; done"

    private static let waits = ShareWaits(
        poll: .milliseconds(20),
        blockLimit: .seconds(1),
        hostLimit: .seconds(10),
        readyLimit: .seconds(2),
        addressInterval: .milliseconds(20),
        addressLimit: .seconds(1),
        noAnswerLimit: .milliseconds(200),
        openWithoutAnswer: .milliseconds(600),
        firstWakeCheck: .milliseconds(50),
        wakeInterval: .milliseconds(50),
        wakeEnd: .milliseconds(500),
        connectionInterval: .seconds(60)
    )

    private struct Fixture {
        let root: URL
        let shop: URL
        let paths: NexusPaths
        let engine: NexusEngine
        let answers: FakeLinkAnswers
        let builds: URL
        let buildEnvironment: URL
        let activity: URL

        var owner: String {
            NexusEngine.processOwner(key: RealPath.of(shop), workspace: nil)
        }

        var devServerLog: URL {
            paths.log("main-shop.test")
        }

        var buildCommand: String {
            "/bin/sh '\(root.path(percentEncoded: false))build.sh'"
        }

        func file(_ name: String) -> URL {
            root.appending(path: name)
        }
    }

    private static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private static func writeProgram(_ script: String, to file: URL) throws {
        try write(script, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
    }

    private static func install(_ name: String, line: String, version: String, revision: Int = 1, sha256: String = "", in paths: NexusPaths) throws {
        let folder = paths.runtime(name, line: line)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runtime = InstalledRuntime(name: name, line: line, version: version, revision: revision, sha256: sha256, installedAt: .now, folder: folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(runtime).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
    }

    private static func buildScript(root: URL) -> String {
        let folder = root.path(percentEncoded: false)

        return """
            #!/bin/sh
            echo "$PWD" >> '\(folder)builds.txt'
            env > '\(folder)build-environment.txt'
            echo $$ > '\(folder)build.pid'
            while [ -f '\(folder)hold' ]; do sleep 0.05; done
            if [ -f '\(folder)fail' ]; then echo 'The build found an error.'; exit 1; fi
            if [ -f '\(folder)slow' ]; then sleep 30; fi
            mkdir -p public/build && echo '{}' > public/build/manifest.json

            """
    }

    private static func laravelProject(at shop: URL, vite: String?, buildScript: Bool = true) throws {
        try write("<?php", to: shop.appending(path: "artisan"))
        try write("<?php", to: shop.appending(path: "bootstrap/app.php"))
        try write("export default {};\n", to: shop.appending(path: "vite.config.js"))
        try write(buildScript ? #"{"scripts": {"dev": "vite", "build": "vite build"}}"# : #"{"scripts": {"dev": "vite"}}"#, to: shop.appending(path: "package.json"))
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)

        if let vite {
            try write(#"{"name": "vite", "version": "\#(vite)"}"#, to: shop.appending(path: "node_modules/vite/package.json"))
        }
    }

    private func fixture(repository: Bool = false, site: (URL) -> Site = { Site(host: "shop.test", folder: $0, aliases: ["www.shop.test"], php: "8.4", backgroundCommands: [devServer]) }, project: (URL) throws -> Void = { try laravelProject(at: $0, vite: "8.3.8") }) async throws -> Fixture {
        let root = shortTemporaryRoot()
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        try paths.createFolders()
        let httpPort = base.freePort()
        let shop = repository ? try await base.repository(in: root) : root.appending(path: "shop", directoryHint: .isDirectory)
        var state = EngineState()

        try project(shop)
        state.ports[ServiceCatalog.httpPortKey] = httpPort
        state.ports[ServiceCatalog.httpsPortKey] = base.freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        state.sites = [site(shop)]
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        try Self.install("php", line: "8.4", version: "8.4.0", in: paths)
        try Self.install("nginx", line: "1.30", version: "1.30.0", in: paths)
        try Self.writeProgram("#!/bin/sh\n[ \"$1\" = \"-t\" ] && exit 0\ntrap '' HUP\nexec \(fakeListener(port: String(httpPort)))\n", to: paths.runtime("nginx", line: "1.30").appending(path: "sbin/nginx"))
        try Self.writeProgram("", to: paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so"))
        try Self.install("cloudflared", line: "1", version: Self.cloudflaredBuild.version, revision: Self.cloudflaredBuild.revision, sha256: Self.cloudflaredBuild.sha256, in: paths)
        try Self.writeProgram("#!/bin/sh\nexec /bin/sleep 600\n", to: paths.runtime("cloudflared", line: "1").appending(path: "bin/cloudflared"))
        try Self.writeProgram(Self.buildScript(root: root), to: root.appending(path: "build.sh"))

        let package = ManifestPackage(name: "cloudflared", version: Self.cloudflaredBuild.version, line: "1", revision: Self.cloudflaredBuild.revision, url: URL(filePath: "/nonexistent/cloudflared.tar.xz"), sha256: Self.cloudflaredBuild.sha256, format: .tarXZ)
        let answers = FakeLinkAnswers()
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
            workspaceFolderQuiet: .zero,
            activity: ActivityLog(file: root.appending(path: "activity.log"), source: "nexusd")
        )
        let script = root.appending(path: "build.sh").path(percentEncoded: false)

        await engine.useShareFakes(answers.checks, waits: Self.waits, wakeLimit: 0.2, connectionLimit: 0.2)
        await engine.useRedirectProbe(FakeRedirectProbe().probe)
        await engine.useShareBuild { _ in "/bin/sh '\(script)'" }

        guard case .done = await engine.handle(.start(service: ServiceCatalog.nginxID)) else {
            await engine.shutdown()
            throw RuntimeError.unsupported("The fake nginx did not start.")
        }

        return Fixture(root: root, shop: shop, paths: paths, engine: engine, answers: answers, builds: root.appending(path: "builds.txt"), buildEnvironment: root.appending(path: "build-environment.txt"), activity: root.appending(path: "activity.log"))
    }

    private func run(_ fixture: Fixture, _ steps: () async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await base.whileRunning(fixture.engine, steps)
    }

    private func record(_ fixture: Fixture) async -> ShareRecord? {
        await fixture.engine.stateStore.current().shares.first { $0.host == "shop.test" }
    }

    private func start(_ fixture: Fixture, _ mode: ShareViteMode?) async -> NexusResponse {
        await fixture.engine.handle(.startShare(ShareStart(host: "shop.test", viteMode: mode)))
    }

    private func preview(_ fixture: Fixture) async throws -> SharePreview {
        guard case .sharePreview(let preview) = await fixture.engine.handle(.sharePreview(host: "shop.test")) else {
            throw RuntimeError.unsupported("The preview failed.")
        }

        return preview
    }

    private func devServers(_ fixture: Fixture) async -> [String] {
        await base.runningProcesses(fixture.engine).filter { !$0.hasPrefix("cloudflared") }
    }

    private func openPage(_ fixture: Fixture) async {
        await fixture.engine.pageRequested(by: fixture.owner)
        await fixture.engine.syncBackgroundProcesses().value
    }

    private func text(_ file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func buildCount(_ fixture: Fixture) -> Int {
        text(fixture.builds).split(separator: "\n").count
    }

    private func config(_ fixture: Fixture) -> String {
        text(fixture.paths.nginxConfig)
    }

    private func within(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))

        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    // MARK: The check

    @Test func aLaravelSiteWithViteAndNodeModulesGetsTheOptionAndWithoutNodeModulesNot() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let withVite = try await preview(fixture)
            try FileManager.default.removeItem(at: fixture.shop.appending(path: "node_modules"))
            let withoutNodeModules = try await preview(fixture)

            #expect(withVite.usesVite)
            #expect(withVite.liveBlocked == nil)
            #expect(withVite.refusal == nil)
            #expect(withVite.warnings.isEmpty)
            #expect(!withoutNodeModules.usesVite)
            #expect(withoutNodeModules.liveBlocked == nil)
        }
    }

    @Test func anOldViteTurnsLiveIntoBuildWithTheTextOfTheVersion() async throws {
        let fixture = try await fixture(project: { try Self.laravelProject(at: $0, vite: "5.4.21") })
        let text = ViteLiveCheck.liveBlockedText(version: "5.4.21", install: "npm install")

        try await run(fixture) {
            let sheet = try await preview(fixture)
            let response = await start(fixture, .live)
            let active = try #require(await record(fixture))

            guard case .share(let info) = response else {
                Issue.record("no link: \(response)")
                return
            }

            #expect(sheet.liveBlocked == text)
            #expect(sheet.defaults.viteMode == .build)
            #expect(sheet.refusal == nil)
            #expect(info.liveBlocked == text)
            #expect(info.buildsAssets)
            #expect(info.usesVite)
            #expect(active.options.viteMode == .build)
            #expect(active.usesVite)
            #expect(active.liveBlocked == text)
            #expect(buildCount(fixture) == 1)
        }
    }

    @Test func aNodeAppWithAnOldViteIsRefusedWithoutARecord() async throws {
        let fixture = try await fixture(site: { Site(host: "shop.test", folder: $0, php: "8.4", runsAs: .node) }, project: { app in
            try Self.write(#"{"scripts": {"dev": "vite"}, "devDependencies": {"vite": "^7.3.1"}}"#, to: app.appending(path: "package.json"))
            try Self.write(#"{"version": "7.3.1"}"#, to: app.appending(path: "node_modules/vite/package.json"))
        })
        let refusal = "Nexus cannot share this app. Its dev server is Vite 7.3.1, which lets visitors read files on your Mac. Update Vite in this project to 7.3.8 or later. Then share the app again."

        try await run(fixture) {
            let sheet = try await preview(fixture)
            let response = await start(fixture, nil)

            #expect(sheet.refusal == refusal)
            #expect(!sheet.usesVite)
            #expect(response == .failure(message: refusal))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    @Test func aLaravelMixSiteHasNoOptionAndBuildRunsNoBuild() async throws {
        let fixture = try await fixture(project: { shop in
            try Self.write("<?php", to: shop.appending(path: "artisan"))
            try Self.write("<?php", to: shop.appending(path: "bootstrap/app.php"))
            try Self.write("mix.js('resources/js/app.js', 'public/js');\n", to: shop.appending(path: "webpack.mix.js"))
            try Self.write(#"{"scripts": {"hot": "mix watch --hot", "build": "mix --production"}}"#, to: shop.appending(path: "package.json"))
        })

        try await run(fixture) {
            let sheet = try await preview(fixture)
            let response = await start(fixture, .build)

            guard case .share(let info) = response else {
                Issue.record("no link: \(response)")
                return
            }

            #expect(!sheet.usesVite)
            #expect(sheet.warnings.isEmpty)
            #expect(!info.usesVite)
            #expect(info.state == .open)
            #expect(buildCount(fixture) == 0)
        }
    }

    @Test func aLaravelMixSiteWithNpmRunHotGetsTheWarningOfMix() async throws {
        let fixture = try await fixture(project: { shop in
            try Self.write("<?php", to: shop.appending(path: "artisan"))
            try Self.write("<?php", to: shop.appending(path: "bootstrap/app.php"))
            try Self.write("mix.js('resources/js/app.js', 'public/js');\n", to: shop.appending(path: "webpack.mix.js"))
            try Self.write("http://localhost:8080", to: shop.appending(path: "public/hot"))
        })

        try await run(fixture) {
            let withHot = try await preview(fixture)
            try FileManager.default.removeItem(at: fixture.shop.appending(path: "public/hot"))
            let withoutHot = try await preview(fixture)

            #expect(withHot.warnings == [.mixHot])
            #expect(!withHot.usesVite)
            #expect(withoutHot.warnings.isEmpty)
        }
    }

    @Test func viteInATerminalWarnsRefusesBuildAndServesLive() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            await fixture.engine.useHotFilePortAnswers { $0 == 51_731 }
            try Self.write("http://[::1]:51731\n", to: fixture.shop.appending(path: "public/hot"))

            let sheet = try await preview(fixture)
            let build = await start(fixture, .build)
            let afterBuild = await fixture.engine.stateStore.current().shares
            let live = await start(fixture, .live)

            #expect(sheet.warnings == [.viteInTerminal])
            #expect(sheet.refusal == nil)
            #expect(build == .failure(message: ShareText.Vite.inTerminal))
            #expect(afterBuild.isEmpty)
            #expect(live.isShare)
            #expect(config(fixture).contains("server [::1]:51731;"))
            #expect(buildCount(fixture) == 0)
        }
    }

    @Test func aHotFileWithoutADevServerRefusesBuildWithTheApprovedText() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            await fixture.engine.useHotFilePortAnswers { _ in false }
            try Self.write("http://[::1]:51731\n", to: fixture.shop.appending(path: "public/hot"))

            let build = await start(fixture, .build)

            #expect(build == .failure(message: "Nexus cannot build the styles and scripts of this site. The file public/hot names no dev server that answers. Remove public/hot. Then share the site again."))
            #expect(buildCount(fixture) == 0)
        }
    }

    @Test func anOldViteInATerminalRefusesTheShare() async throws {
        let fixture = try await fixture(project: { try Self.laravelProject(at: $0, vite: "8.3.6") })

        try await run(fixture) {
            await fixture.engine.useHotFilePortAnswers { $0 == 51_731 }
            try Self.write("http://[::1]:51731\n", to: fixture.shop.appending(path: "public/hot"))

            let sheet = try await preview(fixture)
            let response = await start(fixture, .live)

            #expect(sheet.refusal == ShareText.Vite.inTerminalWithoutLive)
            #expect(response == .failure(message: ShareText.Vite.inTerminalWithoutLive))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    @Test func aMissingBuildScriptRefusesBuild() async throws {
        let fixture = try await fixture(project: { try Self.laravelProject(at: $0, vite: "8.3.8", buildScript: false) })

        try await run(fixture) {
            let response = await start(fixture, .build)

            #expect(response == .failure(message: ShareText.Vite.noBuildScript))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    @Test func anOutputFolderThatGitSeesRefusesBuild() async throws {
        let fixture = try await fixture(repository: true)

        try await run(fixture) {
            let response = await start(fixture, .build)

            #expect(response == .failure(message: ShareText.Vite.notIgnored("public/build/")))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    // MARK: Build

    @Test func buildStopsTheDevServerAndBuildsAfterThePublicHostWithTheEnvironmentOfTheDevServer() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            await openPage(fixture)
            let devServerRan = await eventually { exists(fixture.shop.appending(path: "public/hot")) }
            fixture.answers.set { $0.host = nil }
            try Self.write("", to: fixture.file("hold"))

            let starting = Task { await start(fixture, .build) }
            let stoppedFirst = await eventually {
                let running = await devServers(fixture)
                let port = await record(fixture)?.port ?? 0
                return running.isEmpty && !exists(fixture.shop.appending(path: "public/hot")) && port != 0
            }
            let stateBeforeTheHost = await record(fixture)?.state
            let buildsBeforeTheHost = buildCount(fixture)

            fixture.answers.set { $0.host = Self.publicHost }
            let built = await eventually { buildCount(fixture) == 1 }
            let stateDuringTheBuild = await record(fixture)?.state
            try FileManager.default.removeItem(at: fixture.file("hold"))
            let response = await starting.value
            await fixture.engine.activity?.waitForWrites()
            let environment = text(fixture.buildEnvironment)
            let log = text(fixture.devServerLog)

            #expect(devServerRan)
            #expect(stoppedFirst)
            #expect(stateBeforeTheHost == .starting(.buildAssets))
            #expect(buildsBeforeTheHost == 0)
            #expect(built)
            #expect(stateDuringTheBuild == .starting(.buildAssets))
            #expect(response.isShare)
            #expect(text(fixture.builds) == "\(RealPath.of(fixture.shop))\n")
            #expect(environment.contains("\(BackgroundProcessMarker.name)="))
            #expect(environment.contains("NEXUS_SITE_NODE="))
            #expect(environment.contains("COREPACK_ENABLE_DOWNLOAD_PROMPT=0"))
            #expect(log.contains("Nexus stops this program, because a public link of shop.test uses Build.\n"))
            #expect(log.contains("$ \(fixture.buildCommand)\n"))
            #expect(text(fixture.activity).contains("Nexus builds the assets of shop.test for its link."))
        }
    }

    @Test func aFailedBuildEndsTheLinkAndALongBuildEndsAtTheTimeLimit() async throws {
        let fixture = try await fixture()
        let log = fixture.devServerLog.path(percentEncoded: false)

        try await run(fixture) {
            try Self.write("", to: fixture.file("fail"))
            let failed = await start(fixture, .build)
            let failedState = await record(fixture)?.state

            try FileManager.default.removeItem(at: fixture.file("fail"))
            try Self.write("", to: fixture.file("slow"))
            await fixture.engine.useShareBuild({ [command = fixture.buildCommand] _ in command }, limit: .milliseconds(300))
            let slow = await start(fixture, .build)

            #expect(failed == .failure(message: ShareText.Vite.buildFailed(fixture.buildCommand, log: log)))
            #expect(failedState == .ended(.failed(ShareText.Vite.buildFailed(fixture.buildCommand, log: log))))
            #expect(slow == .failure(message: ShareText.Vite.buildTooLong(fixture.buildCommand, log: log)))
            #expect(text(fixture.devServerLog).contains("The build found an error."))
        }
    }

    @Test func duringABuildLinkNoPageStartsTheDevServerAndAfterTheEndTheNextPageDoes() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let response = await start(fixture, .build)
            await openPage(fixture)
            let duringTheLink = await devServers(fixture)
            let info = await fixture.engine.devServerInfo(owner: fixture.owner)

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let infoAfterTheEnd = await fixture.engine.devServerInfo(owner: fixture.owner)
            await fixture.engine.syncBackgroundProcesses().value
            let afterTheEnd = await devServers(fixture)
            await openPage(fixture)
            let afterAPage = await devServers(fixture)

            #expect(response.isShare)
            #expect(duringTheLink.isEmpty)
            #expect(info?.state == .pausedForLink)
            #expect(infoAfterTheEnd?.state == .waitsForPage)
            #expect(afterTheEnd.isEmpty)
            #expect(afterAPage.count == 1)
        }
    }

    @Test func theEndOfABuildLinkRemovesOnlyAnOutputFolderThatItsBuildMade() async throws {
        let fixture = try await fixture()
        let manifest = fixture.shop.appending(path: "public/build/manifest.json")

        try await run(fixture) {
            _ = await start(fixture, .build)
            let builtByTheLink = exists(manifest)
            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let goneAfterTheEnd = !exists(manifest)

            _ = await start(fixture, .build)
            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let goneAgain = !exists(manifest)

            try Self.write("{}", to: manifest)
            _ = await start(fixture, .build)
            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))

            #expect(builtByTheLink)
            #expect(goneAfterTheEnd)
            #expect(goneAgain)
            #expect(exists(manifest))
            #expect(text(fixture.devServerLog).contains("Nexus removed public/build/, because the build of a public link made it.\n"))
        }
    }

    @Test func aStopDuringTheBuildEndsTheBuild() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            try Self.write("", to: fixture.file("hold"))
            let starting = Task { await start(fixture, .build) }
            let building = await eventually { exists(fixture.file("build.pid")) }
            let pid = try #require(Int32(text(fixture.file("build.pid")).trimmingCharacters(in: .whitespacesAndNewlines)))

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let response = await starting.value
            let ended = await eventually { kill(pid, 0) != 0 }

            #expect(building)
            #expect(response == .failure(message: ShareText.notOpenedLine("shop.test", reason: .stopped)))
            #expect(ended)
            #expect(await record(fixture)?.state == .ended(.stopped))
        }
    }

    @Test func buildAgainBuildsAgainAndRefusesALiveLinkAndNoLink() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let noLink = await fixture.engine.handle(.rebuildShare(host: "shop.test"))
            _ = await start(fixture, .build)
            let again = await fixture.engine.handle(.rebuildShare(host: "www.shop.test"))
            let builds = buildCount(fixture)
            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            _ = await start(fixture, .live)
            let live = await fixture.engine.handle(.rebuildShare(host: "shop.test"))

            #expect(noLink == .failure(message: "shop.test has no open link."))
            #expect(again == .done(message: "Nexus built the styles and scripts of shop.test again."))
            #expect(builds == 2)
            #expect(live == .failure(message: "The link to shop.test does not use Build. Build Again works only with Build."))
            #expect(buildCount(fixture) == 2)
        }
    }

    // MARK: Live

    @Test func liveFollowsTheHotFileOfTheDevServer() async throws {
        let fixture = try await fixture()
        let hot = fixture.shop.appending(path: "public/hot")

        try await run(fixture) {
            await fixture.engine.useHotFilePortAnswers { _ in false }
            try Self.write("http://[::1]:51731\n", to: hot)

            let response = await start(fixture, .live)
            let first = config(fixture)
            try Self.write("http://[::1]:51732\n", to: hot)
            let moved = await within(seconds: 5) { config(fixture).contains("server [::1]:51732;") }
            try FileManager.default.removeItem(at: hot)
            let removed = await within(seconds: 5) { !config(fixture).contains("nexus_share_vite_") }

            #expect(response.isShare)
            #expect(first.contains("server [::1]:51731;"))
            #expect(first.contains(#"sub_filter "http://[::1]:51731" "https://$host";"#))
            #expect(first.contains("location @nexus_vite {"))
            #expect(moved)
            #expect(removed)
            #expect(buildCount(fixture) == 0)
        }
    }

    @Test func aBuildLinkOfTheStateHoldsBackTheDevServerAfterANewStart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try Self.laravelProject(at: shop, vite: "8.3.8")
        var options = ShareOptions.standard
        options.viteMode = .build
        options.address = .ownDomain
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: [Self.devServer])]
        state.shares = [ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: options, mode: .publicHost, port: 18_600, started: .now, state: .open, usesVite: true)]
        let engine = try base.makeSiteEngine(root: root, state: state)
        let owner = NexusEngine.processOwner(key: RealPath.of(shop), workspace: nil)

        try await base.whileRunning(engine) {
            await engine.endSharesOfEarlierRun()
            await engine.pageRequested(by: owner)
            await engine.syncBackgroundProcesses().value

            #expect(await engine.buildShareOwners == [owner])
            #expect(await engine.devServerInfo(owner: owner)?.state == .pausedForLink)
            #expect(await base.runningProcesses(engine).isEmpty)
        }
    }
}

extension NexusResponse {
    fileprivate var isShare: Bool {
        if case .share = self {
            return true
        }

        return false
    }
}
