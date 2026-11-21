import Darwin
import Foundation
import NexusCore

// A kqueue source for the writes, the delete and the rename of one log file. AccessLogWatch and
// ShareLogWatch use it. The source closes its descriptor when it ends.
enum LogFileSource {
    static func start(_ path: String, queue: DispatchQueue, onEvent: @escaping (any DispatchSourceFileSystemObject) -> Void) -> (source: any DispatchSourceFileSystemObject, descriptor: Int32)? {
        let descriptor = Darwin.open(path, O_EVTONLY)

        guard descriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)

        source.setEventHandler { [weak source] in
            guard let source else {
                return
            }

            onEvent(source)
        }

        source.setCancelHandler {
            close(descriptor)
        }

        source.resume()
        return (source, descriptor)
    }
}

// Each access log of nginx with its owner: the main checkout or a workspace (owner, 2026-11-15).
// nginx keeps a log open and adds a line at the end of each request. FSEvents reports such a line
// only when nginx closes the file. A kqueue source reports each line at once. Each owner gets at most
// one report each second, because one page loads many files.
final class AccessLogWatch: @unchecked Sendable {
    static let reportInterval: TimeInterval = 1

    private struct FileSource {
        let source: any DispatchSourceFileSystemObject
        let file: FileIdentity
    }

    // current watches the file at the path. A delete or a rename takes that file from the path, but
    // nginx writes to it until it opens its logs again. So its source moves to earlier and stays. The
    // first line in the file at the path ends the sources in earlier.
    private struct WatchedLog {
        let owner: String
        var current: FileSource?
        var earlier: [any DispatchSourceFileSystemObject] = []

        func cancel() {
            current?.source.cancel()
            earlier.forEach { $0.cancel() }
        }
    }

    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.access-logs")
    private let onRequest: @Sendable (String) -> Void
    private var logs: [String: WatchedLog] = [:]
    private var lastReports: [String: Date] = [:]

    init(onRequest: @escaping @Sendable (String) -> Void) {
        self.onRequest = onRequest
    }

    // logs maps the path of each access log to its owner. A log that is not there gets an empty file
    // first. nginx then adds its lines to the file that the source watches. An owner that leaves the
    // map loses its last report. So the same name later reports its first line at once.
    func watch(_ logs: [String: String]) {
        queue.sync {
            for (path, entry) in self.logs where logs[path] != entry.owner {
                entry.cancel()
                self.logs[path] = nil
            }

            for (path, owner) in logs {
                if self.logs[path] == nil {
                    self.logs[path] = WatchedLog(owner: owner)
                }

                followFile(at: path)
            }

            let owners = Set(logs.values)
            lastReports = lastReports.filter { owners.contains($0.key) }
        }
    }

    // Each log without a source or with another file at its path gets a source for that file. The
    // idle check of the dev servers calls this every 30 seconds.
    func refresh() {
        queue.sync {
            for path in logs.keys {
                followFile(at: path)
            }
        }
    }

    func stop() {
        queue.sync {
            logs.values.forEach { $0.cancel() }
            logs = [:]
        }
    }

    // The last release can come in a handler on the queue. So this does not wait for the queue.
    deinit {
        logs.values.forEach { $0.cancel() }
    }

    private func followFile(at path: String) {
        guard var entry = logs[path] else {
            return
        }

        if let current = entry.current, FileIdentity(path: path) == current.file {
            return
        }

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let started = startSource(path) else {
            return
        }

        if let current = entry.current {
            entry.earlier.append(current.source)
        }

        entry.current = started
        logs[path] = entry
    }

    private func startSource(_ path: String) -> FileSource? {
        guard let started = LogFileSource.start(path, queue: queue, onEvent: { [weak self] source in self?.handle(source, path: path) }) else {
            return nil
        }

        var info = stat()

        guard fstat(started.descriptor, &info) == 0 else {
            started.source.cancel()
            return nil
        }

        return FileSource(source: started.source, file: FileIdentity(info))
    }

    private func handle(_ source: any DispatchSourceFileSystemObject, path: String) {
        guard var entry = logs[path] else {
            return
        }

        let isCurrent = entry.current?.source === source

        guard isCurrent || entry.earlier.contains(where: { $0 === source }) else {
            return
        }

        let event = source.data
        let hasLine = !event.isDisjoint(with: [.write, .extend])
        let leavesPath = isCurrent && !event.isDisjoint(with: [.delete, .rename])

        if leavesPath {
            entry.earlier.append(source)
            entry.current = nil
        }

        // A line in the file at the path shows that nginx opened its logs again.
        if isCurrent, !leavesPath, hasLine {
            entry.earlier.forEach { $0.cancel() }
            entry.earlier = []
        }

        logs[path] = entry

        guard hasLine else {
            return
        }

        let now = Date.now

        if let last = lastReports[entry.owner], now.timeIntervalSince(last) < Self.reportInterval {
            return
        }

        lastReports[entry.owner] = now
        onRequest(entry.owner)
    }
}
