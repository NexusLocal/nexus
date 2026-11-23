import Foundation
import NexusCore
import NexusIPC

// One entry of a log of an app, for read_log and nexus logs (group 7).
public struct AppLogEntry: Codable, Sendable, Equatable {
    public let time: String?
    public let level: String
    public let channel: String?
    public let file: String
    public let line: Int?
    public let message: String
    public let exception: String?
    public let source: String?
    public let context: [String]

    // One line for a terminal or an agent: the time, the level, the message, the exception with
    // its line of the app, and the short context.
    public var text: String {
        var parts = [[time, level.isEmpty ? nil : level, channel == "testing" ? "(test run)" : nil].compactMap { $0 }.joined(separator: " "), message]

        if let exception {
            parts.append(source.map { "\(exception) at \($0)" } ?? exception)
        } else if let source {
            parts.append("at \(source)")
        }

        parts += context
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// Reads the log files of the app of one site or workspace with the index of the Logs screen. A
// reader keeps its index, so --follow reads only what is new.
public final class AppLogReader: @unchecked Sendable {
    public let place: LogPlace
    public let files: [LogFile]
    private let indices: [LogIndex]
    private var seenEnds: [String: UInt64] = [:]
    static let textLimit = 32 * 1024
    static let messageLength = 600

    // file is a name of the file menu, such as laravel.log or cronjobs/import.log.
    public init(place: LogPlace, paths: NexusPaths, file: String?) throws {
        let all = AppLogFiles.files(of: place, paths: paths).filter { $0.kind == .app || $0.kind == .output || $0.kind == .phpErrors }
        let chosen = file.map { name in all.filter { $0.name == name } } ?? all.filter { $0.kind == .app || $0.kind == .output }

        guard !chosen.isEmpty else {
            let names = all.map(\.name)
            let found = names.isEmpty ? "\(place.id) has no log files of its app." : "The logs of \(place.id) are: \(names.joined(separator: ", "))."
            throw ToolFailure(file.map { "\(place.id) has no log \($0). \(found)" } ?? found)
        }

        let zone = place.kind == .laravel ? LaravelTimeZone.of(project: URL(filePath: place.projectFolder, directoryHint: .isDirectory)) : TimeZone.current
        self.place = place
        files = chosen
        indices = chosen.map { LogIndex(file: $0, zone: $0.kind == .app ? zone : .current) }
    }

    // The newest entries, oldest first. level keeps that level and the more serious ones.
    public func entries(count: Int, level: LogLevelGroup?, containing text: String?) -> [AppLogEntry] {
        for index in indices {
            index.update(quickStart: false)
        }

        let snapshots = indices.map(\.snapshot)

        for snapshot in snapshots {
            seenEnds[snapshot.file.id] = snapshot.bytes
        }

        return rows(of: snapshots, count: count, level: level, containing: text).reversed()
    }

    // The entries after the last call, oldest first. A file that was cleared starts again.
    public func newEntries(level: LogLevelGroup?, containing text: String?) -> [AppLogEntry] {
        var result: [AppLogEntry] = []

        for index in indices {
            if index.update(quickStart: false) == .replaced {
                seenEnds[index.file.id] = 0
            }

            let snapshot = index.snapshot
            let start = seenEnds[index.file.id] ?? 0
            let fresh = snapshot.entries.filter { $0.offset >= start }
            seenEnds[index.file.id] = snapshot.bytes

            guard !fresh.isEmpty else {
                continue
            }

            let partial = LogIndex.Snapshot(file: snapshot.file, closed: fresh, last: nil, isComplete: true, bytes: snapshot.bytes)
            result += rows(of: [partial], count: fresh.count, level: level, containing: text).reversed()
        }

        return result
    }

    private func rows(of snapshots: [LogIndex.Snapshot], count: Int, level: LogLevelGroup?, containing text: String?) -> [AppLogEntry] {
        var hits: [String: Set<UInt64>]?

        if let text {
            var found: [String: Set<UInt64>] = [:]

            for index in indices where snapshots.contains(where: { $0.file.id == index.file.id }) {
                let offsets = Set(snapshots.first { $0.file.id == index.file.id }?.entries.map(\.offset) ?? [])
                found[index.file.id] = (index.search(text) ?? []).intersection(offsets)
            }

            hits = found
        }

        let query = LogQuery(levels: Self.levels(from: level), hidesTestRuns: false, groupsEqualEntries: false)
        let result = LogBrowser.result(of: snapshots, query: query, searchHits: hits, limit: count)

        return result.rows.compactMap { row in
            guard let index = indices.first(where: { $0.file.id == row.fileID }) else {
                return nil
            }

            let text = index.text(of: row.entry, limit: Self.textLimit).text
            let summary = LogEntryParser.summary(of: text, kind: index.file.kind)
            let channel = LogEntryParser.detail(of: String(text.prefix(200)), kind: index.file.kind, isCut: true).channel
            let source = summary.sourceFile.map { "\(LogEntryParser.relative($0, to: place.projectFolder)):\(summary.sourceLine ?? 0)" }
            let message = summary.message.count > Self.messageLength ? "\(summary.message.prefix(Self.messageLength))…" : summary.message

            return AppLogEntry(time: row.entry.date.map(Self.time), level: row.entry.level, channel: channel, file: index.file.name, line: row.entry.line > 0 ? row.entry.line : nil, message: message, exception: summary.exceptionClass, source: source, context: summary.context)
        }
    }

    public static func levels(from level: LogLevelGroup?) -> Set<LogLevelGroup> {
        guard let level else {
            return Set(LogLevelGroup.allCases)
        }

        let order = LogLevelGroup.allCases
        return Set(order.prefix(through: order.firstIndex(of: level) ?? order.count - 1))
    }

    private static func time(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
