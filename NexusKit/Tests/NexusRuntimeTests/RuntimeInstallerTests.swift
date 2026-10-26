import Foundation
import NexusCore
import Testing
@testable import NexusRuntime

struct LocalFileDownloader: PackageDownloader {
    func download(_ url: URL) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

struct RuntimeInstallerTests {
    private let workspace: URL
    private let paths: NexusPaths

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "Nexus Runtime Tests \(UUID().uuidString)", directoryHint: .isDirectory)
        paths = NexusPaths(root: workspace.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
    }

    private func makePackage(version: String, line: String = "1.0", content: String = "hello") throws -> ManifestPackage {
        let source = workspace.appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let top = source.appending(path: "demo-\(version)/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: top.appending(path: "hello"))

        let archive = workspace.appending(path: "demo-\(version)-\(UUID().uuidString).tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", source.path(percentEncoded: false), "demo-\(version)"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(
            name: "demo",
            version: version,
            line: line,
            revision: 1,
            url: archive,
            sha256: try FileChecksum.sha256(of: archive),
            format: .tarXZ
        )
    }

    @Test func checksumOfAKnownFile() throws {
        let file = workspace.appending(path: "abc.txt")
        try Data("abc".utf8).write(to: file)

        #expect(try FileChecksum.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func installUnpacksIntoTheLineFolder() async throws {
        let installer = RuntimeInstaller(paths: paths, downloader: LocalFileDownloader())
        let package = try makePackage(version: "1.0.1")

        let runtime = try await installer.install(package)

        let hello = runtime.folder.appending(path: "bin/hello")
        #expect(runtime.folder == paths.runtime("demo", line: "1.0"))
        #expect(try String(contentsOf: hello, encoding: .utf8) == "hello")
        #expect(await installer.installed(name: "demo", line: "1.0")?.version == "1.0.1")
    }

    @Test func aWrongChecksumInstallsNothing() async throws {
        let installer = RuntimeInstaller(paths: paths, downloader: LocalFileDownloader())
        let good = try makePackage(version: "1.0.1")
        let bad = ManifestPackage(name: good.name, version: good.version, line: good.line, revision: 1,
                                  url: good.url, sha256: String(repeating: "0", count: 64), format: .tarXZ)

        await #expect(throws: RuntimeError.self) {
            try await installer.install(bad)
        }

        #expect(await installer.installed(name: "demo", line: "1.0") == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.runtime("demo", line: "1.0").path(percentEncoded: false)))
    }

    @Test func aPatchUpdateReplacesTheLineFolder() async throws {
        let installer = RuntimeInstaller(paths: paths, downloader: LocalFileDownloader())
        try await installer.install(try makePackage(version: "1.0.1", content: "old"))

        let runtime = try await installer.install(try makePackage(version: "1.0.2", content: "new"))

        #expect(runtime.version == "1.0.2")
        #expect(try String(contentsOf: runtime.folder.appending(path: "bin/hello"), encoding: .utf8) == "new")
        #expect(await installer.installedRuntimes().map(\.version) == ["1.0.2"])
    }

    @Test func removeDeletesTheRuntime() async throws {
        let installer = RuntimeInstaller(paths: paths, downloader: LocalFileDownloader())
        try await installer.install(try makePackage(version: "1.0.1"))

        try await installer.remove(name: "demo", line: "1.0")

        #expect(await installer.installedRuntimes().isEmpty)
    }
}
