import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusTestSupport
import NexusTLS
import Synchronization
import Testing
@testable import NexusEngine

// The install and the update of cloudflared before a link (group 4, 4a).
extension NexusEngineTests {
    private func cloudflaredPaths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
    }

    private func cloudflaredBinary(_ root: URL) -> URL {
        cloudflaredPaths(root).runtime("cloudflared", line: "1").appending(path: "bin/cloudflared")
    }

    private func fakeCloudflared(version: String, in root: URL) throws -> ManifestPackage {
        let source = root.appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bin = source.appending(path: "cloudflared-\(version)/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = bin.appending(path: "cloudflared")
        try Data("#!/bin/sh\necho \"cloudflared version \(version)\"\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false))

        let archive = root.appending(path: "cloudflared-\(version)-\(UUID().uuidString).tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", source.path(percentEncoded: false), "cloudflared-\(version)"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "cloudflared", version: version, line: "1", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ, license: "Apache-2.0")
    }

    private func makeCloudflaredEngine(root: URL, manifest: CountingManifest, downloader: any PackageDownloader = CopyDownloader(), state: EngineState = EngineState(), activity: ActivityLog? = nil) throws -> NexusEngine {
        let paths = cloudflaredPaths(root)
        try paths.createFolders()
        var state = state
        state.ports[NexusEngine.dnsServiceID] = state.ports[NexusEngine.dnsServiceID] ?? freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        return NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: downloader,
            manifestSource: manifest,
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero,
            activity: activity
        )
    }

    private func cloudflaredLines(of file: URL, _ activity: ActivityLog) throws -> [String] {
        activity.waitForWrites()

        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return []
        }

        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { line in String(line.drop { $0 != " " }.dropFirst()) }
    }

    private func shareRecord(_ host: String, state: ShareState) -> ShareRecord {
        ShareRecord(id: UUID().uuidString, host: host, site: host, options: .standard, mode: .localHost, started: .now, state: state)
    }

    @Test func aFirstLinkInstallsCloudflaredFromTheManifest() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, activity: activity)
        let downloads = CallCount()

        try await whileRunning(engine) {
            let binary = try await engine.prepareCloudflared { downloads.add() }

            #expect(binary == cloudflaredBinary(root))
            #expect(FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)))
            #expect(downloads.count == 1)
            #expect(await engine.usableCloudflared()?.version == "2026.11.0")
            #expect(try cloudflaredLines(of: logFile, activity) == ["nexusd share: Nexus downloads cloudflared 2026.11.0 before a link opens."])
        }
    }

    @Test func theSameBuildNeedsNoDownloadAndNoSecondReadInOneHour() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let downloader = CountingDownloader()
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, downloader: downloader)
        let downloads = CallCount()

        try await whileRunning(engine) {
            _ = try await engine.prepareCloudflared {}
            let binary = try await engine.prepareCloudflared { downloads.add() }

            #expect(binary == cloudflaredBinary(root))
            #expect(downloads.count == 0)
            #expect(downloader.count == 1)
            #expect(manifest.reads == 1)
        }
    }

    @Test func aNewBuildUpdatesCloudflaredAfterOneHour() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, activity: activity)
        let downloads = CallCount()

        try await whileRunning(engine) {
            _ = try await engine.prepareCloudflared {}
            manifest.offer([try fakeCloudflared(version: "2026.11.1", in: root)])

            _ = try await engine.prepareCloudflared { downloads.add() }

            #expect(await engine.usableCloudflared()?.version == "2026.11.0")
            #expect(manifest.reads == 1)
            #expect(downloads.count == 0)

            await engine.ageManifestRead(by: 3_601)
            let binary = try await engine.prepareCloudflared { downloads.add() }

            #expect(binary == cloudflaredBinary(root))
            #expect(await engine.usableCloudflared()?.version == "2026.11.1")
            #expect(manifest.reads == 2)
            #expect(downloads.count == 1)
            #expect(try cloudflaredLines(of: logFile, activity).last == "nexusd share: Nexus updates cloudflared 2026.11.0 to 2026.11.1 before a link opens.")
        }
    }

    @Test func anUpdateThatFailsKeepsTheInstalledBuild() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, activity: activity)
        let good = try fakeCloudflared(version: "2026.11.1", in: root)
        let broken = ManifestPackage(name: good.name, version: good.version, line: good.line, revision: good.revision, url: good.url, sha256: String(repeating: "0", count: 64), format: .tarXZ)

        try await whileRunning(engine) {
            _ = try await engine.prepareCloudflared {}
            manifest.offer([broken])
            await engine.ageManifestRead(by: 3_601)

            let binary = try await engine.prepareCloudflared {}
            let last = try #require(try cloudflaredLines(of: logFile, activity).last)

            #expect(binary == cloudflaredBinary(root))
            #expect(FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)))
            #expect(await engine.usableCloudflared()?.version == "2026.11.0")
            #expect(last.hasPrefix("nexusd share: Nexus did not update cloudflared 2026.11.0 to 2026.11.1. The link uses 2026.11.0. The download has the SHA-256 "))
        }
    }

    @Test func aManifestThatFailsUsesTheInstalledBuildOrRefusesTheLink() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logFile = root.appending(path: "activity.log")
        let activity = ActivityLog(file: logFile, source: "nexusd")
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let installed = try makeCloudflaredEngine(root: root.appending(path: "installed"), manifest: manifest, activity: activity)
        let empty = try makeCloudflaredEngine(root: root.appending(path: "empty"), manifest: CountingManifest(nil))

        try await whileRunning(installed) {
            _ = try await installed.prepareCloudflared {}
            manifest.offer(nil)
            await installed.ageManifestRead(by: 3_601)

            let binary = try await installed.prepareCloudflared {}
            let last = try #require(try cloudflaredLines(of: logFile, activity).last)

            #expect(binary == cloudflaredBinary(root.appending(path: "installed")))
            #expect(last.hasPrefix("nexusd share: Nexus cannot read the package list. The link uses cloudflared 2026.11.0. The download of "))
        }

        try await whileRunning(empty) {
            let error = await #expect(throws: RuntimeError.self) {
                try await empty.prepareCloudflared {}
            }

            #expect(error?.description.hasPrefix("Nexus cannot download cloudflared, the program that makes the public links. Check that this Mac is online. The download of ") == true)
        }
    }

    @Test func aManifestWithoutCloudflaredRefusesOnlyWithoutAnInstall() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let installed = try makeCloudflaredEngine(root: root.appending(path: "installed"), manifest: manifest)
        let empty = try makeCloudflaredEngine(root: root.appending(path: "empty"), manifest: CountingManifest([]))

        try await whileRunning(installed) {
            _ = try await installed.prepareCloudflared {}
            manifest.offer([])
            await installed.ageManifestRead(by: 3_601)

            #expect(try await installed.prepareCloudflared {} == cloudflaredBinary(root.appending(path: "installed")))
        }

        try await whileRunning(empty) {
            let error = await #expect(throws: RuntimeError.self) {
                try await empty.prepareCloudflared {}
            }

            #expect(error == .unsupported(ShareText.Cloudflared.notInPackageList))
        }
    }

    @Test func aFolderWithoutItsBinaryGetsANewInstall() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let downloader = CountingDownloader()
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, downloader: downloader)
        let downloads = CallCount()

        try await whileRunning(engine) {
            _ = try await engine.prepareCloudflared {}
            try FileManager.default.removeItem(at: cloudflaredBinary(root))

            let binary = try await engine.prepareCloudflared { downloads.add() }

            #expect(binary == cloudflaredBinary(root))
            #expect(FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)))
            #expect(downloads.count == 1)
            #expect(downloader.count == 2)
        }
    }

    @Test func twoLinksShareOneDownload() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let downloader = CountingDownloader()
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, downloader: downloader)
        let downloads = CallCount()

        try await whileRunning(engine) {
            async let first = engine.prepareCloudflared { downloads.add() }
            async let second = engine.prepareCloudflared { downloads.add() }
            let binaries = try await [first, second]

            #expect(binaries == [cloudflaredBinary(root), cloudflaredBinary(root)])
            #expect(downloads.count == 2)
            #expect(downloader.count == 1)
        }
    }

    @Test func theBinaryIsAlwaysTheOneOfNexus() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeCloudflaredEngine(root: root, manifest: CountingManifest(nil))

        try await whileRunning(engine) {
            await #expect(throws: RuntimeError.self) {
                try await engine.prepareCloudflared {}
            }

            #expect(await engine.usableCloudflared() == nil)
        }
    }

    @Test func aLinkShowsTheStepOfTheDownloadOnlyWhileItStarts() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let starting = shareRecord("shop.test", state: .starting(.openLink))
        let ended = shareRecord("blog.test", state: .ended(.stopped))
        var state = EngineState()
        state.shares = [starting, ended]
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest, state: state)
        try await whileRunning(engine) {
            let firstStep = await engine.firstCloudflaredStep()
            _ = try await engine.prepareCloudflared(forShare: ended.id)
            try FileManager.default.removeItem(at: cloudflaredBinary(root))

            let binary = try await engine.prepareCloudflared(forShare: starting.id)

            let shares = await engine.stateStore.current().shares

            #expect(firstStep == .downloadCloudflared)
            #expect(shares.map(\.state) == [.starting(.downloadCloudflared), .ended(.stopped)])
            #expect(await engine.firstCloudflaredStep() == .openLink)
            #expect(binary == cloudflaredBinary(root))
        }
    }

    @Test func removeRefusesWhileALinkUsesCloudflared() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CountingManifest([try fakeCloudflared(version: "2026.11.0", in: root)])
        let engine = try makeCloudflaredEngine(root: root, manifest: manifest)
        let refusal = NexusResponse.failure(message: ShareText.Cloudflared.inUse(host: "shop.test"))
        let open = shareRecord("shop.test", state: .open)
        let starting = shareRecord("shop.test", state: .starting(.downloadCloudflared))
        let ended = shareRecord("shop.test", state: .ended(.stopped))

        try await whileRunning(engine) {
            _ = try await engine.prepareCloudflared {}

            try await engine.stateStore.update { $0.shares = [open] }
            let whileOpen = await engine.handle(.remove(name: "cloudflared", line: "1"))

            try await engine.stateStore.update { $0.shares = [starting] }
            let whileStarting = await engine.handle(.remove(name: "cloudflared", line: "1"))
            let keptFolder = exists(cloudflaredBinary(root))

            try await engine.stateStore.update { $0.shares = [ended] }
            let afterTheEnd = await engine.handle(.remove(name: "cloudflared", line: "1"))

            #expect(whileOpen == refusal)
            #expect(whileStarting == refusal)
            #expect(keptFolder)
            #expect(afterTheEnd == .done(message: "cloudflared 1 is removed."))
            #expect(!exists(cloudflaredPaths(root).runtime("cloudflared", line: "1")))
        }
    }
}

private final class CountingManifest: ManifestSource {
    private let state: Mutex<(packages: [ManifestPackage]?, reads: Int)>

    init(_ packages: [ManifestPackage]?) {
        state = Mutex((packages, 0))
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    func offer(_ packages: [ManifestPackage]?) {
        state.withLock { $0.packages = packages }
    }

    func manifest(from url: URL) async throws -> Manifest {
        let packages = state.withLock { state in
            state.reads += 1
            return state.packages
        }

        guard let packages else {
            throw RuntimeError.httpStatus(503, url)
        }

        return Manifest(schema: 1, generated: .now, repository: "test", packages: packages)
    }
}

private final class CountingDownloader: PackageDownloader {
    private let downloads = Mutex(0)

    var count: Int {
        downloads.withLock { $0 }
    }

    func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        downloads.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(300))
        return try await CopyDownloader().download(url, progress: progress)
    }
}

private final class CallCount: Sendable {
    private let calls = Mutex(0)

    var count: Int {
        calls.withLock { $0 }
    }

    func add() {
        calls.withLock { $0 += 1 }
    }
}

private extension NexusEngine {
    func ageManifestRead(by seconds: TimeInterval) {
        lastManifest?.read.addTimeInterval(-seconds)
    }
}
