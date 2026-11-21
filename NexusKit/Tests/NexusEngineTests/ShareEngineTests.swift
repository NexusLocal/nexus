import Darwin
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

// The answers of the metrics server and of 1.1.1.1 for the links of a test.
final class FakeLinkAnswers: Sendable {
    struct Answers {
        var host: String? = "calm-river-tree-lamp.trycloudflare.com"
        var ready: Bool? = true
        var resolves: Bool? = true
        var askedPorts: Set<Int> = []
        var firstReady: Date?
    }

    private let answers = Mutex(Answers())

    func set(_ change: (inout Answers) -> Void) {
        answers.withLock { change(&$0) }
    }

    var current: Answers {
        answers.withLock { $0 }
    }

    var checks: ShareChecks {
        ShareChecks(
            quickTunnelHost: { port in
                self.answers.withLock { answers in
                    answers.askedPorts.insert(port)
                    return answers.host
                }
            },
            isReady: { port in
                self.answers.withLock { answers in
                    answers.askedPorts.insert(port)

                    if answers.ready == true, answers.firstReady == nil {
                        answers.firstReady = .now
                    }

                    return answers.ready
                }
            },
            resolves: { _ in
                self.answers.withLock { $0.resolves }
            }
        )
    }
}

extension NexusEngine {
    func useShareFakes(_ checks: ShareChecks, waits: ShareWaits, wakeLimit: TimeInterval, connectionLimit: TimeInterval) {
        shareChecks = checks
        shareBlockAnswers = { _ in true }
        shareWaits = waits
        shareWakeLimit = wakeLimit
        shareConnectionLimit = connectionLimit
    }

    func useConnectionCheck(at date: Date) {
        lastConnectionCheck = date
    }

    func useShareCheckInterval(_ interval: Duration) {
        shareCheckInterval = interval
    }

    func shareNotReadySince(_ id: String) -> Date? {
        notReadySince[id]
    }

    func checksAfterWake() -> Set<String> {
        wakeChecks
    }

    // A stop that read the state before the start added its record.
    func stopBeforeTheRecord(host: String) {
        stoppedStarts[host] = .stopped
    }
}

@Suite(.serialized)
struct ShareEngineTests {
    private let base = NexusEngineTests()
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"
    private static let build = (version: "2026.11.0", revision: 1, sha256: "fake-cloudflared")

    private static let waits = ShareWaits(
        poll: .milliseconds(20),
        blockLimit: .seconds(1),
        hostLimit: .seconds(2),
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
        let paths: NexusPaths
        let engine: NexusEngine
        let answers: FakeLinkAnswers
        let processes: ProcessSupervisor
        let starts: URL
        let environment: URL
        let activity: URL
    }

    // The fake cloudflared writes its arguments and its environment at each start. With the file
    // fail429 it exits as cloudflared does after a 429 of api.trycloudflare.com.
    private static func fakeCloudflared(root: URL) -> String {
        let folder = root.path(percentEncoded: false)

        return """
            #!/bin/sh
            echo "$*" >> '\(folder)/starts.txt'
            echo "$HOME|$\(BackgroundProcessMarker.name)" >> '\(folder)/environment.txt'
            if [ -f '\(folder)/fail429' ]; then
                echo 'ERR failed to unmarshal quick Tunnel: 429 Too Many Requests'
                exit 1
            fi
            exec /bin/sleep 600

            """
    }

    // The fake nginx passes each check and listens on the HTTP port. It ignores the reload.
    private static func fakeNginx(httpPort: Int) -> String {
        """
        #!/bin/sh
        [ "$1" = "-t" ] && exit 0
        trap '' HUP
        exec \(fakeListener(port: String(httpPort)))

        """
    }

    private static func writeProgram(_ script: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file)
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

    // The manifest has the same build of cloudflared as the fake. So a check of the manifest
    // downloads nothing and never reads GitHub.
    private static func manifest() -> FixedManifest {
        let package = ManifestPackage(name: "cloudflared", version: build.version, line: "1", revision: build.revision, url: URL(filePath: "/nonexistent/cloudflared.tar.xz"), sha256: build.sha256, format: .tarXZ)
        return FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [package]))
    }

    private static func paths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
    }

    private func engine(root: URL, processes: ProcessSupervisor, answers: FakeLinkAnswers) async -> NexusEngine {
        let paths = Self.paths(root)
        let engine = NexusEngine(
            paths: paths,
            helper: base.helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: base.keyStore),
            processSupervisor: processes,
            manifestSource: Self.manifest(),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero,
            activity: ActivityLog(file: root.appending(path: "activity.log"), source: "nexusd")
        )

        await engine.useShareFakes(answers.checks, waits: Self.waits, wakeLimit: 0.2, connectionLimit: 0.2)
        await engine.useRedirectProbe(FakeRedirectProbe().probe)
        return engine
    }

    private func fixture(hosts: [String] = ["shop.test"], repository: Bool = false, startsNginx: Bool = true, change: (inout EngineState) -> Void = { _ in }) async throws -> Fixture {
        let root = shortTemporaryRoot()
        let paths = Self.paths(root)
        try paths.createFolders()
        let httpPort = base.freePort()
        var state = EngineState()

        state.ports[ServiceCatalog.httpPortKey] = httpPort
        state.ports[ServiceCatalog.httpsPortKey] = base.freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()

        for host in hosts {
            let folder = repository && host == hosts.first ? try await base.repository(in: root) : root.appending(path: host, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.sites.append(Site(host: host, folder: folder, aliases: ["www.\(host)"], php: "8.4"))
        }

        change(&state)
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        try Self.install("nginx", line: "1.30", version: "1.30.0", in: paths)
        try Self.writeProgram(Self.fakeNginx(httpPort: httpPort), to: paths.runtime("nginx", line: "1.30").appending(path: "sbin/nginx"))
        try Self.writeProgram("", to: paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so"))
        try Self.install("cloudflared", line: "1", version: Self.build.version, revision: Self.build.revision, sha256: Self.build.sha256, in: paths)
        try Self.writeProgram(Self.fakeCloudflared(root: root), to: paths.runtime("cloudflared", line: "1").appending(path: "bin/cloudflared"))

        let answers = FakeLinkAnswers()
        let processes = ProcessSupervisor()
        let engine = await engine(root: root, processes: processes, answers: answers)

        if startsNginx {
            let started = await engine.handle(.start(service: ServiceCatalog.nginxID))

            guard case .done = started else {
                await engine.shutdown()
                throw RuntimeError.unsupported("The fake nginx did not start: \(started)")
            }
        }

        return Fixture(root: root, paths: paths, engine: engine, answers: answers, processes: processes, starts: root.appending(path: "starts.txt"), environment: root.appending(path: "environment.txt"), activity: root.appending(path: "activity.log"))
    }

    private func run(_ fixture: Fixture, _ steps: () async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await base.whileRunning(fixture.engine, steps)
    }

    private func record(_ fixture: Fixture, host: String = "shop.test") async -> ShareRecord? {
        await fixture.engine.stateStore.current().shares.first { $0.host == host }
    }

    private func open(_ fixture: Fixture, _ start: ShareStart = ShareStart(host: "shop.test")) async -> ShareInfo? {
        guard case .share(let info) = await fixture.engine.handle(.startShare(start)) else {
            return nil
        }

        return info
    }

    private func program(_ fixture: Fixture, _ record: ShareRecord?) async -> ServiceState? {
        guard let record else {
            return nil
        }

        return await fixture.processes.state(of: "share\n\(record.id)")
    }

    private func lines(of file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func ended(_ fixture: Fixture, host: String = "shop.test") async -> ShareEndReason? {
        guard case .ended(let reason)? = await record(fixture, host: host)?.state else {
            return nil
        }

        return reason
    }

    // MARK: The start

    @Test func aStartOpensTheLinkOnPortsOfTheLinksThatOnlyAnActiveLinkHolds() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let info = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let metricsPort = try #require(active.metricsPort)
            let taken = await fixture.engine.takenPorts(await fixture.engine.stateStore.current())
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(info.url == "https://\(Self.publicHost)")
            #expect(info.state == .open)
            #expect(active.publicHost == Self.publicHost)
            #expect(active.port >= NexusEngine.firstSharePort)
            #expect(metricsPort >= NexusEngine.firstSharePort)
            #expect(taken.isSuperset(of: [active.port, metricsPort]))
            #expect(config.contains("listen 127.0.0.1:\(active.port) default_server;"))
            #expect(config.contains("\"\(active.id)\" \"\(active.id)\";"))

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let after = await fixture.engine.takenPorts(await fixture.engine.stateStore.current())
            let configAfter = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(after.isDisjoint(with: [active.port, metricsPort]))
            #expect(await record(fixture)?.port == 0)
            #expect(!configAfter.contains("listen 127.0.0.1:\(active.port) default_server;"))
        }
    }

    @Test func aLinkWithoutTheNjsModuleOfNginxEndsWithTheTextOfTheModule() async throws {
        let fixture = try await fixture()
        try FileManager.default.removeItem(at: fixture.paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so"))

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test")))

            #expect(answer == .failure(message: ShareText.njsMissing))
            #expect(await ended(fixture) == .failed(ShareText.njsMissing))
            #expect(lines(of: fixture.starts).isEmpty)
        }
    }

    @Test func theNjsModuleOfALinkAndItsPlanLiveAsLongAsTheLink() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let script = fixture.paths.shareScript(active.id)
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(try String(contentsOf: script, encoding: .utf8).contains("const LINK = "))
            #expect(config.contains("/runtimes/nginx/1.30/modules/ngx_http_js_module.so\";"))
            #expect(config.contains("js_import nexus_share_\(active.id) from \"\(script.path(percentEncoded: false))\";"))
            #expect(config.contains("location /_nexus/host/www.shop.test/ {"))
            #expect(await fixture.engine.hostPlan(of: active.id)?.extraHosts == ["www.shop.test"])

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let after = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(!FileManager.default.fileExists(atPath: script.path(percentEncoded: false)))
            #expect(await fixture.engine.hostPlan(of: active.id) == nil)
            #expect(!after.contains("ngx_http_js_module"))
            #expect(!after.contains("js_import"))
        }
    }

    @Test func cloudflaredRunsFromTheRuntimesFolderWithTheFilesOfNexusAndWithoutARestart() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let metricsPort = try #require(active.metricsPort)
            let binary = fixture.paths.runtime("cloudflared", line: "1").appending(path: "bin/cloudflared")
            let definition = await fixture.engine.cloudflaredDefinition(active, binary: binary, metricsPort: metricsPort)
            let home = fixture.paths.cloudflaredHome.path(percentEncoded: false)
            let marker = fixture.paths.root.path(percentEncoded: true)
            let wrote = await eventually { lines(of: fixture.environment).count == 1 }

            #expect(wrote)
            #expect(definition.id == "share\n\(active.id)")
            #expect(definition.executable == binary)
            #expect(definition.arguments == CloudflaredConfig.quickLinkArguments(config: fixture.paths.cloudflaredConfig, metricsPort: metricsPort, port: active.port))
            #expect(definition.environment == ["HOME": home, BackgroundProcessMarker.name: marker])
            #expect(definition.ports == [metricsPort])
            #expect(definition.logFile == fixture.paths.tunnelLog("shop.test"))
            #expect(definition.activityName == nil)
            #expect(!definition.restartsAfterExit)
            #expect(lines(of: fixture.starts) == [definition.arguments.joined(separator: " ")])
            #expect(lines(of: fixture.environment) == ["\(home)|\(marker)"])
            #expect(try String(contentsOf: fixture.paths.cloudflaredConfig, encoding: .utf8) == CloudflaredConfig.quickLinkFile)
            #expect(lines(of: fixture.paths.tunnelLog("shop.test")).first == "$ cloudflared \(definition.arguments.joined(separator: " "))")
            #expect(await program(fixture, active)?.pid != nil)
        }
    }

    @Test func theLinkOpensOnlyAfterTheAddressResolves() async throws {
        let fixture = try await fixture()
        fixture.answers.set { $0.resolves = false }

        try await run(fixture) {
            let resolved = Task {
                try await Task.sleep(for: .milliseconds(300))
                fixture.answers.set { $0.resolves = true }
                return Date.now
            }

            let info = try #require(await open(fixture))
            let opened = Date.now

            #expect(info.state == .open)
            #expect(opened >= (try await resolved.value))
        }
    }

    @Test func anAddressThatNeverResolvesEndsTheStartAndStopsTheProgram() async throws {
        let fixture = try await fixture()
        fixture.answers.set { $0.resolves = false }

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test")))
            let failed = await record(fixture)

            #expect(answer == .failure(message: ShareText.addressFails))
            #expect(failed?.state == .ended(.failed(ShareText.addressFails)))
            #expect(failed?.port == 0)
            #expect(await program(fixture, failed) == .stopped)
        }
    }

    @Test func withoutAnyAnswerOfDNSTheLinkOpensAFixedTimeAfterTheFirstReady() async throws {
        let fixture = try await fixture()
        fixture.answers.set { $0.resolves = nil }

        try await run(fixture) {
            let info = try #require(await open(fixture))
            let opened = Date.now
            let ready = try #require(fixture.answers.current.firstReady)

            #expect(info.state == .open)
            #expect(opened.timeIntervalSince(ready) >= Self.waits.openWithoutAnswer.timeInterval)
            #expect(opened.timeIntervalSince(ready) < Self.waits.openWithoutAnswer.timeInterval + 1)
        }
    }

    @Test func aSecondStartOfAnOpenLinkAlsoThroughAnAliasGivesTheSameLinkWithItsOptions() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let first = try #require(await open(fixture, ShareStart(host: "shop.test", duration: .oneHour)))
            let second = try #require(await open(fixture, ShareStart(host: "www.shop.test", duration: .untilStopped, password: true)))
            _ = await eventually { lines(of: fixture.environment).count == 1 }
            try await Task.sleep(for: .milliseconds(200))

            #expect(second == first)
            #expect(second.options.duration == .oneHour)
            #expect(!second.options.password)
            #expect(lines(of: fixture.starts).count == 1)
            #expect(await fixture.engine.stateStore.current().shares.count == 1)
        }
    }

    @Test func withoutNginxTheStartRefusesAndMakesNoRecord() async throws {
        let fixture = try await fixture(startsNginx: false)

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test")))

            #expect(answer == .failure(message: ShareText.nginxNotRunning))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    @Test func anOwnDomainWaitsForItsSetUp() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test", address: .ownDomain)))

            #expect(answer == .failure(message: ShareText.ownDomainMissing))
            #expect(await fixture.engine.stateStore.current().shares.isEmpty)
        }
    }

    @Test func anUnknownHostGetsTheTextOfTheSiteList() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "nothing.test")))

            #expect(answer == .failure(message: "Nexus has no site or workspace nothing.test. See: nexus site list"))
        }
    }

    @Test func aStopDuringTheStartGivesTheLineThatTheLinkDidNotOpen() async throws {
        let fixture = try await fixture()
        fixture.answers.set { $0.host = nil }

        try await run(fixture) {
            let starting = Task { await fixture.engine.handle(.startShare(ShareStart(host: "shop.test"))) }
            let running = await eventually { await program(fixture, await record(fixture))?.pid != nil }
            let stopped = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let answer = await starting.value

            #expect(running)
            #expect(stopped == .done(message: "The link to shop.test stopped."))
            #expect(answer == .failure(message: "The link to shop.test did not open: the user stopped it."))
            #expect(await ended(fixture) == .stopped)
            #expect(await program(fixture, await record(fixture)) == .stopped)
        }
    }

    @Test func aStopThatFoundNoRecordStillEndsTheStart() async throws {
        let fixture = try await fixture()
        fixture.answers.set { $0.host = nil }

        try await run(fixture) {
            let starting = Task { await fixture.engine.handle(.startShare(ShareStart(host: "shop.test"))) }
            let running = await eventually { await program(fixture, await record(fixture))?.pid != nil }
            await fixture.engine.stopBeforeTheRecord(host: "shop.test")
            let answer = await starting.value

            #expect(running)
            #expect(answer == .failure(message: "The link to shop.test did not open: the user stopped it."))
            #expect(await ended(fixture) == .stopped)
            #expect(await program(fixture, await record(fixture)) == .stopped)
        }
    }

    @Test func aRefusalOfCloudflareEndsTheStartWithItsText() async throws {
        let fixture = try await fixture()
        FileManager.default.createFile(atPath: fixture.root.appending(path: "fail429").path(percentEncoded: false), contents: nil)
        fixture.answers.set { $0.host = nil }

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test")))

            #expect(answer == .failure(message: "The link to shop.test did not open: \(ShareText.tooManyLinks)"))
            #expect(await ended(fixture) == .failed(ShareText.tooManyLinks))
        }
    }

    @Test func aFailedInstallOfCloudflaredEndsTheStartWithoutTheWaitForTheProbe() async throws {
        let fixture = try await fixture()
        let probe = FakeRedirectProbe(Array(repeating: nil, count: 100))
        try FileManager.default.removeItem(at: fixture.paths.runtime("cloudflared", line: "1"))
        await fixture.engine.useRedirectProbe(probe.probe)

        try await run(fixture) {
            let clock = ContinuousClock()
            let begin = clock.now
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test")))
            let elapsed = clock.now - begin

            guard case .failure = answer else {
                Issue.record("The start did not fail: \(answer)")
                return
            }

            #expect(elapsed < .seconds(5))
            #expect(await record(fixture)?.state.isActive == false)
        }
    }

    // MARK: The ends

    @Test func aStopEndsTheLinkStopsTheProgramAndDeletesTheVisitorLog() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let log = fixture.paths.shareVisitorLog(active.id)
            let hadLog = exists(log)

            let stopped = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let again = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let info = try #require(await fixture.engine.shareInfos().first)

            #expect(hadLog)
            #expect(stopped == .done(message: "The link to shop.test stopped."))
            #expect(again == .done(message: "shop.test has no open link."))
            #expect(await ended(fixture) == .stopped)
            #expect(await program(fixture, active) == .stopped)
            #expect(!exists(log))
            #expect(info.url == nil)
            #expect(await record(fixture)?.publicHost == nil)
        }
    }

    @Test func aQuitOfTheAppEndsEachLink() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"])

        try await run(fixture) {
            _ = try #require(await open(fixture))
            _ = try #require(await open(fixture, ShareStart(host: "blog.test")))

            let stopped = await fixture.engine.handle(.stopAllShares(appQuit: true))
            let again = await fixture.engine.handle(.stopAllShares(appQuit: false))

            #expect(stopped == .done(message: "Nexus stopped 2 links."))
            #expect(again == .done(message: "No link is open."))
            #expect(await ended(fixture) == .appQuit)
            #expect(await ended(fixture, host: "blog.test") == .appQuit)
        }
    }

    @Test func anEndOfCloudflaredAfterTheOpenEndsTheLinkWithoutANewTunnel() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let pid = try #require(await program(fixture, active)?.pid)
            _ = await eventually { lines(of: fixture.environment).count == 1 }

            kill(pid, SIGKILL)
            let failed = await eventually { await ended(fixture) != nil }
            try await Task.sleep(for: .milliseconds(500))
            let log = fixture.paths.tunnelLog("shop.test").path(percentEncoded: false)

            #expect(failed)
            #expect(await ended(fixture) == .failed(ShareText.cloudflaredStopped(log: log)))
            #expect(lines(of: fixture.starts).count == 1)
        }
    }

    @Test func theEndTimeEndsTheLink() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: "shop.test", duration: .oneHour)))
            let active = try #require(await record(fixture))
            let endsAt = try #require(active.endsAt)

            await fixture.engine.checkShares(now: endsAt.addingTimeInterval(-1))
            let before = await record(fixture)?.state
            await fixture.engine.checkShares(now: endsAt)

            #expect(endsAt.timeIntervalSince(active.started) == 3_600)
            #expect(before == .open)
            #expect(await ended(fixture) == .endTime)
        }
    }

    @Test func afterAWakeALinkWithoutAConnectionAndWithoutAnAddressEnds() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            fixture.answers.set { answers in
                answers.ready = false
                answers.resolves = false
            }

            await fixture.engine.sharesAfterWake(at: .now)

            #expect(await ended(fixture) == .sleep)
        }
    }

    @Test func afterAWakeALinkWithAConnectionStaysOpen() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))

            await fixture.engine.sharesAfterWake(at: .now)

            #expect(await record(fixture)?.state == .open)
            #expect(await fixture.engine.checksAfterWake().isEmpty)
            #expect(await fixture.engine.shareNotReadySince(active.id) == nil)
        }
    }

    @Test func afterAWakeALinkWhoseAddressStillResolvesStaysOpenAndTheCheckEachMinuteTakesOver() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            fixture.answers.set { $0.ready = false }
            let wake = Date.now

            await fixture.engine.sharesAfterWake(at: wake)

            #expect(await record(fixture)?.state == .open)
            #expect(await fixture.engine.checksAfterWake().isEmpty)
            #expect(await fixture.engine.shareNotReadySince(active.id) == wake)
        }
    }

    @Test func theCheckEachMinuteEndsALinkWithoutAConnectionAndWithoutAnAddress() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            fixture.answers.set { answers in
                answers.ready = false
                answers.resolves = nil
            }
            let now = Date.now

            await fixture.engine.checkShares(now: now)
            await fixture.engine.checkShares(now: now.addingTimeInterval(61))
            let withoutAnswer = await record(fixture)?.state
            fixture.answers.set { $0.resolves = false }
            await fixture.engine.checkShares(now: now.addingTimeInterval(122))

            #expect(withoutAnswer == .open)
            #expect(await ended(fixture) == .connectionLost)
        }
    }

    @Test func aNewStartOfNexusdEndsEachQuickLinkAndKeepsALinkOfTheOwnDomain() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"])
        let own = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "blog.test", site: "blog.test", options: ShareOptions(duration: .untilStopped, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .ownDomain), mode: .localHost, label: "blog", port: 18_500, started: .now, state: .open)
        var second: NexusEngine?

        try await run(fixture) {
            _ = try #require(await open(fixture))
            try await fixture.engine.stateStore.update { $0.shares.append(own) }
            await fixture.engine.shutdown()

            let restarted = await engine(root: fixture.root, processes: ProcessSupervisor(), answers: fixture.answers)
            second = restarted
            await restarted.endSharesOfEarlierRun()
            let shares = await restarted.stateStore.current().shares

            #expect(shares.first { $0.host == "shop.test" }?.state == .ended(.nexusdStopped))
            #expect(shares.first { $0.host == "blog.test" } == own)
        }

        await second?.shutdown()
    }

    @Test func aLinkWithoutAProgramEndsAtItsEndTimeAlsoAfterANewStartOfNexusd() async throws {
        let fixture = try await fixture()
        let options = ShareOptions(duration: .oneHour, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .ownDomain)
        let own = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "shop.test", site: "shop.test", options: options, mode: .localHost, label: "shop", started: .now.addingTimeInterval(-3_601), endsAt: .now.addingTimeInterval(-1), state: .open)
        var second: NexusEngine?

        try await run(fixture) {
            try await fixture.engine.stateStore.update { $0.shares = [own] }
            await fixture.engine.shutdown()

            let restarted = await engine(root: fixture.root, processes: ProcessSupervisor(), answers: fixture.answers)
            second = restarted
            await restarted.useShareCheckInterval(.milliseconds(50))
            await restarted.endSharesOfEarlierRun()

            #expect(await eventually { await restarted.stateStore.current().share(id: own.id)?.state == .ended(.endTime) })
        }

        await second?.shutdown()
    }

    @Test func aRemovalOfTheSiteEndsItsLink() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"])

        try await run(fixture) {
            _ = try #require(await open(fixture))

            _ = await fixture.engine.handle(.removeSite(host: "shop.test"))

            #expect(await eventually { await ended(fixture) == .siteGone })
        }
    }

    @Test func stopAllServicesEndsEachLink() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))

            _ = await fixture.engine.handle(.stopAll)

            #expect(await ended(fixture) == .stopped)
        }
    }

    // MARK: The workspaces and the visitors

    private func workspaceFixture() async throws -> (fixture: Fixture, shop: URL, host: String) {
        let fixture = try await fixture(repository: true)
        let shop = fixture.root.appending(path: "shop", directoryHint: .isDirectory)

        try await base.settle(fixture.engine)
        try await base.git("worktree", "add", "-q", "-b", "fix", fixture.root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await base.settle(fixture.engine)

        return (fixture, shop, HostName.workspaceHost("shop.test", workspace: "fix", tld: "test"))
    }

    @Test func aWorkspaceWithAnOpenLinkDoesNotStopWhenIdle() async throws {
        let (fixture, shop, host) = try await workspaceFixture()

        try await run(fixture) {
            let info = try #require(await open(fixture, ShareStart(host: host)))

            await fixture.engine.checkIdleWorkspaces(now: .now.addingTimeInterval(30 * 86_400))

            #expect(info.workspace == "fix")
            #expect(info.site == "shop.test")
            #expect(try await base.record(fixture.engine, of: shop).runState == .running)
        }
    }

    @Test func aLinkWithoutAProgramKeepsItsWorkspaceAwake() async throws {
        let (fixture, shop, host) = try await workspaceFixture()
        let preparing = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: host, site: "shop.test", workspace: "fix", options: .standard, mode: .localHost, started: .now, state: .starting(.openLink))
        let later = Date.now.addingTimeInterval(30 * 86_400)

        try await run(fixture) {
            try await fixture.engine.stateStore.update { $0.shares = [preparing] }
            await fixture.engine.checkIdleWorkspaces(now: later)
            let withLink = try await base.record(fixture.engine, of: shop).runState

            try await fixture.engine.stateStore.update { $0.shares = [] }
            await fixture.engine.checkIdleWorkspaces(now: later)

            #expect(withLink == .running)
            #expect(try await base.record(fixture.engine, of: shop).runState != .running)
        }
    }

    @Test func aVisitorCountsStartsAStoppedWorkspaceAndIsAPage() async throws {
        let (fixture, shop, host) = try await workspaceFixture()

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: host)))
            let active = try #require(await record(fixture, host: host))
            _ = await fixture.engine.handle(.stopWorkspace(host: "shop.test", name: "fix"))
            let stopped = try await base.record(fixture.engine, of: shop).runState

            let line = #"{"time":1800000000.125,"request":"5f2b","status":200,"visitor":"203.0.113.7"}"# + "\n"
            let handle = try FileHandle(forWritingTo: fixture.paths.shareVisitorLog(active.id))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()

            let counted = await eventually { await fixture.engine.shareInfos().first?.visitors == 1 }
            let started = await eventually { (try? await base.record(fixture.engine, of: shop).runState) == .running }
            let state = await fixture.engine.stateStore.current()
            let tracked = try #require(await fixture.engine.trackedWorkspaces(key: RealPath.of(shop), sites: state.sites, state: state).first)

            #expect(stopped == .stopped)
            #expect(counted)
            #expect(await fixture.engine.shareInfos().first?.lastVisit != nil)
            #expect(started)
            #expect(await fixture.engine.lastActivity(of: tracked)?.source == .page)
        }
    }

    @Test func aRemovalOfTheWorkspaceEndsItsLink() async throws {
        let (fixture, _, host) = try await workspaceFixture()

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: host)))

            _ = await fixture.engine.handle(.removeWorkspace(host: "shop.test", name: "fix", force: true))

            #expect(await eventually { await ended(fixture, host: host) == .siteGone })
        }
    }

    // MARK: The preview, the defaults and the log

    @Test func thePreviewGivesTheDefaultsAndTheOpenLinkAndTheDefaultsAreSaved() async throws {
        let fixture = try await fixture()
        let defaults = ShareOptions(duration: .fourHours, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .random)

        try await run(fixture) {
            let saved = await fixture.engine.handle(.setShareDefaults(defaults))
            _ = try #require(await open(fixture, ShareStart(host: "shop.test", password: false)))
            let preview = await fixture.engine.handle(.sharePreview(host: "www.shop.test"))
            let list = await fixture.engine.siteList()

            guard case .sharePreview(let sheet) = preview else {
                Issue.record("no preview: \(preview)")
                return
            }

            #expect(saved == .done(message: "Nexus saved the defaults for new links."))
            #expect(sheet.host == "shop.test")
            #expect(sheet.defaults == defaults)
            #expect(sheet.openLink?.url == "https://\(Self.publicHost)")
            #expect(sheet.openLink?.options.duration == .fourHours)
            #expect(sheet.openLink?.options.password == false)
            #expect(list.shareDefaults == defaults)
            #expect(list.sites.first?.share?.state == .open)
        }
    }

    @Test func theActivityLogNamesEachStepWithoutTheAddressTheIDOrThePassword() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: "shop.test", duration: .untilStopped)))
            let active = try #require(await record(fixture))
            try await fixture.engine.stateStore.update { $0.shares[0].password = "plum-river-42" }
            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            await fixture.engine.activity?.waitForWrites()

            let lines = lines(of: fixture.activity).filter { $0.contains(" share: ") }.map { String($0.split(separator: " share: ", maxSplits: 1)[1]) }
            let all = try String(contentsOf: fixture.activity, encoding: .utf8)

            #expect(lines == [
                "Nexus opens a link to shop.test: ends when you stop it, password off, error details hidden, requests off.",
                "The link to shop.test is open.",
                "The link to shop.test stopped: the user stopped it.",
            ])
            #expect(all.contains("nginx reloaded: a change of the public links"))
            #expect(!all.contains(Self.publicHost))
            #expect(!all.contains(active.id))
            #expect(!all.contains("plum-river-42"))
        }
    }

    // MARK: A cloudflared of the user

    @Test func theDefaultMetricsPortsOfCloudflaredDoNotChangeThePortOfNexus() async throws {
        var listeners: [Int32] = []

        for port in 20_241...20_245 {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }

            if bound == 0, listen(listener, 4) == 0 {
                listeners.append(listener)
            } else {
                close(listener)
            }
        }

        defer { listeners.forEach { close($0) } }
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let metricsPort = try #require(await record(fixture)?.metricsPort)

            #expect(!(20_241...20_245).contains(metricsPort))
            #expect(fixture.answers.current.askedPorts == [metricsPort])
        }
    }

    @Test func aNewStartEndsOnlyACloudflaredWithTheMarkerOfItsRoot() async throws {
        let fixture = try await fixture(startsNginx: false)
        let copy = fixture.root.appending(path: "cloudflared")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: copy)
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/codesign"), arguments: ["-f", "-s", "-", copy.path(percentEncoded: false)]))

        let ofTheUser = Process()
        ofTheUser.executableURL = copy
        ofTheUser.arguments = ["300"]
        try ofTheUser.run()
        defer { ofTheUser.terminate() }

        let crashed = ProcessSupervisor()
        let record = ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: .standard, mode: .localHost, port: 18_400, started: .now, state: .open)
        let link = await fixture.engine.cloudflaredDefinition(record, binary: copy, metricsPort: 18_401)
        try await crashed.start(ServiceDefinition(id: link.id, displayName: link.displayName, executable: copy, arguments: ["300"], environment: link.environment, logFile: link.logFile, restartsAfterExit: false))
        let ofNexus = try #require(await crashed.state(of: link.id)?.pid)

        try await run(fixture) {
            await fixture.engine.endProcessesOfEarlierRun()

            #expect(await eventually { kill(ofNexus, 0) != 0 })
            #expect(kill(ofTheUser.processIdentifier, 0) == 0)
        }

        await crashed.stopAll(cause: "the end of a test")
    }

    // MARK: The protection of visitors (4d)

    private func posixPermissions(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.posixPermissions] as? Int
    }

    private func passwordMatches(_ line: String, _ password: String) -> Bool {
        guard line.hasPrefix("nexus:{SSHA}"), let data = Data(base64Encoded: String(line.dropFirst("nexus:{SSHA}".count))), data.count > 20 else {
            return false
        }

        return ShareProtection.passwordLine(password: password, salt: Array(data.dropFirst(20))) == line + "\n"
    }

    @Test func aLinkWithThePasswordGetsAPrivateFileThatNginxReadsAndLosesItAtTheEnd() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let info = try #require(await open(fixture, ShareStart(host: "shop.test", password: true)))
            let active = try #require(await record(fixture))
            let password = try #require(active.password)
            let file = fixture.paths.sharePasswordFile(active.id)
            let lines = lines(of: file)
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)
            await fixture.engine.activity?.waitForWrites()
            let activity = try String(contentsOf: fixture.activity, encoding: .utf8)

            #expect(password.wholeMatch(of: /[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}/) != nil)
            #expect(info.password == password)
            #expect(posixPermissions(of: file) == 0o600)
            #expect(posixPermissions(of: fixture.paths.shareFolder) == 0o700)
            #expect(lines.count == 1)
            #expect(passwordMatches(lines.first ?? "", password))
            #expect(!passwordMatches(lines.first ?? "", "k7mq-2xfh-9pwd-r4tc"))
            #expect(config.contains("        auth_basic $nexus_guard_realm;"))
            #expect(config.contains("        auth_basic_user_file \"\(file.path(percentEncoded: false))\";"))
            #expect(activity.contains("password on"))
            #expect(!activity.contains(password))

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))

            #expect(!exists(file))
            #expect(await record(fixture)?.password == nil)
        }
    }

    @Test func aLinkWithoutThePasswordHasNoFileAndNoPasswordInNginx() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: "shop.test", password: false)))
            let active = try #require(await record(fixture))
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(active.password == nil)
            #expect(!exists(fixture.paths.sharePasswordFile(active.id)))
            #expect(!config.contains("auth_basic"))
            #expect(config.contains("        if ($nexus_guard_hidden) {"))
        }
    }

    @Test func eachPasswordIsNewAndHasFourGroupsOfFourCharactersThatAPersonReadsWithoutDoubt() {
        var generator = SystemRandomNumberGenerator()
        let passwords = (0..<200).map { _ in NexusEngine.sharePassword(using: &generator) }

        #expect(Set(passwords).count == passwords.count)
        #expect(passwords.allSatisfy { $0.wholeMatch(of: /[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}/) != nil })
        #expect(NexusEngine.sharePasswordCharacters.count == 31)
    }

    @Test func aPasswordFileThatCannotBeWrittenEndsTheStartWithItsText() async throws {
        let fixture = try await fixture()
        let folder = fixture.paths.shareFolder.path(percentEncoded: false)
        try? FileManager.default.removeItem(atPath: folder)
        try Data().write(to: URL(filePath: String(folder.dropLast()), directoryHint: .notDirectory))

        try await run(fixture) {
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test", password: true)))

            guard case .failure(let message) = answer else {
                Issue.record("The start did not fail: \(answer)")
                return
            }

            #expect(message.hasPrefix("Nexus cannot save the password of the link in its data folder. "))
            #expect(await ended(fixture).map { if case .failed = $0 { true } else { false } } == true)
        }
    }

    private func block(_ fixture: Fixture, options: ShareOptions = .standard, site: WebSite?) async -> ShareBlock {
        let record = ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: options, mode: .localHost, port: 18_400, started: .now, state: .open)
        return await fixture.engine.shareBlock(for: record, site: site)
    }

    private func webSite(_ backend: WebBackend) -> WebSite {
        WebSite(hosts: ["shop.test"], backend: backend, certificate: URL(filePath: "/c.crt"), key: URL(filePath: "/c.key"), accessLog: URL(filePath: "/a.log"))
    }

    @Test func withoutTheOptionTheBlockHasNoLineOfTheOptionAndPHPKeepsItsSocket() async throws {
        let fixture = try await fixture()
        var options = ShareOptions.standard
        options.hidesErrors = false

        try await run(fixture) {
            _ = try #require(await open(fixture, ShareStart(host: "shop.test", hidesErrors: false)))
            let active = try #require(await record(fixture))
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)
            let share = try #require(await fixture.engine.siteShare(for: "shop.test", in: [active], phpLine: "8.4"))
            let block = try ShareProtection.refusals(for: await block(fixture, options: options, site: nil))

            #expect(!config.contains("@nexus_guard_error"))
            #expect(!config.contains("proxy_intercept_errors"))
            #expect(!config.contains("$nexus_guard_debug)"))
            #expect(share.fastcgiValues["APP_DEBUG"] == nil)
            #expect(share.fastcgiValues["REMOTE_ADDR"] == "$http_x_nexus_share_visitor")
            #expect(share.shareSocket == nil)
            #expect(!block.contains("recursive_error_pages on;"))
        }
    }

    @Test func theSiteBlockOfTheSharedHostGetsTheValuesOfTheLinkAndThePoolOnlyForPHP() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"])

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let shared = try #require(await fixture.engine.siteShare(for: "shop.test", in: [active], phpLine: "8.4"))
            let app = try #require(await fixture.engine.siteShare(for: "shop.test", in: [active], phpLine: nil))
            let other = await fixture.engine.siteShare(for: "blog.test", in: [active], phpLine: "8.4")
            let hostValues = await fixture.engine.shareFastCGIValues(of: active)

            #expect(shared.fastcgiValues == hostValues.merging(ShareProtection.fastcgiValues(for: .standard)) { _, protection in protection })
            #expect(ShareProtection.fastcgiValues(for: .standard).allSatisfy { shared.fastcgiValues[$0.key] == $0.value })
            #expect(shared.shareSocket == fixture.paths.phpShareSocket(line: "8.4"))
            #expect(app.shareSocket == nil)
            #expect(app.fastcgiValues["REMOTE_ADDR"] == "$http_x_nexus_share_visitor")
            #expect(other == nil)
            #expect(NexusEngine.sharePHPLine(of: .php(server: .nginx, documentRoot: fixture.root, socket: fixture.root), php: "8.4") == "8.4")
            #expect(NexusEngine.sharePHPLine(of: .php(server: .apache, documentRoot: fixture.root, socket: fixture.root), php: "8.4") == "8.4")
            #expect(NexusEngine.sharePHPLine(of: .app(port: 3_000, framework: nil), php: "8.4") == nil)
        }
    }

    @Test func onlyTheSiteBlockOfTheSharedHostGetsTheMapOfTheAddressOfTheVisitor() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"])
        try Self.install("php", line: "8.4", version: "8.4.0", in: fixture.paths)

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let active = try #require(await record(fixture))
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(config.contains("        default $remote_addr;\n        \"\(active.id)\" \"$http_x_nexus_share_visitor\";"))
            #expect(config.components(separatedBy: "fastcgi_param REMOTE_ADDR $nexus_share_").count == 2)
            #expect(config.components(separatedBy: "fastcgi_param REMOTE_ADDR").count == 2)
        }
    }

    @Test func theCustomPathsOfTheDebugToolsComeFromTheEnvOfTheLaravelApplication() async throws {
        let fixture = try await fixture()
        let laravel = fixture.root.appending(path: "laravel", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: laravel.appending(path: "public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: laravel.appending(path: "bootstrap"), withIntermediateDirectories: true)
        try Data().write(to: laravel.appending(path: "artisan"))
        try Data().write(to: laravel.appending(path: "bootstrap/app.php"))
        try Data("TELESCOPE_PATH=/admin/telescope/\nHORIZON_PATH=horizon\nPULSE_PATH=\"${APP}/pulse\"\n".utf8).write(to: laravel.appending(path: ".env"))
        var off = ShareOptions.standard
        off.hidesErrors = false

        try await run(fixture) {
            let site = webSite(.php(server: .nginx, documentRoot: laravel.appending(path: "public", directoryHint: .isDirectory), socket: fixture.root))
            let on = await block(fixture, site: site)
            let without = await block(fixture, options: off, site: site)
            let refusals = try ShareProtection.refusals(for: on)

            #expect(on.debugPaths == ["${APP}/pulse", "admin/telescope"])
            #expect(without.debugPaths.isEmpty)
            #expect(refusals.contains(#"if ($uri ~* "^(?:/_nexus/host/[^/]+)?/(?:admin/telescope)(?:/|$)") {"#))
        }
    }

    @Test func onlyADocumentRootWithTheAutoloaderOfComposerGetsTheVendorRule() async throws {
        let fixture = try await fixture()
        let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        let laravel = fixture.root.appending(path: "laravel", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain.appending(path: "vendor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: laravel.appending(path: "vendor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: laravel.appending(path: "public"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: plain.appending(path: "vendor/autoload.php"))
        try Data("<?php".utf8).write(to: laravel.appending(path: "vendor/autoload.php"))

        try await run(fixture) {
            let plainBlock = await block(fixture, site: webSite(.php(server: .nginx, documentRoot: plain, socket: fixture.root)))
            let apacheBlock = await block(fixture, site: webSite(.php(server: .apache, documentRoot: plain, socket: fixture.root)))
            let laravelBlock = await block(fixture, site: webSite(.php(server: .nginx, documentRoot: laravel.appending(path: "public", directoryHint: .isDirectory), socket: fixture.root)))
            let nodeBlock = await block(fixture, site: webSite(.app(port: 3_000, framework: nil)))
            let missing = await block(fixture, site: nil)
            let plainLines = try ShareProtection.refusals(for: plainBlock)
            let laravelLines = try ShareProtection.refusals(for: laravelBlock)

            #expect(plainBlock.composerInDocumentRoot)
            #expect(apacheBlock.composerInDocumentRoot)
            #expect(!laravelBlock.composerInDocumentRoot)
            #expect(!nodeBlock.composerInDocumentRoot)
            #expect(!missing.composerInDocumentRoot)
            #expect(plainLines.contains("if ($nexus_guard_vendor = composer) {"))
            #expect(!laravelLines.contains("if ($nexus_guard_vendor = composer) {"))
        }
    }

    @Test func thePHPConfigurationHasThePoolOfTheLinksAndStopsXdebugThereWhenPHPIniLoadsIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try base.makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        let extensions = await engine.paths.runtime("php", line: "8.5").appending(path: "lib/php/extensions/no-debug-non-zts-20250925", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data().write(to: extensions.appending(path: "xdebug.so"))
        let folder = await engine.paths.phpConfigFolder(line: "8.5")
        let socket = await engine.paths.phpShareSocket(line: "8.5").path(percentEncoded: false)

        try await base.whileRunning(engine) {
            _ = try await engine.writePHPConfig(line: "8.5", state: await engine.stateStore.current())
            let plain = try String(contentsOf: folder.appending(path: "php-fpm.conf"), encoding: .utf8)

            try Data("zend_extension = xdebug\n".utf8).write(to: folder.appending(path: "php.ini"))
            let changed = try await engine.writePHPConfig(line: "8.5", state: await engine.stateStore.current())
            let withXdebug = try String(contentsOf: folder.appending(path: "php-fpm.conf"), encoding: .utf8)
            let debugPool = try String(contentsOf: folder.appending(path: PHPConfig.xdebugFPMConfigName), encoding: .utf8)

            #expect(plain.contains("[nexus-share]\nlisten = \"\(socket)\"\n"))
            #expect(!plain.contains("xdebug.start_with_request"))
            #expect(changed)
            #expect(withXdebug.contains("php_admin_value[xdebug.start_with_request] = \"no\"\n"))
            #expect(!debugPool.contains("[nexus-share]"))
        }
    }

    // MARK: The real nginx

    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNginxAcceptsTwoSitesWithTwoShareBlocks() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root)
        try paths.createFolders()
        try base.linkRealRuntimes(in: paths, ["nginx/1.30"])
        try Self.install("php", line: "8.5", version: "8.5.0", in: paths)
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = base.freePort()
        state.ports[ServiceCatalog.httpsPortKey] = base.freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()

        for host in ["shop.test", "blog.test"] {
            let folder = root.appending(path: host, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.sites.append(Site(host: host, folder: folder, php: "8.5"))
        }

        state.shares = [
            ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: .standard, mode: .localHost, port: 18_600, metricsPort: 18_601, started: .now, state: .open),
            ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "blog.test", site: "blog.test", options: .standard, mode: .localHost, port: 18_602, metricsPort: 18_603, started: .now, state: .open),
        ]
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))
        let engine = await engine(root: root, processes: ProcessSupervisor(), answers: FakeLinkAnswers())

        try await base.whileRunning(engine) {
            _ = try await engine.writeWebConfig()
            let config = try String(contentsOf: paths.nginxConfig, encoding: .utf8)

            #expect(config.contains("listen 127.0.0.1:18600 default_server;"))
            #expect(config.contains("listen 127.0.0.1:18602 default_server;"))
            #expect(config.contains("combined if=$nexus_site_log;"))
        }
    }
}
