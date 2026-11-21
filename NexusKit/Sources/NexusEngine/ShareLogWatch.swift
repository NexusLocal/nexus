import Darwin
import Foundation
import NexusCore

// The visitor log of each link (group 4, 4b). nginx adds one JSON line at the end of each request.
// A kqueue source reports each line at once, as in AccessLogWatch. The watch reads from the end of
// its last read. A line without its end waits for the next read. A line that does not decode is
// skipped. A read has no limit of size. So a long line of the request list of 4f also arrives.
// Each line comes with its place in the file. So 4f can read it again when the app asks.
final class ShareLogWatch: @unchecked Sendable {
    // The place of one line in its log, without its line end.
    struct Spot: Sendable, Equatable {
        let offset: UInt64
        let length: Int
    }

    struct Line: Sendable {
        let line: ShareLogLine
        let spot: Spot
    }

    private struct WatchedLog {
        let id: String
        let source: any DispatchSourceFileSystemObject
        var offset: UInt64 = 0
        var rest = Data()
    }

    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.share-logs")
    private let onLines: @Sendable (String, [Line]) -> Void
    private var logs: [String: WatchedLog] = [:]

    init(onLines: @escaping @Sendable (String, [Line]) -> Void) {
        self.onLines = onLines
    }

    // One line of a log at its spot, nil when the file does not hold it anymore.
    static func line(at spot: Spot, in file: URL) -> ShareLogLine? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }

        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: spot.offset)) != nil, let data = try? handle.read(upToCount: spot.length), data.count == spot.length else {
            return nil
        }

        return try? JSONDecoder().decode(ShareLogLine.self, from: data)
    }

    // logs maps the path of each visitor log to the id of its link. A log that is not there gets an
    // empty file first. A log that leaves the map loses its source.
    func watch(_ logs: [String: String]) {
        queue.sync {
            for (path, entry) in self.logs where logs[path] != entry.id {
                entry.source.cancel()
                self.logs[path] = nil
            }

            for (path, id) in logs where self.logs[path] == nil {
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }

                if let source = startSource(path) {
                    self.logs[path] = WatchedLog(id: id, source: source)
                    read(path)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            logs.values.forEach { $0.source.cancel() }
            logs = [:]
        }
    }

    // The last release can come in a handler on the queue. So this does not wait for the queue.
    deinit {
        logs.values.forEach { $0.source.cancel() }
    }

    private func startSource(_ path: String) -> (any DispatchSourceFileSystemObject)? {
        LogFileSource.start(path, queue: queue) { [weak self] source in self?.handle(source, path: path) }?.source
    }

    // A log that goes away gives no more lines. nexusd deletes it at the end of its link.
    private func handle(_ source: any DispatchSourceFileSystemObject, path: String) {
        guard let entry = logs[path], entry.source === source else {
            return
        }

        if !source.data.isDisjoint(with: [.delete, .rename]) {
            source.cancel()
            logs[path] = nil
            return
        }

        read(path)
    }

    private func read(_ path: String) {
        guard var entry = logs[path], let handle = FileHandle(forReadingAtPath: path) else {
            return
        }

        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // A shorter file is a new file. Its read starts at its beginning.
        if size < entry.offset {
            entry.offset = 0
            entry.rest = Data()
        }

        guard size > entry.offset, (try? handle.seek(toOffset: entry.offset)) != nil, let data = try? handle.read(upToCount: Int(size - entry.offset)) else {
            logs[path] = entry
            return
        }

        entry.offset += UInt64(data.count)
        entry.rest.append(data)

        var lines: [Line] = []
        let decoder = JSONDecoder()
        let restOffset = entry.offset - UInt64(entry.rest.count)
        var start = entry.rest.startIndex

        while let end = entry.rest[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if let decoded = try? decoder.decode(ShareLogLine.self, from: entry.rest[start..<end]) {
                lines.append(Line(line: decoded, spot: Spot(offset: restOffset + UInt64(start - entry.rest.startIndex), length: end - start)))
            }

            start = end + 1
        }

        entry.rest.removeSubrange(entry.rest.startIndex..<start)
        logs[path] = entry

        if !lines.isEmpty {
            onLines(entry.id, lines)
        }
    }
}
