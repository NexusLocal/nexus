import Foundation

// The filters of the Logs screen (group 7). The screen, the web page and nexus logs use the same
// rules. Debug is off by default, as in the design.
public struct LogQuery: Codable, Sendable, Equatable {
    public var levels: Set<LogLevelGroup>
    public var hidesTestRuns: Bool
    // The hash of each hidden message, with a short text for its chip.
    public var hiddenMessages: [UInt64: String]
    public var groupsEqualEntries: Bool
    public var search: String
    // nil shows all files of the place.
    public var fileID: String?

    public init(levels: Set<LogLevelGroup> = [.error, .warning, .info], hidesTestRuns: Bool = true, hiddenMessages: [UInt64: String] = [:], groupsEqualEntries: Bool = true, search: String = "", fileID: String? = nil) {
        self.levels = levels
        self.hidesTestRuns = hidesTestRuns
        self.hiddenMessages = hiddenMessages
        self.groupsEqualEntries = groupsEqualEntries
        self.search = search
        self.fileID = fileID
    }

    public var searchText: String? {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// One row of the list: an entry, or the newest entry of a group of equal entries.
public struct LogRow: Sendable, Identifiable, Equatable {
    public let fileID: String
    public let entry: LogIndex.Entry
    public let count: Int
    // The time of the oldest entry of the group.
    public let firstDate: Double?

    public var id: String {
        "\(fileID)#\(entry.offset)"
    }

    public var group: LogLevelGroup {
        LogLevelGroup.of(level: entry.level)
    }
}

public struct LogResult: Sendable, Equatable {
    public let rows: [LogRow]
    // The groups (or entries) after the filters. rows holds the newest of them.
    public let rowCount: Int
    // The entries after the filters.
    public let matching: Int
    public let total: Int
    // The count of each level with all filters except the level filter.
    public let levelCounts: [LogLevelGroup: Int]
    public let hiddenTestRuns: Int
    public let hiddenByMessage: [UInt64: Int]

    public static let empty = LogResult(rows: [], rowCount: 0, matching: 0, total: 0, levelCounts: [:], hiddenTestRuns: 0, hiddenByMessage: [:])
}

public enum LogBrowser {
    // searchHits holds the offsets of the entries with the search text for each file. nil when
    // there is no search.
    public static func result(of snapshots: [LogIndex.Snapshot], query: LogQuery, searchHits: [String: Set<UInt64>]?, limit: Int) -> LogResult {
        var candidates: [(fileID: String, entry: LogIndex.Entry, order: Int)] = []
        var levelCounts: [LogLevelGroup: Int] = [:]
        var hiddenTestRuns = 0
        var hiddenByMessage: [UInt64: Int] = [:]
        var total = 0
        var order = 0

        for snapshot in snapshots where query.fileID == nil || query.fileID == snapshot.file.id {
            let hits = searchHits.map { $0[snapshot.file.id] ?? [] }

            snapshot.forEach { entry in
                total += 1
                order += 1

                if let hits, !hits.contains(entry.offset) {
                    return
                }

                if query.hidesTestRuns, entry.isTestRun {
                    hiddenTestRuns += 1
                    return
                }

                if query.hiddenMessages[entry.hash] != nil {
                    hiddenByMessage[entry.hash, default: 0] += 1
                    return
                }

                let group = LogLevelGroup.of(level: entry.level)
                levelCounts[group, default: 0] += 1

                guard query.levels.contains(group) else {
                    return
                }

                candidates.append((snapshot.file.id, entry, order))
            }
        }

        candidates.sort { left, right in
            left.entry.sortDate != right.entry.sortDate ? left.entry.sortDate > right.entry.sortDate : left.order > right.order
        }

        var rows: [LogRow] = []
        var rowCount = 0

        if query.groupsEqualEntries {
            var groups: [UInt64: (index: Int, count: Int, first: Double?)] = [:]
            var newest: [(fileID: String, entry: LogIndex.Entry)] = []

            for candidate in candidates {
                if let known = groups[candidate.entry.hash] {
                    groups[candidate.entry.hash] = (known.index, known.count + 1, candidate.entry.date ?? known.first)
                } else {
                    groups[candidate.entry.hash] = (newest.count, 1, candidate.entry.date)
                    newest.append((candidate.fileID, candidate.entry))
                }
            }

            rowCount = newest.count
            rows = newest.prefix(limit).map { item in
                let group = groups[item.entry.hash]!
                return LogRow(fileID: item.fileID, entry: item.entry, count: group.count, firstDate: group.first)
            }
        } else {
            rowCount = candidates.count
            rows = candidates.prefix(limit).map { LogRow(fileID: $0.fileID, entry: $0.entry, count: 1, firstDate: $0.entry.date) }
        }

        return LogResult(rows: rows, rowCount: rowCount, matching: candidates.count, total: total, levelCounts: levelCounts, hiddenTestRuns: hiddenTestRuns, hiddenByMessage: hiddenByMessage)
    }
}
