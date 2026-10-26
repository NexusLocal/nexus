import Foundation
import NexusCore

public protocol PackageDownloader: Sendable {
    func download(_ url: URL) async throws -> URL
}

public struct URLSessionDownloader: PackageDownloader {
    public init() {}

    public func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.httpStatus(http.statusCode, url)
        }

        return file
    }
}

public enum RuntimeError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int, URL)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .httpStatus(let status, let url):
            "The download of \(url.absoluteString) failed with HTTP status \(status)."
        case .checksumMismatch(let expected, let actual):
            "The download has the SHA-256 \(actual), but the manifest expects \(expected). Nexus did not install it."
        case .unpackFailed(let output):
            "The package could not be unpacked: \(output)"
        case .unsupported(let reason):
            reason
        }
    }
}

// Installs each runtime into runtimes/<name>/<line>, so a patch update replaces the folder that
// the configuration files point to. The package is checked and unpacked in a staging folder
// first, so a failed install never leaves a half-written runtime.
public actor RuntimeInstaller {
    private let paths: NexusPaths
    private let downloader: any PackageDownloader
    private let fileManager = FileManager.default

    public init(paths: NexusPaths, downloader: any PackageDownloader = URLSessionDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    @discardableResult
    public func install(_ package: ManifestPackage) async throws -> InstalledRuntime {
        if let current = installed(name: package.name, line: package.line), current.isSameBuild(as: package) {
            return current
        }

        let download = try await downloader.download(package.url)
        defer { try? fileManager.removeItem(at: download) }

        let actual = try FileChecksum.sha256(of: download)
        guard actual == package.sha256.lowercased() else {
            throw RuntimeError.checksumMismatch(expected: package.sha256, actual: actual)
        }

        let staging = paths.runtimeStaging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try unpack(download, format: package.format, into: staging)

        let runtime = InstalledRuntime(
            name: package.name,
            line: package.line,
            version: package.version,
            revision: package.revision,
            sha256: actual,
            installedAt: .now,
            folder: paths.runtime(package.name, line: package.line)
        )
        try writeMetadata(runtime, into: staging)
        try replace(runtime.folder, with: staging)

        return runtime
    }

    public func installed(name: String, line: String) -> InstalledRuntime? {
        readMetadata(in: paths.runtime(name, line: line))
    }

    public func installedRuntimes() -> [InstalledRuntime] {
        let names = (try? fileManager.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil)) ?? []

        return names
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { name in (try? fileManager.contentsOfDirectory(at: name, includingPropertiesForKeys: nil)) ?? [] }
            .compactMap { readMetadata(in: $0) }
            .sorted { ($0.name, $0.line) < ($1.name, $1.line) }
    }

    public func remove(name: String, line: String) throws {
        let folder = paths.runtime(name, line: line)

        guard fileManager.fileExists(atPath: folder.path(percentEncoded: false)) else {
            return
        }

        try fileManager.removeItem(at: folder)
    }

    private func unpack(_ archive: URL, format: ManifestPackage.Format, into folder: URL) throws {
        switch format {
        case .tarXZ:
            try run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", folder.path(percentEncoded: false), "--strip-components", "1"])
        case .phar:
            try fileManager.copyItem(at: archive, to: folder.appending(path: "composer.phar"))
        }
    }

    private func replace(_ destination: URL, with staging: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let old = paths.runtimeStaging.appending(path: "old-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.moveItem(at: destination, to: old)
            try fileManager.moveItem(at: staging, to: destination)
            try? fileManager.removeItem(at: old)
            return
        }

        try fileManager.moveItem(at: staging, to: destination)
    }

    private func writeMetadata(_ runtime: InstalledRuntime, into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runtime).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
    }

    private func readMetadata(in folder: URL) -> InstalledRuntime? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: folder.appending(path: InstalledRuntime.metadataFileName)),
              var runtime = try? decoder.decode(InstalledRuntime.self, from: data) else {
            return nil
        }

        runtime.folder = folder
        return runtime
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RuntimeError.unpackFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
