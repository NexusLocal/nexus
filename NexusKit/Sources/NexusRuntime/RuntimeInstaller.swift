import Foundation
import NexusCore
import NexusSupervisor
import Synchronization

// The bytes of a download so far. The size is nil when the server does not give it.
public struct DownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let expected: Int64?

    public init(received: Int64, expected: Int64?) {
        self.received = received
        self.expected = expected
    }
}

// A cancelled task stops its download and gets a CancellationError.
public protocol PackageDownloader: Sendable {
    func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
}

// A download task of URLSession reports its bytes and stops at once on a cancel. The file of the
// task goes away when the handler returns. So the handler moves it first.
public struct URLSessionDownloader: PackageDownloader {
    public init() {}

    public func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let transfer = Transfer()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    continuation.resume(with: Result { try Self.keep(file, response: response, error: error, url: url) })
                }

                let observation = task.observe(\.countOfBytesReceived) { task, _ in
                    let expected = task.countOfBytesExpectedToReceive
                    progress(DownloadProgress(received: task.countOfBytesReceived, expected: expected > 0 ? expected : nil))
                }

                transfer.start(task, observation: observation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private static func keep(_ file: URL?, response: URLResponse?, error: (any Error)?, url: URL) throws -> URL {
        if let error {
            throw (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.httpStatus(http.statusCode, url)
        }

        guard let file else {
            throw RuntimeError.unsupported("The download of \(url.absoluteString) gave no file.")
        }

        let kept = FileManager.default.temporaryDirectory.appending(path: "nexus-download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    // A cancel can come before the task exists. The task then stops as soon as it starts.
    private final class Transfer: Sendable {
        private let state = Mutex<(task: URLSessionDownloadTask?, observation: NSKeyValueObservation?, cancelled: Bool)>((nil, nil, false))

        func start(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) {
            let cancelled = state.withLock { state in
                state.task = task
                state.observation = observation
                return state.cancelled
            }

            task.resume()

            if cancelled {
                task.cancel()
            }
        }

        func cancel() {
            let task = state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
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

// A runtime that is checked and unpacked in its staging folder, but not in place yet.
public struct PreparedRuntime: Sendable {
    public let runtime: InstalledRuntime
    let staging: URL
}

// Installs each runtime into runtimes/<name>/<line>, so a patch update replaces the folder that
// the configuration files point to. prepare(_:progress:) checks and unpacks the package in a
// staging folder. So a failed or stopped install never leaves a half-written runtime. A stop can
// come until commit(_:) starts. After that the install finishes.
public actor RuntimeInstaller {
    private let paths: NexusPaths
    private let downloader: any PackageDownloader
    private let fileManager = FileManager.default

    public init(paths: NexusPaths, downloader: any PackageDownloader = URLSessionDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    public func prepare(_ package: ManifestPackage, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> PreparedRuntime {
        let download = try await downloader.download(package.url, progress: progress)
        defer { try? fileManager.removeItem(at: download) }

        try Task.checkCancellation()

        let actual = try FileChecksum.sha256(of: download)
        guard actual == package.sha256.lowercased() else {
            throw RuntimeError.checksumMismatch(expected: package.sha256, actual: actual)
        }

        let staging = paths.runtimeStaging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            try await unpack(download, format: package.format, into: staging)

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
            try Task.checkCancellation()

            return PreparedRuntime(runtime: runtime, staging: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    @discardableResult
    public func commit(_ prepared: PreparedRuntime) throws -> InstalledRuntime {
        defer { discard(prepared) }

        try replace(prepared.runtime.folder, with: prepared.staging)
        return prepared.runtime
    }

    public func discard(_ prepared: PreparedRuntime) {
        try? fileManager.removeItem(at: prepared.staging)
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

    private func unpack(_ archive: URL, format: ManifestPackage.Format, into folder: URL) async throws {
        switch format {
        case .tarXZ:
            let tar = Command(executable: URL(filePath: "/usr/bin/tar"), arguments: ["-xf", archive.path(percentEncoded: false), "-C", folder.path(percentEncoded: false), "--strip-components", "1"])

            do {
                try await CommandRunner.run(tar)
            } catch CommandError.failed(_, _, let output) {
                throw RuntimeError.unpackFailed(output)
            }
        case .phar:
            try fileManager.copyItem(at: archive, to: folder.appending(path: "composer.phar"))
        }
    }

    private func replace(_ destination: URL, with staging: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // When the new folder cannot move into place, the old folder goes back. So the service
        // that ran before the update can start again.
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let old = paths.runtimeStaging.appending(path: "old-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.moveItem(at: destination, to: old)

            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.moveItem(at: old, to: destination)
                throw error
            }

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
}
