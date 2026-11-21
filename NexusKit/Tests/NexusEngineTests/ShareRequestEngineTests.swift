import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusDumps
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

@Suite(.serialized)
struct ShareRequestEngineTests {
    private let base = NexusEngineTests()
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"
    private static let build = (version: "2026.11.0", revision: 1, sha256: "fake-cloudflared")
    private static let first = String(repeating: "4f2c0d9e", count: 4)
    private static let second = String(repeating: "5a6b7c8d", count: 4)

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
    }

    private static func fakeCloudflared() -> String {
        """
        #!/bin/sh
        exec /bin/sleep 600

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

    private func engine(root: URL, answers: FakeLinkAnswers) async -> NexusEngine {
        let paths = Self.paths(root)
        let engine = NexusEngine(
            paths: paths,
            helper: base.helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: base.keyStore),
            processSupervisor: ProcessSupervisor(),
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

    private func fixture(change: (inout EngineState) -> Void = { _ in }) async throws -> Fixture {
        let root = shortTemporaryRoot()
        let paths = Self.paths(root)
        try paths.createFolders()
        let httpPort = base.freePort()
        var state = EngineState()

        state.ports[ServiceCatalog.httpPortKey] = httpPort
        state.ports[ServiceCatalog.httpsPortKey] = base.freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()

        for host in ["shop.test", "blog.test"] {
            let folder = root.appending(path: host, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.sites.append(Site(host: host, folder: folder, php: "8.4"))
        }

        change(&state)
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        try Self.install("nginx", line: "1.30", version: "1.30.0", in: paths)
        try Self.writeProgram(Self.fakeNginx(httpPort: httpPort), to: paths.runtime("nginx", line: "1.30").appending(path: "sbin/nginx"))
        try Self.writeProgram("", to: paths.runtime("nginx", line: "1.30").appending(path: "modules/ngx_http_js_module.so"))
        try Self.install("cloudflared", line: "1", version: Self.build.version, revision: Self.build.revision, sha256: Self.build.sha256, in: paths)
        try Self.writeProgram(Self.fakeCloudflared(), to: paths.runtime("cloudflared", line: "1").appending(path: "bin/cloudflared"))

        let answers = FakeLinkAnswers()
        let engine = await engine(root: root, answers: answers)
        let started = await engine.handle(.start(service: ServiceCatalog.nginxID))

        guard case .done = started else {
            await engine.shutdown()
            throw RuntimeError.unsupported("The fake nginx did not start: \(started)")
        }

        await engine.startDumpReceiver()
        return Fixture(root: root, paths: paths, engine: engine, answers: answers)
    }

    private func run(_ fixture: Fixture, _ steps: () async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await base.whileRunning(fixture.engine, steps)
    }

    private func open(_ fixture: Fixture, keepsRequests: Bool = true) async -> ShareInfo? {
        guard case .share(let info) = await fixture.engine.handle(.startShare(ShareStart(host: "shop.test", keepsRequests: keepsRequests))) else {
            return nil
        }

        return info
    }

    private func record(_ fixture: Fixture, host: String = "shop.test") async -> ShareRecord? {
        await fixture.engine.stateStore.current().shares.first { $0.host == host }
    }

    private func info(_ fixture: Fixture) async -> ShareInfo? {
        await fixture.engine.shareInfos().first { $0.host == "shop.test" }
    }

    private func dumpList(_ fixture: Fixture) async -> DumpList? {
        guard case .dumpList(let list) = await fixture.engine.handle(.dumpList(place: nil)) else {
            return nil
        }

        return list
    }

    private func requests(_ fixture: Fixture) async -> [DumpedRequest] {
        await dumpList(fixture)?.requests ?? []
    }

    private func line(_ id: String, method: String = "POST", uri: String = "/webhooks/stripe", contentType: String = "application/json", body: String? = #"{"id":"evt_1Q"}"#) -> String {
        let object: [String: Any] = [
            "time": Date.now.timeIntervalSince1970,
            "request": id,
            "status": 200,
            "visitor": "3.18.12.63",
            "method": method,
            "uri": uri,
            "host": Self.publicHost,
            "duration": 0.184,
            "size": 34,
            "contentType": contentType,
            "requestHeaders": [["Host", Self.publicHost], ["Cookie", "hidden"]],
            "responseHeaders": [["Content-Type", contentType]],
            "body": body.map { Data($0.utf8).base64EncodedString() } ?? NSNull(),
            "bodyBytes": body.map { $0.utf8.count } ?? NSNull(),
        ]

        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private func append(_ lines: [String], to file: URL) throws {
        try writeAtEnd(lines.map { "\($0)\n" }.joined(), of: file)
    }

    private func dump(_ id: String) -> DumpEvent {
        let envelope = DumpEnvelope(id: id, kind: .http, method: "POST", url: "https://shop.test/webhooks/stripe", host: "shop.test", started: .now)
        return .dump(request: envelope, dump: CaughtDump(requestID: id, seq: 1, time: .now, kind: .dump, text: "\"payment_intent.succeeded\""))
    }

    private func lines(of file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func aLinkWithTheListWritesItsRequestLogOnlyForTheUserAndShowsItsHost() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let info = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            let log = fixture.paths.shareRequestLog(record.id)
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)
            let mode = try FileManager.default.attributesOfItem(atPath: log.path(percentEncoded: false))[.posixPermissions] as? Int

            #expect(info.requestCount == 0)
            #expect(config.contains("access_log \"\(log.path(percentEncoded: false))\" nexus_share_requests if=$nexus_share_request_logged;"))
            #expect(config.contains("js_import nexus_requests from \"\(fixture.paths.shareRequestScript.path(percentEncoded: false))\";"))
            #expect(mode == 0o600)
            #expect(try String(contentsOf: fixture.paths.shareRequestScript, encoding: .utf8) == ShareRequests.script)
            #expect(await dumpList(fixture)?.linkHosts == ["shop.test"])
        }
    }

    @Test func theLinesOfTheLogBecomeRequestsOfTheSiteWithTheirDetailAndADumpOfPHPJoins() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            try append([line(Self.first), line(Self.second), line("c3", method: "GET", uri: "/build/app.css", contentType: "text/css", body: nil)], to: fixture.paths.shareRequestLog(record.id))

            let arrived = await eventually { await requests(fixture).count == 2 }
            let listed = await requests(fixture)
            let detail = await fixture.engine.handle(.shareRequest(id: Self.first))

            #expect(arrived)
            #expect(Set(listed.map(\.id)) == [Self.first, Self.second])
            #expect(listed.allSatisfy { $0.publicLink?.host == "shop.test" && $0.site == "shop.test" })
            #expect(listed.first?.url == "https://\(Self.publicHost)/webhooks/stripe")
            #expect(await info(fixture)?.requestCount == 2)

            guard case .shareRequest(let found) = detail else {
                Issue.record("no detail: \(detail)")
                return
            }

            #expect(found.requestBody == #"{"id":"evt_1Q"}"#)
            #expect(found.requestHeaders.contains(ShareHeader(name: "Cookie", value: "hidden")))

            await fixture.engine.dumpStore.add(dump(Self.first))
            let joined = await eventually { await requests(fixture).first { $0.id == Self.first }?.dumpCount == 1 }

            #expect(joined)
            #expect(await requests(fixture).count == 2)
        }
    }

    @Test func theStopRemovesTheRequestsWithoutEntriesAndKeepsTheOthersWithoutTheLink() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            let log = fixture.paths.shareRequestLog(record.id)
            try append([line(Self.first), line(Self.second)], to: log)
            _ = await eventually { await requests(fixture).count == 2 }
            await fixture.engine.dumpStore.add(dump(Self.first))
            _ = await eventually { await requests(fixture).first { $0.id == Self.first }?.dumpCount == 1 }

            _ = await fixture.engine.handle(.stopShare(host: "shop.test"))
            let listed = await requests(fixture)

            #expect(listed.map(\.id) == [Self.first])
            #expect(listed.first?.publicLink == nil)
            #expect(await dumpList(fixture)?.linkHosts == [])
            #expect(await fixture.engine.handle(.shareRequest(id: Self.first)) == .failure(message: LinkRequestText.detailGone))
            #expect(!exists(log))
            #expect(await info(fixture)?.requestCount == nil)
        }
    }

    @Test func aClearOfTheLinkRemovesItsRequests() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            try append([line(Self.first), line(Self.second)], to: fixture.paths.shareRequestLog(record.id))
            _ = await eventually { await requests(fixture).count == 2 }

            let cleared = await fixture.engine.handle(.clearLinkRequests(host: "shop.test"))
            let again = await fixture.engine.handle(.clearLinkRequests(host: "shop.test"))

            #expect(cleared == .done(message: "Nexus removed 2 requests."))
            #expect(again == .done(message: "The list has no requests to remove."))
            #expect(await requests(fixture).isEmpty)
            #expect(await fixture.engine.handle(.shareRequest(id: Self.first)) == .failure(message: LinkRequestText.detailGone))
            #expect(await dumpList(fixture)?.linkHosts == ["shop.test"])
        }
    }

    @Test func aLinkWithoutTheListKeepsNoRequests() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            let info = try #require(await open(fixture, keepsRequests: false))
            let record = try #require(await record(fixture))
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            #expect(info.requestCount == nil)
            #expect(!config.contains("nexus_share_requests"))
            #expect(!exists(fixture.paths.shareRequestLog(record.id)))
            #expect(await dumpList(fixture)?.linkHosts == [])
        }
    }

    @Test func aNewStartOfNexusdForgetsTheListOfEachLink() async throws {
        let own = ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "blog.test", site: "blog.test", options: ShareOptions(duration: .untilStopped, password: false, hidesErrors: true, viteMode: .live, keepsRequests: true, address: .ownDomain), mode: .localHost, label: "blog", port: 18_500, started: .now, state: .open)
        let fixture = try await fixture()
        var restarted: NexusEngine?

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            try append([line(Self.first)], to: fixture.paths.shareRequestLog(record.id))
            _ = await eventually { await requests(fixture).count == 1 }
            await fixture.engine.dumpStore.add(dump(Self.first))
            _ = await eventually { await requests(fixture).first?.dumpCount == 1 }
            try await fixture.engine.stateStore.update { $0.shares.append(own) }
            try Data((line(Self.second) + "\n").utf8).write(to: fixture.paths.shareRequestLog(own.id))
            await fixture.engine.dumpStore.waitForWrites()
            await fixture.engine.shutdown()

            let second = await engine(root: fixture.root, answers: fixture.answers)
            restarted = second
            await second.endSharesOfEarlierRun()
            await second.forgetLinkRequestsOfEarlierRun()
            await second.startDumpReceiver()
            let listed = await second.dumpStore.list()

            #expect(listed.map(\.id) == [Self.first])
            #expect(listed.allSatisfy { $0.publicLink == nil })
            #expect(!exists(fixture.paths.shareRequestLog(record.id)))
            #expect(lines(of: fixture.paths.shareRequestLog(own.id)).isEmpty)
            #expect(await second.linkListHosts == ["blog.test"])
        }

        await restarted?.shutdown()
    }

    @Test func theRequestsOfABusyLinkGoOutWithTheDumpChangesAndNotWithTheSiteList() async throws {
        let fixture = try await fixture()

        try await run(fixture) {
            _ = try #require(await open(fixture))
            let record = try #require(await record(fixture))
            let log = fixture.paths.shareRequestLog(record.id)
            let siteLists = EventRecorder<Bool> { event in
                guard case .sites = event else {
                    return nil
                }

                return true
            }
            let changed = EventRecorder<[String]> { event in
                guard case .dumpChanges(let change) = event else {
                    return nil
                }

                return change.changed.filter { $0.publicLink?.host == "shop.test" }.map(\.id)
            }
            let events = await fixture.engine.events()
            let changes = await fixture.engine.events()

            siteLists.record(events)
            changed.record(changes)
            try await Task.sleep(for: .milliseconds(200))
            let before = siteLists.all.count

            for batch in 0..<5 {
                try append((0..<10).map { index in line("r\(batch)-\(index)") }, to: log)
                try await Task.sleep(for: .milliseconds(100))
            }

            let all = await eventually { await fixture.engine.dumpStore.linkRequestCount(host: "shop.test") == 50 }
            let sent = await eventually { Set(changed.all.flatMap { $0 }).count == 50 }

            #expect(all)
            #expect(sent)
            #expect(siteLists.all.count - before <= 1)
        }
    }
}
