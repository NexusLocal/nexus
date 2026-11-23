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

// Counts the downloads of each URL and copies the file.
private final class DownloadsByURL: PackageDownloader, Sendable {
    private let counts = Mutex<[URL: Int]>([:])

    func downloads(of url: URL) -> Int {
        counts.withLock { $0[url] ?? 0 }
    }

    func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        counts.withLock { $0[url, default: 0] += 1 }
        try await Task.sleep(for: .milliseconds(100))

        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

// The MongoDB tools belong to each MongoDB (owner, 2026-11-23).
extension NexusEngineTests {
    private func fakePackage(_ name: String, line: String, binary: String, in root: URL) throws -> ManifestPackage {
        let source = root.appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bin = source.appending(path: "\(name)-\(line)/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appending(path: binary)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))

        let archive = root.appending(path: "\(name)-\(line)-\(UUID().uuidString).tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", source.path(percentEncoded: false), "\(name)-\(line)"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: name, version: "\(line).1", line: line, revision: 1, url: archive, sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    @Test func eachMongoDBGetsTheToolsAndTwoInstallsShareOneDownloadOfThem() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        let server7 = try fakePackage("mongodb", line: "7.0", binary: "mongod", in: root)
        let server8 = try fakePackage("mongodb", line: "8.0", binary: "mongod", in: root)
        let tools = try fakePackage(MongoDBToolsPackage.name, line: MongoDBToolsPackage.line, binary: "mongodump", in: root)
        let downloader = DownloadsByURL()

        var state = EngineState()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: downloader,
            manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [server7, server8, tools])),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero
        )

        try await whileRunning(engine) {
            async let first = engine.handle(.install(name: "mongodb", line: "7.0"))
            async let second = engine.handle(.install(name: "mongodb", line: "8.0"))
            let installs = await [first, second]

            let refused = await engine.handle(.remove(name: MongoDBToolsPackage.name, line: MongoDBToolsPackage.line))
            _ = await engine.handle(.remove(name: "mongodb", line: "7.0"))
            let toolsAfterOne = await engine.installer.installed(name: MongoDBToolsPackage.name, line: MongoDBToolsPackage.line)
            _ = await engine.handle(.remove(name: "mongodb", line: "8.0"))
            let toolsAfterAll = await engine.installer.installed(name: MongoDBToolsPackage.name, line: MongoDBToolsPackage.line)

            for install in installs {
                guard case .done(let message) = install else {
                    Issue.record("an install failed: \(install)")
                    continue
                }

                #expect(!message.contains("did not install"))
            }

            #expect(downloader.downloads(of: tools.url) == 1)

            guard case .failure(let message) = refused else {
                Issue.record("the tools were removed with a MongoDB: \(refused)")
                return
            }

            #expect(message.contains("needs the MongoDB tools"))
            #expect(toolsAfterOne != nil)
            #expect(toolsAfterAll == nil)
        }
    }

    @Test func aMongoDBStaysWhenItsToolsDoNotInstall() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        let server = try fakePackage("mongodb", line: "8.0", binary: "mongod", in: root)

        var state = EngineState()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: CopyDownloader(),
            manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [server])),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero
        )

        try await whileRunning(engine) {
            let installed = await engine.handle(.install(name: "mongodb", line: "8.0"))

            guard case .done(let message) = installed else {
                Issue.record("the install failed: \(installed)")
                return
            }

            #expect(message.contains("The MongoDB tools did not install"))
            #expect(await engine.installer.installed(name: "mongodb", line: "8.0") != nil)
        }
    }
}
