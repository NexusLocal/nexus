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

// The API of Cloudflare and the name servers of 1.1.1.1 in memory.
final class FakeCloudflare: Sendable {
    struct State {
        var zoneName = "example.com"
        var nameservers: [String]? = ["anna.ns.cloudflare.com", "bob.ns.cloudflare.com"]
        var records: [CloudflareDNSRecord] = []
        var tunnels: [String: String] = [:]
        var takenNames: Set<String> = []
        var deletedTunnels: [String] = []
        var puts: [[String: Int]] = []
        var version = 0
        var appliedVersion: Int?
        var failure: CloudflareAPIError?
        var tokenFailure: CloudflareAPIError?
        var nextID = 1
        var holdsRecords = false
        var recordsCalls = 0
        var createDelay: Duration?
        var tokenDelay: Duration?
        var deleteDelay: Duration?
    }

    private let state = Mutex(State())

    func set(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    var current: State {
        state.withLock { $0 }
    }

    private func check() throws {
        if let failure = current.failure {
            throw failure
        }
    }

    var api: CloudflareAPI {
        CloudflareAPI(
            zoneName: { _, _ in
                try self.check()
                return self.current.zoneName
            },
            records: { _, name, _ in
                self.set { $0.recordsCalls += 1 }
                try self.check()

                while self.current.holdsRecords {
                    try await Task.sleep(for: .milliseconds(10))
                }

                return self.current.records.filter { $0.name == name }
            },
            addRecord: { _, name, target, _ in
                try self.check()
                self.set { state in
                    state.records.append(CloudflareDNSRecord(id: "record-\(state.nextID)", type: "CNAME", name: name, content: target))
                    state.nextID += 1
                }
            },
            deleteRecord: { _, id, _ in
                try self.check()
                self.set { $0.records.removeAll { $0.id == id } }
            },
            createTunnel: { _, name, _ in
                try self.check()
                let id = try self.state.withLock { state in
                    guard !state.takenNames.contains(name) else {
                        throw CloudflareAPIError.conflict
                    }

                    let id = "tunnel-\(state.nextID)"
                    state.nextID += 1
                    state.takenNames.insert(name)
                    state.tunnels[id] = name
                    return id
                }

                if let delay = self.current.createDelay {
                    try await Task.sleep(for: delay)
                }

                return id
            },
            putRules: { _, _, rules, _ in
                try self.check()
                return self.state.withLock { state in
                    state.puts.append(rules)
                    state.version += 1
                    return state.version
                }
            },
            tunnelToken: { _, id, _ in
                try self.check()

                if let failure = self.current.tokenFailure {
                    throw failure
                }

                if let delay = self.current.tokenDelay {
                    try await Task.sleep(for: delay)
                }

                return Data("token-of-\(id)".utf8)
            },
            deleteTunnel: { _, id, _ in
                try self.check()

                if let delay = self.current.deleteDelay {
                    try await Task.sleep(for: delay)
                }

                self.set { state in
                    state.deletedTunnels.append(id)
                    state.tunnels[id] = nil
                }
            }
        )
    }

    // cloudflared takes each new version at once, unless appliedVersion holds it back.
    func seams(loginLimit: Duration) -> OwnDomainSeams {
        OwnDomainSeams(
            nameservers: { _ in self.current.nameservers },
            computerName: { "Jo’s MacBook Pro" },
            api: api,
            configVersion: { _ in self.current.appliedVersion ?? self.current.version },
            loginLimit: loginLimit,
            configLimit: .seconds(1)
        )
    }
}

extension NexusEngine {
    func useOwnDomainFakes(_ seams: OwnDomainSeams, keys: any CloudflareKeyStore) {
        ownDomainSeams = seams
        cloudflareKeys = keys
    }

    func currentOwnDomainInfo() async -> OwnDomainInfo? {
        ownDomainInfo(await stateStore.current())
    }

    func currentOwnDomainTunnel() -> OwnDomainTunnel? {
        ownDomainTunnel
    }

    func quickLinkPrograms() -> Int {
        sharePrograms.count
    }

    func useShareBlockAnswers(_ answers: @escaping @Sendable (Int) -> Bool) {
        shareBlockAnswers = answers
    }
}

// A gate that a test opens. The work at the gate waits until then. blockUntilOpen holds the thread.
// So an actor lets no other work in while its work waits at the gate.
final class TestGate: Sendable {
    private let state = Mutex((reached: false, opened: false))

    var reached: Bool {
        state.withLock { $0.reached }
    }

    func open() {
        state.withLock { $0.opened = true }
    }

    func blockUntilOpen() {
        state.withLock { $0.reached = true }

        while !state.withLock({ $0.opened }) {
            usleep(10_000)
        }
    }

    func waitUntilOpen() async {
        state.withLock { $0.reached = true }

        while !state.withLock({ $0.opened }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite(.serialized)
struct OwnDomainEngineTests {
    private let base = NexusEngineTests()
    private static let build = (version: "2026.11.0", revision: 1, sha256: "fake-cloudflared")
    private static let loginPage = "https://dash.cloudflare.com/argotunnel?callback=secret-callback"
    private static let tunnelName = "nexus-jos-macbook-pro"

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
        connectionInterval: .seconds(60),
        resumeLimit: .seconds(1)
    )

    private struct Fixture {
        let root: URL
        let paths: NexusPaths
        let engine: NexusEngine
        let answers: FakeLinkAnswers
        let cloudflare: FakeCloudflare
        let keys: MemoryCloudflareKeyStore
        let processes: ProcessSupervisor
        let calls: URL
        let environment: URL
        let activity: URL
        let authorize: URL
    }

    // The fake cloudflared writes its arguments and its environment at each call. The login waits
    // for the file authorize. Then it writes the cert as cloudflared does. With the file loginend
    // the login writes the text of that file and stops without a cert. With the file failrun the
    // tunnel exits at once.
    private static func fakeCloudflared(root: URL) -> String {
        let folder = root.path(percentEncoded: false)

        return """
            #!/bin/sh
            echo "$*" >> '\(folder)/calls.txt'
            echo "$HOME|${TUNNEL_TOKEN:+token}|$\(BackgroundProcessMarker.name)" >> '\(folder)/environment.txt'
            case "$*" in
            *" login")
                echo "Please open the following URL and log in with your Cloudflare account:"
                echo ""
                echo "\(loginPage)"
                while [ ! -f '\(folder)/authorize' ]; do
                    if [ -f '\(folder)/loginend' ]; then
                        cat '\(folder)/loginend'
                        exit 1
                    fi
                    sleep 0.05
                done
                mkdir -p "$HOME/.cloudflared"
                cp '\(folder)/cert.pem' "$HOME/.cloudflared/cert.pem"
                exit 0
                ;;
            *" run")
                if [ -f '\(folder)/failrun' ]; then
                    exit 1
                fi
                exec /bin/sleep 600
                ;;
            *" --url "*)
                exec /bin/sleep 600
                ;;
            esac
            exit 0

            """
    }

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

    private static func viteProject(at folder: URL) throws {
        let files = [
            "artisan": "<?php",
            "bootstrap/app.php": "<?php",
            "vite.config.js": "export default {};\n",
            "package.json": #"{"scripts": {"dev": "vite", "build": "vite build"}}"#,
            "node_modules/vite/package.json": #"{"name": "vite", "version": "8.3.8"}"#,
        ]

        for (path, text) in files {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        try FileManager.default.createDirectory(at: folder.appending(path: "public"), withIntermediateDirectories: true)
    }

    private static func heldBuild(root: URL) -> String {
        let folder = root.path(percentEncoded: false)

        return """
            #!/bin/sh
            echo $$ > '\(folder)/build.pid'
            while [ -f '\(folder)/hold' ]; do sleep 0.05; done
            mkdir -p public/build && echo '{}' > public/build/manifest.json

            """
    }

    private static func buildRuns(root: URL) -> Bool {
        guard let text = try? String(contentsOf: root.appending(path: "build.pid"), encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        return kill(pid, 0) == 0
    }

    private static func install(_ name: String, line: String, version: String, revision: Int = 1, sha256: String = "", in paths: NexusPaths) throws {
        let folder = paths.runtime(name, line: line)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runtime = InstalledRuntime(name: name, line: line, version: version, revision: revision, sha256: sha256, installedAt: .now, folder: folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(runtime).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
    }

    private static func manifest() -> FixedManifest {
        let package = ManifestPackage(name: "cloudflared", version: build.version, line: "1", revision: build.revision, url: URL(filePath: "/nonexistent/cloudflared.tar.xz"), sha256: build.sha256, format: .tarXZ)
        return FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [package]))
    }

    private static func paths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
    }

    private func engine(root: URL, processes: ProcessSupervisor, answers: FakeLinkAnswers, cloudflare: FakeCloudflare, keys: MemoryCloudflareKeyStore, loginLimit: Duration) async -> NexusEngine {
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
        await engine.useOwnDomainFakes(cloudflare.seams(loginLimit: loginLimit), keys: keys)
        return engine
    }

    // connected gives a domain that the setup made already, with its two keys.
    private func fixture(hosts: [String] = ["shop.test"], connected: Bool = false, loginLimit: Duration = .seconds(10), change: (inout EngineState) -> Void = { _ in }) async throws -> Fixture {
        let root = shortTemporaryRoot()
        let paths = Self.paths(root)
        try paths.createFolders()
        let httpPort = base.freePort()
        var state = EngineState()

        state.ports[ServiceCatalog.httpPortKey] = httpPort
        state.ports[ServiceCatalog.httpsPortKey] = base.freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()

        for host in hosts {
            let folder = root.appending(path: host, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.sites.append(Site(host: host, folder: folder, php: "8.4"))
        }

        let cloudflare = FakeCloudflare()
        let keys = MemoryCloudflareKeyStore()

        if connected {
            state.ownDomain = OwnDomainRecord(domain: "example.com", tunnelID: "tunnel-1", tunnelName: Self.tunnelName, metricsPort: 0)
            try keys.save(CloudflareAPITests.pem(), as: .cert)
            try keys.save(Data("token-of-tunnel-1".utf8), as: .tunnel)
            cloudflare.set { fake in
                fake.tunnels["tunnel-1"] = Self.tunnelName
                fake.takenNames.insert(Self.tunnelName)
                fake.nextID = 2
            }
        }

        change(&state)
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))
        try CloudflareAPITests.pem().write(to: root.appending(path: "cert.pem"))

        try Self.install("nginx", line: "1.30", version: "1.30.0", in: paths)
        try Self.writeProgram(Self.fakeNginx(httpPort: httpPort), to: paths.runtime("nginx", line: "1.30").appending(path: "sbin/nginx"))
        try Self.writeProgram("", to: paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so"))
        try Self.install("cloudflared", line: "1", version: Self.build.version, revision: Self.build.revision, sha256: Self.build.sha256, in: paths)
        try Self.writeProgram(Self.fakeCloudflared(root: root), to: paths.runtime("cloudflared", line: "1").appending(path: "bin/cloudflared"))

        let answers = FakeLinkAnswers()
        let processes = ProcessSupervisor(policy: RestartPolicy(firstDelay: .milliseconds(20), maximumDelay: .milliseconds(40), stableAfter: .seconds(60), maximumQuickRestarts: 2, stopTimeout: .seconds(2)))
        let engine = await engine(root: root, processes: processes, answers: answers, cloudflare: cloudflare, keys: keys, loginLimit: loginLimit)
        let started = await engine.handle(.start(service: ServiceCatalog.nginxID))

        guard case .done = started else {
            await engine.shutdown()
            throw RuntimeError.unsupported("The fake nginx did not start: \(started)")
        }

        return Fixture(root: root, paths: paths, engine: engine, answers: answers, cloudflare: cloudflare, keys: keys, processes: processes, calls: root.appending(path: "calls.txt"), environment: root.appending(path: "environment.txt"), activity: root.appending(path: "activity.log"), authorize: root.appending(path: "authorize"))
    }

    private func run(_ fixture: Fixture, _ steps: () async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await base.whileRunning(fixture.engine, steps)
    }

    private func lines(of file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func record(_ fixture: Fixture, host: String = "shop.test") async -> ShareRecord? {
        await fixture.engine.stateStore.current().shares.first { $0.host == host }
    }

    private func open(_ fixture: Fixture, host: String = "shop.test", label: String? = nil) async -> NexusResponse {
        await fixture.engine.handle(.startShare(ShareStart(host: host, address: .ownDomain, label: label)))
    }

    private func authorize(_ fixture: Fixture) throws {
        try Data().write(to: fixture.authorize)
    }

    private func runCalls(_ fixture: Fixture) -> [String] {
        lines(of: fixture.calls).filter { $0.hasSuffix(" run") }
    }

    // MARK: The check

    @Test func aDomainWithTheNameServersOfCloudflareUsesCloudflare() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let answer = await fixture.engine.handle(.checkOwnDomain(domain: " Example.com "))

            #expect(answer == .ownDomainCheck(OwnDomainCheck(domain: "example.com", usesCloudflare: true, nameservers: ["anna.ns.cloudflare.com", "bob.ns.cloudflare.com"])))
        }
    }

    @Test func otherNameServersNoNameServersAndNoAnswerGiveTheirOwnValue() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            fixture.cloudflare.set { $0.nameservers = ["ns1.example.net", "anna.ns.cloudflare.com"] }
            let other = await fixture.engine.handle(.checkOwnDomain(domain: "example.com"))
            fixture.cloudflare.set { $0.nameservers = [] }
            let none = await fixture.engine.handle(.checkOwnDomain(domain: "dev.example.com"))
            fixture.cloudflare.set { $0.nameservers = nil }
            let blocked = await fixture.engine.handle(.checkOwnDomain(domain: "example.com"))
            let notADomain = await fixture.engine.handle(.checkOwnDomain(domain: "com"))

            #expect(other == .ownDomainCheck(OwnDomainCheck(domain: "example.com", usesCloudflare: false, nameservers: ["ns1.example.net", "anna.ns.cloudflare.com"])))
            #expect(none == .ownDomainCheck(OwnDomainCheck(domain: "dev.example.com", usesCloudflare: false, nameservers: [])))
            #expect(blocked == .ownDomainCheck(OwnDomainCheck(domain: "example.com", usesCloudflare: nil, nameservers: [])))
            #expect(notADomain == .failure(message: ShareText.OwnDomain.notADomain))
        }
    }

    // MARK: The setup

    @Test func theSetupShowsTheLoginPageThenConnectsWithTwoKeysAndNoFiles() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let answer = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            let first = await fixture.engine.currentOwnDomainInfo()

            #expect(answer == .done(message: ShareText.OwnDomain.connectSteps("example.com")))
            #expect(first?.state == .connecting(loginPage: nil) || first?.state == .connecting(loginPage: Self.loginPage))
            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .connecting(loginPage: Self.loginPage) })

            try authorize(fixture)

            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .connected })

            let state = await fixture.engine.stateStore.current()
            let homes = lines(of: fixture.environment).map { $0.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? "" }

            #expect(state.ownDomain == OwnDomainRecord(domain: "example.com", tunnelID: "tunnel-1", tunnelName: Self.tunnelName, metricsPort: 0))
            #expect(await fixture.engine.currentOwnDomainInfo() == OwnDomainInfo(domain: "example.com", tunnelName: Self.tunnelName, state: .connected))
            #expect(fixture.keys.keys[.cert] == CloudflareAPITests.pem())
            #expect(fixture.keys.keys[.tunnel] == Data("token-of-tunnel-1".utf8))
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownDomainLoginCert.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownDomainLoginLog.path(percentEncoded: false)))
            #expect(homes == [fixture.paths.ownDomainFolder.path(percentEncoded: false)])
            #expect(!homes.contains(NSHomeDirectory()))
            #expect(lines(of: fixture.calls) == ["tunnel --config \(fixture.paths.ownDomainCommandConfig.path(percentEncoded: false)) login"])
            #expect(lines(of: fixture.activity).contains { $0.hasSuffix(ShareText.OwnDomain.connectedLine("example.com", tunnel: Self.tunnelName)) })
        }
    }

    @Test func aKeyOfAnotherDomainIsRefusedAndRemoved() async throws {
        let fixture = try await fixture()
        try Data().write(to: fixture.authorize)
        fixture.cloudflare.set { $0.zoneName = "other.com" }

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))

            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .failed(ShareText.OwnDomain.otherDomain(selected: "other.com", asked: "example.com"), keyMade: true) })
            #expect(await fixture.engine.stateStore.current().ownDomain == nil)
            #expect(fixture.keys.keys.isEmpty)
            #expect(fixture.cloudflare.current.tunnels.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownDomainLoginCert.path(percentEncoded: false)))
        }
    }

    @Test func aTunnelNameThatExistsGetsTheNextNumber() async throws {
        let fixture = try await fixture()
        try Data().write(to: fixture.authorize)
        fixture.cloudflare.set { $0.takenNames = [Self.tunnelName] }

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))

            #expect(await eventually { await fixture.engine.stateStore.current().ownDomain != nil })
            #expect(await fixture.engine.stateStore.current().ownDomain?.tunnelName == "\(Self.tunnelName)-2")
        }
    }

    @Test func aCancelDuringTheLoginStopsItAndLeavesNothing() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .connecting(loginPage: Self.loginPage) })

            let answer = await fixture.engine.handle(.cancelOwnDomain)

            #expect(answer == .done(message: ShareText.OwnDomain.setupStopped("example.com")))
            #expect(await fixture.engine.currentOwnDomainInfo() == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownDomainLoginLog.path(percentEncoded: false)))
            #expect(fixture.keys.keys.isEmpty)
            #expect(await eventually { (try? String(contentsOf: fixture.calls, encoding: .utf8))?.contains("login") == true })
        }
    }

    @Test func noClickWithinTheTimeLimitGivesTheTextOfTheTimeLimit() async throws {
        let fixture = try await fixture(loginLimit: .milliseconds(400))

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))

            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .failed(ShareText.OwnDomain.loginTimedOut, keyMade: false) })
        }
    }

    @Test(arguments: [
        (CloudflareAPITests.loginWaitEndedLog, ShareText.OwnDomain.loginTimedOut),
        (CloudflareAPITests.otherLoginErrorLog, ShareText.OwnDomain.noKey),
    ])
    func aLoginThatCloudflaredEndsGivesTheTextOfItsEnd(log: String, text: String) async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .connecting(loginPage: Self.loginPage) })

            try Data(log.utf8).write(to: fixture.root.appending(path: "loginend"))

            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .failed(text, keyMade: false) })
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownDomainLoginLog.path(percentEncoded: false)))
            #expect(fixture.keys.keys.isEmpty)
        }
    }

    @Test func aFailureAfterTheNewTunnelDeletesThatTunnel() async throws {
        let fixture = try await fixture()
        try Data().write(to: fixture.authorize)
        fixture.cloudflare.set { $0.tokenFailure = .failed(status: 500, message: "Internal error") }

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))

            #expect(await eventually { await fixture.engine.currentOwnDomainInfo()?.state == .failed(ShareText.OwnDomain.tunnelNotMade(Self.tunnelName, log: fixture.paths.ownDomainTunnelLog.path(percentEncoded: false)), keyMade: true) })
            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(fixture.keys.keys.isEmpty)
            #expect(await fixture.engine.stateStore.current().ownDomain == nil)
            #expect(lines(of: fixture.activity).contains { $0.hasSuffix(ShareText.OwnDomain.setupTunnelDeletedLine("example.com", tunnel: Self.tunnelName)) })
        }
    }

    @Test func aConnectWhileADomainIsConnectedSaysWhy() async throws {
        let fixture = try await fixture(connected: true)

        try await run(fixture) {
            let answer = await fixture.engine.handle(.connectOwnDomain(domain: "other.com"))

            #expect(answer == .failure(message: ShareText.OwnDomain.inUse("example.com")))
        }
    }

    @Test func aConnectDuringTheCleanupOfASetupOwnsTheSetupAndStartsOneLogin() async throws {
        let fixture = try await fixture()
        let engine = fixture.engine

        try await run(fixture) {
            _ = await engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { await engine.currentOwnDomainInfo()?.state == .connecting(loginPage: Self.loginPage) })

            async let other = engine.handle(.connectOwnDomain(domain: "other.com"))
            async let third = engine.handle(.connectOwnDomain(domain: "example.org"))
            let answers = await [other, third]
            let owner = try #require(await engine.currentOwnDomainInfo()?.domain)

            #expect(answers == [.done(message: ShareText.OwnDomain.connectSteps("other.com")), .done(message: ShareText.OwnDomain.connectSteps("example.org"))])
            #expect(["other.com", "example.org"].contains(owner))
            #expect(await eventually { await engine.currentOwnDomainInfo()?.state == .connecting(loginPage: Self.loginPage) })

            try await Task.sleep(for: .milliseconds(300))

            #expect(lines(of: fixture.calls).filter { $0.hasSuffix(" login") }.count == 2)
        }
    }

    @Test func aCancelDuringTheCallThatMakesTheTunnelDeletesThatTunnel() async throws {
        let fixture = try await fixture()
        try authorize(fixture)
        fixture.cloudflare.set { $0.createDelay = .seconds(1) }

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { !fixture.cloudflare.current.tunnels.isEmpty })

            _ = await fixture.engine.handle(.cancelOwnDomain)

            #expect(fixture.cloudflare.current.tunnels.isEmpty)
            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(fixture.keys.keys.isEmpty)
        }
    }

    @Test func theStopOfNexusdWaitsForTheCleanupOfASetup() async throws {
        let fixture = try await fixture()
        try authorize(fixture)
        fixture.cloudflare.set { fake in
            fake.tokenDelay = .seconds(5)
            fake.deleteDelay = .milliseconds(500)
        }

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { !fixture.cloudflare.current.tunnels.isEmpty })

            await fixture.engine.shutdown()

            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(fixture.keys.keys.isEmpty)
        }
    }

    @Test func aCancelWhileTheSetupWaitsForTheStateWritesNoDomainAndDeletesTheTunnel() async throws {
        let fixture = try await fixture()
        let engine = fixture.engine
        let gate = TestGate()
        try authorize(fixture)
        fixture.cloudflare.set { $0.tokenDelay = .milliseconds(500) }

        try await run(fixture) {
            _ = await engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { !fixture.cloudflare.current.tunnels.isEmpty })

            let hold = Task { try await engine.stateStore.update { _ in gate.blockUntilOpen() } }
            #expect(await eventually { gate.reached })
            #expect(await eventually { fixture.keys.keys[.tunnel] != nil })

            let cancel = Task { await engine.cancelOwnDomain() }
            try await Task.sleep(for: .milliseconds(300))
            gate.open()
            try await hold.value
            _ = await cancel.value

            #expect(await engine.stateStore.current().ownDomain == nil)
            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(fixture.keys.keys.isEmpty)
        }
    }

    // MARK: The links

    @Test func twoStartsAtTheSameTimeDoNotGetTheSameLabel() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true)
        let engine = fixture.engine

        try await run(fixture) {
            async let shop = engine.handle(.startShare(ShareStart(host: "shop.test", address: .ownDomain, label: "web")))
            async let blog = engine.handle(.startShare(ShareStart(host: "blog.test", address: .ownDomain, label: "web")))
            let answers = await [shop, blog]
            let refusals = ["blog.test", "shop.test"].map { ShareText.OwnDomain.labelInUse(host: $0, address: "web.example.com") }
            let failures = answers.compactMap { answer -> String? in
                guard case .failure(let message) = answer else {
                    return nil
                }

                return message
            }

            #expect(failures.count == 1)
            #expect(failures.allSatisfy(refusals.contains))
            #expect(await engine.stateStore.current().ownDomain?.labels.values.filter { $0 == "web" }.count == 1)
        }
    }

    @Test func twoStartsAtTheSameTimeWithTheSameDefaultLabelBothOpenWithTheNextFreeLabel() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "shop.blog.test"], connected: true)
        let engine = fixture.engine

        try await run(fixture) {
            async let shop = engine.handle(.startShare(ShareStart(host: "shop.test", address: .ownDomain)))
            async let other = engine.handle(.startShare(ShareStart(host: "shop.blog.test", address: .ownDomain)))
            let answers = await [shop, other]
            let state = await engine.stateStore.current()
            let opened = answers.filter { answer in
                guard case .share = answer else {
                    return false
                }

                return true
            }

            #expect(opened.count == 2)
            #expect(Set(state.shares.compactMap(\.label)) == ["shop", "shop-2"])
            #expect(Set(state.shares.compactMap(\.publicHost)) == ["shop.example.com", "shop-2.example.com"])
        }
    }

    @Test func aFailedRecordEndsTheStartAtOnceAndStopsTheBuild() async throws {
        let fixture = try await fixture(connected: true)
        let shop = fixture.root.appending(path: "shop.test", directoryHint: .isDirectory)
        let hold = fixture.root.appending(path: "hold")
        let script = fixture.root.appending(path: "build.sh")
        try Self.viteProject(at: shop)
        try Data().write(to: hold)
        try Self.writeProgram(Self.heldBuild(root: fixture.root), to: script)
        await fixture.engine.useShareBuild { _ in "/bin/sh '\(script.path(percentEncoded: false))'" }
        fixture.cloudflare.set { $0.failure = .failed(status: 500, message: "Internal error") }

        try await run(fixture) {
            let release = Task {
                try await Task.sleep(for: .seconds(8))
                try FileManager.default.removeItem(at: hold)
            }

            let begin = ContinuousClock.now
            let answer = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test", viteMode: .build, address: .ownDomain)))
            let elapsed = ContinuousClock.now - begin
            release.cancel()

            #expect(answer == .failure(message: ShareText.OwnDomain.recordNotAdded("shop.example.com", log: fixture.paths.ownDomainTunnelLog.path(percentEncoded: false))))
            #expect(elapsed < .seconds(5))
            #expect(await eventually { Self.buildRuns(root: fixture.root) == false })
        }
    }

    @Test func anOwnDomainLinkAndAQuickLinkAtTheSameTimeGetOtherPorts() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true)
        let engine = fixture.engine

        try await run(fixture) {
            async let own = engine.handle(.startShare(ShareStart(host: "shop.test", address: .ownDomain)))
            async let quick = engine.handle(.startShare(ShareStart(host: "blog.test", address: .random)))
            _ = await [own, quick]

            let state = await engine.stateStore.current()
            let shop = try #require(state.shares.first { $0.host == "shop.test" })
            let blog = try #require(state.shares.first { $0.host == "blog.test" })
            let ports = [shop.port, blog.port, blog.metricsPort ?? 0, state.ownDomain?.metricsPort ?? 0]

            #expect(shop.state == .open)
            #expect(blog.state == .open)
            #expect(Set(ports).count == 4)
        }
    }

    @Test func anOwnDomainLinkAddsItsRecordAndRunsOneTunnelWithItsRule() async throws {
        let fixture = try await fixture(connected: true)

        try await run(fixture) {
            guard case .share(let info) = await open(fixture) else {
                Issue.record("The link did not open.")
                return
            }

            let active = try #require(await record(fixture))
            let tunnel = try #require(await fixture.engine.currentOwnDomainTunnel())
            let state = await fixture.engine.stateStore.current()
            #expect(await eventually { lines(of: fixture.environment).count == 1 })
            let environment = lines(of: fixture.environment).last ?? ""
            let marker = await fixture.engine.processMarkerValue

            #expect(info.url == "https://shop.example.com")
            #expect(info.log == fixture.paths.ownDomainTunnelLog.path(percentEncoded: false))
            #expect(active.publicHost == "shop.example.com")
            #expect(active.label == "shop")
            #expect(active.metricsPort == nil)
            #expect(await fixture.engine.quickLinkPrograms() == 0)
            #expect(tunnel.rules == ["shop.example.com": active.port])
            #expect(fixture.cloudflare.current.records == [CloudflareDNSRecord(id: "record-2", type: "CNAME", name: "shop.example.com", content: "tunnel-1.cfargotunnel.com")])
            #expect(fixture.cloudflare.current.puts == [["shop.example.com": active.port]])
            #expect(state.ownDomain?.labels == ["shop.test": "shop"])
            #expect(state.ownDomain?.dnsRecords == ["shop.example.com"])
            #expect(state.ownDomain?.metricsPort == tunnel.metricsPort)
            #expect(runCalls(fixture) == ["tunnel --no-autoupdate --config \(fixture.paths.ownDomainConfig.path(percentEncoded: false)) --metrics 127.0.0.1:\(tunnel.metricsPort) run"])
            #expect(environment == "\(fixture.paths.cloudflaredHome.path(percentEncoded: false))|token|\(marker)")
            #expect(try String(contentsOf: fixture.paths.ownDomainConfig, encoding: .utf8) == CloudflaredConfig.remoteTunnelFile)
            #expect(lines(of: fixture.activity).contains { $0.hasSuffix(ShareText.OwnDomain.addedRecordLine(host: "shop.test", domain: "example.com")) })
        }
    }

    @Test func aLabelThatExistsAtCloudflareStopsTheLinkAndKeepsTheRecord() async throws {
        let fixture = try await fixture(connected: true)
        let users = CloudflareDNSRecord(id: "user-1", type: "A", name: "shop.example.com", content: "203.0.113.7")
        fixture.cloudflare.set { $0.records = [users] }

        try await run(fixture) {
            let answer = await open(fixture)

            #expect(answer == .failure(message: ShareText.OwnDomain.recordExists("shop.example.com")))
            #expect(fixture.cloudflare.current.records == [users])
            #expect(await fixture.engine.stateStore.current().ownDomain?.dnsRecords == [])
            #expect(runCalls(fixture).isEmpty)
        }
    }

    @Test func aLabelOfAnotherSiteIsRefusedAndALabelOfAGoneSiteMoves() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true) { state in
            state.ownDomain?.labels = ["blog.test": "shop", "old.test": "cms"]
        }

        try await run(fixture) {
            let taken = await open(fixture, label: "shop")
            let moved = await open(fixture, label: "cms")

            #expect(taken == .failure(message: ShareText.OwnDomain.labelInUse(host: "blog.test", address: "shop.example.com")))
            #expect(await record(fixture)?.publicHost == "cms.example.com")
            #expect(await fixture.engine.stateStore.current().ownDomain?.labels == ["blog.test": "shop", "shop.test": "cms"])

            guard case .share = moved else {
                Issue.record("The link did not open: \(moved)")
                return
            }
        }
    }

    @Test func aSecondLinkGetsOneNewListOfRulesAndNoSecondProgram() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true)

        try await run(fixture) {
            _ = await open(fixture)
            let first = try #require(await fixture.engine.currentOwnDomainTunnel())
            _ = await open(fixture, host: "blog.test")
            let second = try #require(await fixture.engine.currentOwnDomainTunnel())
            let shop = try #require(await record(fixture))
            let blog = try #require(await record(fixture, host: "blog.test"))

            #expect(second.processID == first.processID)
            #expect(second.rules == ["shop.example.com": shop.port, "blog.example.com": blog.port])
            #expect(fixture.cloudflare.current.puts.count == 2)
            #expect(await eventually { runCalls(fixture).count == 1 })

            _ = await fixture.engine.handle(.stopShare(host: "blog.test"))
            #expect(await eventually { await fixture.engine.currentOwnDomainTunnel()?.rules == ["shop.example.com": shop.port] })
            let afterStop = try #require(await fixture.engine.currentOwnDomainTunnel())

            #expect(afterStop.processID == first.processID)
            #expect(fixture.cloudflare.current.puts.last == ["shop.example.com": shop.port])
            #expect(await record(fixture)?.state == .open)

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))

            #expect(await eventually { await fixture.engine.currentOwnDomainTunnel() == nil })
            #expect(await eventually { await fixture.processes.state(of: first.processID)?.isActive != true })
        }
    }

    @Test func theStopOfALinkDoesNotWaitForTheNewRules() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true)

        try await run(fixture) {
            _ = await open(fixture)
            _ = await open(fixture, host: "blog.test")
            fixture.cloudflare.set { $0.appliedVersion = $0.version }
            let begin = ContinuousClock.now

            let answer = await fixture.engine.handle(.stopShare(host: "blog.test"))

            #expect(ContinuousClock.now - begin < .milliseconds(800))
            #expect(answer == .done(message: ShareText.linkStopped("blog.test")))
            #expect(await record(fixture, host: "blog.test")?.state == .ended(.stopped))
            #expect(await eventually { lines(of: fixture.activity).contains { $0.contains("Nexus did not change the addresses of the tunnel") } })
        }
    }

    @Test func twoEndsWhileTheQueueIsBusyGiveOneJobForTheNewRules() async throws {
        let hosts = ["shop.test", "blog.test", "cms.test"]
        let fixture = try await fixture(hosts: hosts, connected: true)
        let engine = fixture.engine
        let gate = TestGate()
        let failures = { lines(of: fixture.activity).filter { $0.contains(ShareText.OwnDomain.rulesNotChangedLine(Self.tunnelName, reason: "")) }.count }

        try await run(fixture) {
            for host in hosts {
                _ = await open(fixture, host: host)
            }

            fixture.cloudflare.set { $0.failure = .failed(status: 500, message: "Internal error") }
            let busy = Task { try await engine.serialOwnDomain { await gate.waitUntilOpen() } }
            #expect(await eventually { gate.reached })

            _ = await engine.handle(.stopShare(host: "blog.test"))
            _ = await engine.handle(.stopShare(host: "cms.test"))
            gate.open()
            try await busy.value

            #expect(await eventually { failures() == 1 })

            try await Task.sleep(for: .milliseconds(500))

            #expect(failures() == 1)
        }
    }

    @Test func aCancelOfAWaitThrowsAndTheEndOfTheLimitGivesNil() async throws {
        let fixture = try await fixture()
        let engine = fixture.engine

        try await run(fixture) {
            let wait = Task { try await engine.waitFor(limit: .seconds(5), every: .milliseconds(20)) { () -> Bool? in nil } }
            wait.cancel()
            let limit = try await engine.waitFor(limit: .milliseconds(100), every: .milliseconds(20)) { () -> Bool? in nil }

            await #expect(throws: CancellationError.self) { try await wait.value }
            #expect(limit == nil)
        }
    }

    @Test func aTunnelThatDoesNotTakeTheNewRulesKeepsItsOldRules() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true)

        try await run(fixture) {
            _ = await open(fixture)
            let first = try #require(await fixture.engine.currentOwnDomainTunnel())
            fixture.cloudflare.set { $0.appliedVersion = $0.version }

            let answer = await open(fixture, host: "blog.test")

            #expect(answer == .failure(message: ShareText.OwnDomain.rulesNotChanged(Self.tunnelName, log: fixture.paths.ownDomainTunnelLog.path(percentEncoded: false))))
            #expect(await fixture.engine.currentOwnDomainTunnel()?.rules == first.rules)
            #expect(await record(fixture)?.state == .open)
        }
    }

    @Test func theChecksOfTheQuickLinksDoNotAskTheTunnelOfTheOwnDomain() async throws {
        let fixture = try await fixture(connected: true)

        try await run(fixture) {
            _ = await open(fixture)
            fixture.answers.set { $0.askedPorts = []; $0.ready = false; $0.resolves = false }

            await fixture.engine.checkShares(now: .now.addingTimeInterval(61))
            await fixture.engine.sharesAfterWake(at: .now.addingTimeInterval(-700))

            #expect(fixture.answers.current.askedPorts.isEmpty)
            #expect(await record(fixture)?.state == .open)
        }
    }

    @Test func aFailedTunnelEndsEachOwnDomainLinkWithItsLog() async throws {
        let fixture = try await fixture(connected: true)

        try await run(fixture) {
            _ = await open(fixture)
            let tunnel = try #require(await fixture.engine.currentOwnDomainTunnel())
            let pid = try #require(await fixture.processes.state(of: tunnel.processID)?.pid)
            try Data().write(to: fixture.root.appending(path: "failrun"))

            kill(pid, SIGKILL)

            #expect(await eventually { await record(fixture)?.state == .ended(.failed(ShareText.cloudflaredStopped(log: fixture.paths.ownDomainTunnelLog.path(percentEncoded: false)))) })
            #expect(await fixture.engine.currentOwnDomainTunnel() == nil)
        }
    }

    // MARK: A new start of nexusd

    @Test func aNewStartOfNexusdKeepsTheOpenLinkAndStartsTheTunnelWithItsRule() async throws {
        let fixture = try await fixture(connected: true)
        var second: NexusEngine?

        try await run(fixture) {
            _ = await open(fixture)
            let before = try #require(await record(fixture))
            #expect(await eventually { runCalls(fixture).count == 1 })
            await fixture.engine.shutdown()

            let restarted = await engine(root: fixture.root, processes: ProcessSupervisor(), answers: fixture.answers, cloudflare: fixture.cloudflare, keys: fixture.keys, loginLimit: .seconds(10))
            second = restarted
            await restarted.endSharesOfEarlierRun()
            _ = await restarted.handle(.start(service: ServiceCatalog.nginxID))
            await restarted.resumeOwnDomainLinks()
            let after = await restarted.stateStore.current().shares.first { $0.host == "shop.test" }

            #expect(after == before)
            #expect(await restarted.currentOwnDomainTunnel()?.rules == ["shop.example.com": before.port])
            #expect(await eventually { runCalls(fixture).count == 2 })
        }

        await second?.shutdown()
    }

    @Test func aNewStartOfNexusdEndsALinkThatStartedAndALinkWithoutTheDomain() async throws {
        let options = ShareOptions(duration: .untilStopped, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .ownDomain)
        let starting = ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: options, mode: .localHost, label: "shop", publicHost: "shop.example.com", port: 18_400, started: .now, state: .starting(.openLink))
        let open = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "blog.test", site: "blog.test", options: options, mode: .localHost, label: "blog", publicHost: "blog.example.com", port: 18_401, started: .now, state: .open)
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"]) { state in
            state.shares = [starting, open]
        }

        try await run(fixture) {
            await fixture.engine.resumeOwnDomainLinks()

            #expect(await record(fixture)?.state == .ended(.nexusdStopped))
            #expect(await record(fixture, host: "blog.test")?.state == .ended(.failed(ShareText.ownDomainMissing)))
        }
    }

    @Test func aNewStartOfNexusdChecksTheBlocksWithOneLimitBeforeAnyRules() async throws {
        let options = ShareOptions(duration: .untilStopped, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .ownDomain)
        let starting = ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: options, mode: .localHost, label: "shop", publicHost: "shop.example.com", port: 18_400, started: .now, state: .starting(.openLink))
        let blog = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "blog.test", site: "blog.test", options: options, mode: .localHost, label: "blog", publicHost: "blog.example.com", port: 18_401, started: .now, state: .open)
        let docs = ShareRecord(id: "00112233445566778899aabbccddeeff", host: "docs.test", site: "docs.test", options: options, mode: .localHost, label: "docs", publicHost: "docs.example.com", port: 18_402, started: .now, state: .open)
        let fixture = try await fixture(hosts: ["shop.test", "blog.test", "docs.test"], connected: true) { state in
            state.shares = [starting, blog, docs]
        }

        try await run(fixture) {
            await fixture.engine.useShareBlockAnswers { _ in false }
            let begin = ContinuousClock.now

            await fixture.engine.resumeOwnDomainLinks()

            #expect(ContinuousClock.now - begin < .milliseconds(1_800))
            #expect(await record(fixture, host: "blog.test")?.state == .ended(.failed(ShareText.portNotOpen(18_401))))
            #expect(await record(fixture, host: "docs.test")?.state == .ended(.failed(ShareText.portNotOpen(18_402))))
            #expect(fixture.cloudflare.current.puts.isEmpty)
            #expect(runCalls(fixture).isEmpty)
        }
    }

    // MARK: Disconnect

    @Test func disconnectEndsTheLinksAndDeletesOnlyTheRecordsAndTheTunnelOfNexus() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "blog.test"], connected: true) { state in
            state.shareDefaults.address = .ownDomain
        }

        try await run(fixture) {
            _ = await open(fixture)
            _ = await open(fixture, host: "blog.test")
            fixture.cloudflare.set { fake in
                fake.records = fake.records.map { record in
                    record.name == "blog.example.com" ? CloudflareDNSRecord(id: record.id, type: "CNAME", name: record.name, content: "example.netlify.app") : record
                }
            }

            let answer = await fixture.engine.handle(.disconnectOwnDomain)
            let state = await fixture.engine.stateStore.current()

            #expect(answer == .ownDomainRemoval(OwnDomainRemoval(removedRecords: ["shop.example.com"], keptRecords: ["blog.example.com"])))
            #expect(await record(fixture)?.state == .ended(.stopped))
            #expect(await record(fixture, host: "blog.test")?.state == .ended(.stopped))
            #expect(fixture.cloudflare.current.records.map(\.name) == ["blog.example.com"])
            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(fixture.keys.keys.isEmpty)
            #expect(state.ownDomain == nil)
            #expect(state.shareDefaults.address == .random)
            #expect(await fixture.engine.currentOwnDomainTunnel() == nil)
            #expect(lines(of: fixture.activity).contains { $0.hasSuffix(ShareText.OwnDomain.removedLine("example.com", tunnel: Self.tunnelName, keptRecords: 1)) })
        }
    }

    @Test func aRecordThatALinkAddsDuringDisconnectDoesNotStayAtCloudflare() async throws {
        let fixture = try await fixture(connected: true)
        let engine = fixture.engine
        fixture.cloudflare.set { $0.holdsRecords = true }

        try await run(fixture) {
            let start = Task { await engine.handle(.startShare(ShareStart(host: "shop.test", address: .ownDomain))) }
            #expect(await eventually { fixture.cloudflare.current.recordsCalls == 1 })

            let disconnect = Task { await engine.handle(.disconnectOwnDomain) }
            #expect(await eventually { await record(fixture)?.state == .ended(.stopped) })

            fixture.cloudflare.set { $0.holdsRecords = false }
            _ = await start.value
            _ = await disconnect.value

            #expect(fixture.cloudflare.current.records.isEmpty)
            #expect(await engine.stateStore.current().ownDomain == nil)
        }
    }

    @Test func disconnectAfterARevokedKeyForgetsTheDomainAndNamesWhatStays() async throws {
        let fixture = try await fixture(connected: true) { state in
            state.ownDomain?.dnsRecords = ["shop.example.com"]
        }

        try await run(fixture) {
            fixture.cloudflare.set { $0.failure = .refused }

            let answer = await fixture.engine.handle(.disconnectOwnDomain)

            #expect(answer == .ownDomainRemoval(OwnDomainRemoval(removedRecords: [], keptRecords: ["shop.example.com"], keptTunnel: Self.tunnelName)))
            #expect(await fixture.engine.stateStore.current().ownDomain == nil)
            #expect(fixture.keys.keys.isEmpty)
            #expect(lines(of: fixture.activity).contains { $0.hasSuffix(ShareText.OwnDomain.removedWithTunnelLine("example.com", tunnel: Self.tunnelName, keptRecords: 1)) })
        }
    }

    @Test func disconnectAsksAtMostFourNamesAtATimeAndStartsNoNameAfterARefusedKey() async throws {
        let names = (1...8).map { "site\($0).example.com" }
        let fixture = try await fixture(connected: true) { state in
            state.ownDomain?.dnsRecords = names
        }

        try await run(fixture) {
            fixture.cloudflare.set { $0.failure = .refused }

            let answer = await fixture.engine.handle(.disconnectOwnDomain)

            #expect(answer == .ownDomainRemoval(OwnDomainRemoval(removedRecords: [], keptRecords: names, keptTunnel: Self.tunnelName)))
            #expect(fixture.cloudflare.current.recordsCalls == 4)
            #expect(await fixture.engine.stateStore.current().ownDomain == nil)
        }
    }

    @Test func disconnectWithoutANetworkKeepsTheDomain() async throws {
        let fixture = try await fixture(connected: true) { state in
            state.ownDomain?.dnsRecords = ["shop.example.com"]
        }

        try await run(fixture) {
            fixture.cloudflare.set { $0.failure = .noAnswer }

            let answer = await fixture.engine.handle(.disconnectOwnDomain)

            #expect(answer == .failure(message: ShareText.OwnDomain.noAnswerAtDisconnect))
            #expect(await fixture.engine.stateStore.current().ownDomain?.dnsRecords == ["shop.example.com"])
            #expect(fixture.keys.keys.count == 2)
        }
    }

    @Test func noSecretReachesAFileOfNexus() async throws {
        let fixture = try await fixture()
        try Data().write(to: fixture.authorize)

        try await run(fixture) {
            _ = await fixture.engine.handle(.connectOwnDomain(domain: "example.com"))
            #expect(await eventually { await fixture.engine.stateStore.current().ownDomain != nil })
            _ = await open(fixture)
            _ = await fixture.engine.handle(.disconnectOwnDomain)

            let files = [fixture.activity, fixture.paths.errorLog, fixture.paths.ownDomainTunnelLog, fixture.paths.config.appending(path: "state.json")]
            let texts = files.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")

            #expect(!texts.isEmpty)
            #expect(!texts.contains("secret-token"))
            #expect(!texts.contains("token-of-tunnel"))
            #expect(!texts.contains("secret-callback"))
        }
    }

    // MARK: The preview and the removal of Nexus

    @Test func thePreviewNamesTheDomainAndTheLabelOnlyWithADomain() async throws {
        let connected = try await fixture(connected: true) { $0.shareDefaults.address = .ownDomain }

        try await run(connected) {
            guard case .sharePreview(let preview) = await connected.engine.handle(.sharePreview(host: "shop.test")) else {
                Issue.record("No preview")
                return
            }

            #expect(preview.ownDomain == "example.com")
            #expect(preview.label == "shop")
            #expect(preview.defaults.address == .ownDomain)
        }

        let alone = try await fixture { $0.shareDefaults.address = .ownDomain }

        try await run(alone) {
            guard case .sharePreview(let preview) = await alone.engine.handle(.sharePreview(host: "shop.test")) else {
                Issue.record("No preview")
                return
            }

            #expect(preview.ownDomain == nil)
            #expect(preview.label == nil)
            #expect(preview.defaults.address == .random)
        }
    }

    @Test func theRemovalOfNexusDisconnectsTheDomainFirstAndStopsWhenThatFails() async throws {
        let fixture = try await fixture(connected: true)
        let resolver = fixture.root.appending(path: "etc/resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(SystemDNSFiles.resolverContents(port: 10053).utf8).write(to: resolver)

        try await run(fixture) {
            let before = base.helper.requests
            fixture.cloudflare.set { $0.failure = .noAnswer }
            let stopped = await fixture.engine.handle(.uninstall)

            #expect(stopped == .failure(message: ShareText.OwnDomain.uninstallStopped("example.com", reason: ShareText.OwnDomain.noAnswerAtDisconnect)))
            #expect(base.helper.requests == before)
            #expect(FileManager.default.fileExists(atPath: resolver.path(percentEncoded: false)))
            #expect(await fixture.engine.stateStore.current().ownDomain != nil)

            fixture.cloudflare.set { $0.failure = nil }
            let removed = await fixture.engine.handle(.uninstall)

            guard case .done(let message) = removed else {
                Issue.record("The removal did not end: \(removed)")
                return
            }

            #expect(message.contains(ShareText.OwnDomain.uninstallItem("example.com")))
            #expect(message.contains(ShareText.OwnDomain.removeKey))
            #expect(fixture.cloudflare.current.deletedTunnels == ["tunnel-1"])
            #expect(base.helper.requests.contains(.removeResolver(tld: "test")))
        }
    }
}
