import Foundation

public struct NexusPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: NexusPaths {
        NexusPaths(root: .applicationSupportDirectory.appending(path: "Nexus", directoryHint: .isDirectory))
    }

    public var runtimes: URL { folder("runtimes") }
    public var config: URL { folder("config") }
    public var data: URL { folder("data") }
    public var run: URL { folder("run") }
    public var logs: URL { folder("logs") }
    public var certs: URL { folder("certs") }
    public var trash: URL { folder("trash") }
    public var bin: URL { folder("bin") }

    public var allFolders: [URL] {
        [runtimes, config, data, run, logs, certs, trash, bin]
    }

    public func runtime(_ name: String, line: String) -> URL {
        runtimes
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: line, directoryHint: .isDirectory)
    }

    public var runtimeStaging: URL {
        runtimes.appending(path: ".staging", directoryHint: .isDirectory)
    }

    public func dataFolder(service: String, line: String) -> URL {
        data.appending(path: "\(service)-\(line)", directoryHint: .isDirectory)
    }

    public func log(_ name: String) -> URL {
        logs.appending(path: "\(name).log", directoryHint: .notDirectory)
    }

    public func createFolders(using fileManager: FileManager = .default) throws {
        for folder in allFolders {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func folder(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}
