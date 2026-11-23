import AppKit
import NexusCore
import Observation

// A row of the Logs screen with the parts of its entry that the row shows. dayTitle is set on the
// first row of each day.
nonisolated struct LogRowItem: Identifiable, Equatable, Sendable {
    let row: LogRow
    let file: LogFile
    let summary: LogEntrySummary
    let dayTitle: String?

    var id: String {
        row.id
    }
}

nonisolated struct LogDetailItem: Equatable, Sendable {
    let row: LogRowItem
    let detail: LogEntryDetail
    let text: String
}

// The state of the Logs screen (group 7). The app reads the log files itself, as it reads the logs
// of the services. The index and the search run off the main thread. A newer refresh makes the
// result of an older one go away.
@MainActor
@Observable
final class LogsModel {
    static let rowPage = 1000
    nonisolated static let summaryBytes = 16 * 1024
    nonisolated static let detailBytes = 2 * 1024 * 1024
    static let chosenPlaceKey = "logsPlace"

    var places: [LogPlace] = []
    private(set) var placeID: String?
    private(set) var files: [LogFile] = []
    private(set) var query = LogQuery()
    private(set) var result = LogResult.empty
    private(set) var rows: [LogRowItem] = []
    private(set) var openRowID: String?
    private(set) var detail: LogDetailItem?
    // The share of the file that the index has read, while it reads a large file.
    private(set) var countProgress: Double?
    private(set) var isSearching = false
    private(set) var isLoaded = false
    private(set) var rowLimit = rowPage
    private(set) var zones: [String: TimeZone] = [:]

    @ObservationIgnored private var indices: [String: LogIndex] = [:]
    @ObservationIgnored private var watchers: [String: LogTail.Watcher] = [:]
    @ObservationIgnored private var searchHits: [String: Set<UInt64>]?
    @ObservationIgnored private var hiddenByPlace: [String: [UInt64: String]] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var refreshIsPlanned = false
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var fileCheck: Task<Void, Never>?
    @ObservationIgnored private let paths: NexusPaths

    init(paths: NexusPaths = .standard) {
        self.paths = paths
    }

    var place: LogPlace? {
        places.first { $0.id == placeID }
    }

    var chosenFile: LogFile? {
        files.first { $0.id == query.fileID }
    }

    var appFiles: [LogFile] {
        files.filter { $0.kind == .app }
    }

    // MARK: The place and its files

    func setPlaces(_ newPlaces: [LogPlace]) {
        guard newPlaces != places else {
            return
        }

        places = newPlaces

        if placeID == nil || !newPlaces.contains(where: { $0.id == placeID }) {
            let remembered = UserDefaults.standard.string(forKey: Self.chosenPlaceKey)
            let first = newPlaces.first { $0.id == remembered }?.id ?? newPlaces.first?.id
            choosePlace(first)
        } else if isVisible {
            reloadFiles()
        }
    }

    func choosePlace(_ id: String?) {
        guard id != placeID || !isLoaded else {
            return
        }

        if let placeID {
            hiddenByPlace[placeID] = query.hiddenMessages
        }

        placeID = id
        UserDefaults.standard.set(id, forKey: Self.chosenPlaceKey)
        query.fileID = nil
        query.hiddenMessages = id.flatMap { hiddenByPlace[$0] } ?? [:]
        query.search = ""
        searchHits = nil
        openRowID = nil
        detail = nil
        rows = []
        result = .empty
        rowLimit = Self.rowPage
        indices = [:]
        stopWatching()
        files = []
        isLoaded = false

        if isVisible {
            reloadFiles()
        }
    }

    // The file to show when the files of the place load, such as the output of a Node.js app.
    func preferFile(_ id: String?) {
        guard let id else {
            return
        }

        query.fileID = id

        if isVisible {
            chooseFile(id)
        }
    }

    func appeared() {
        isVisible = true
        reloadFiles()

        // A new daily file of Laravel or a new debug.log comes without a change of a known file.
        fileCheck?.cancel()
        fileCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.reloadFilesIfChanged()
            }
        }
    }

    func disappeared() {
        isVisible = false
        fileCheck?.cancel()
        fileCheck = nil
        stopWatching()
    }

    private func reloadFilesIfChanged() {
        guard isVisible, let place else {
            return
        }

        let found = AppLogFiles.files(of: place, paths: paths)

        if found.map(\.id) != files.map(\.id) {
            reloadFiles()
        }
    }

    private func reloadFiles() {
        guard let place else {
            files = []
            isLoaded = true
            return
        }

        files = AppLogFiles.files(of: place, paths: paths)

        if let fileID = query.fileID, !files.contains(where: { $0.id == fileID }) {
            query.fileID = nil
        }

        let laravelZone = place.appLogZone
        var kept: [String: LogIndex] = [:]
        var newZones: [String: TimeZone] = [:]

        for file in files {
            let zone = file.kind == .app ? laravelZone : TimeZone.current
            newZones[file.id] = zone
            kept[file.id] = indices[file.id] ?? LogIndex(file: file, zone: zone)
        }

        zones = newZones
        indices = kept
        watch()
        refresh()
    }

    // MARK: Live

    private func watch() {
        let wanted = Set(files.map(\.id))

        for id in watchers.keys where !wanted.contains(id) {
            watchers[id]?.cancel()
            watchers[id] = nil
        }

        guard isVisible else {
            return
        }

        for file in files where watchers[file.id] == nil {
            watchers[file.id] = LogTail.Watcher(file: URL(filePath: file.path)) { [weak self] in
                Task { @MainActor in
                    self?.planRefresh()
                }
            }
        }
    }

    private func stopWatching() {
        for watcher in watchers.values {
            watcher.cancel()
        }

        watchers = [:]
    }

    // Many writes in a short time give one refresh. A search reads the files again, so it waits
    // longer.
    private func planRefresh() {
        guard !refreshIsPlanned else {
            return
        }

        refreshIsPlanned = true

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.query.searchText == nil ? 300 : 1500))

            guard let self else {
                return
            }

            refreshIsPlanned = false

            if query.searchText != nil {
                runSearch()
            } else {
                refresh()
            }
        }
    }

    // MARK: The result

    func refresh() {
        generation += 1
        let token = generation
        let indices = Array(indices.values)
        let files = files
        let query = query
        let hits = searchHits
        let limit = rowLimit

        Task.detached(priority: .userInitiated) {
            for index in indices {
                index.update()
            }

            let output = Self.compute(indices: indices, files: files, query: query, hits: hits, limit: limit)

            await MainActor.run { [weak self] in
                guard let self, token == generation else {
                    return
                }

                apply(output)
                isLoaded = true
                completeIndicesIfNeeded()
            }
        }
    }

    private nonisolated static func compute(indices: [LogIndex], files: [LogFile], query: LogQuery, hits: [String: Set<UInt64>]?, limit: Int) -> (result: LogResult, rows: [LogRowItem]) {
        let snapshots = files.compactMap { file in indices.first { $0.file.id == file.id }?.snapshot }
        let result = LogBrowser.result(of: snapshots, query: query, searchHits: hits, limit: limit)
        var summaries: [String: LogEntrySummary] = [:]

        for index in indices {
            let rows = result.rows.filter { $0.fileID == index.file.id }

            guard !rows.isEmpty else {
                continue
            }

            let texts = index.texts(of: rows.map(\.entry), limit: summaryBytes)

            for (row, text) in zip(rows, texts) {
                summaries[row.id] = LogEntryParser.summary(of: text, kind: index.file.kind)
            }
        }

        var lastDay: String?
        let items = result.rows.compactMap { row -> LogRowItem? in
            guard let file = files.first(where: { $0.id == row.fileID }) else {
                return nil
            }

            let day = LogTimeText.dayTitle(of: row.entry.date ?? row.sortDate)
            let title = day == lastDay ? nil : day
            lastDay = day
            return LogRowItem(row: row, file: file, summary: summaries[row.id] ?? LogEntrySummary(message: ""), dayTitle: title)
        }

        return (result, items)
    }

    private func apply(_ output: (result: LogResult, rows: [LogRowItem])) {
        result = output.result

        if rows != output.rows {
            rows = output.rows
        }

        if openRowID == nil || !rows.contains(where: { $0.id == openRowID }) {
            open(rows.first?.id)
        }
    }

    // A large file first shows its end. Then the index reads the whole file for the counts.
    private func completeIndicesIfNeeded() {
        let incomplete = indices.values.filter { !$0.isComplete }

        guard !incomplete.isEmpty, countProgress == nil else {
            return
        }

        countProgress = 0

        Task.detached(priority: .utility) {
            for index in incomplete {
                index.update { done in
                    Task { @MainActor [weak self] in
                        if self?.countProgress != nil {
                            self?.countProgress = done
                        }
                    }
                }
            }

            // A search must also read the rest of the file.
            await MainActor.run { [weak self] in
                self?.countProgress = nil

                if self?.query.searchText == nil {
                    self?.refresh()
                } else {
                    self?.runSearch()
                }
            }
        }
    }

    // MARK: Filters

    func chooseFile(_ id: String?) {
        query.fileID = id
        openRowID = nil
        rowLimit = Self.rowPage
        refresh()
    }

    func toggleLevel(_ group: LogLevelGroup) {
        if query.levels.contains(group) {
            query.levels.remove(group)
        } else {
            query.levels.insert(group)
        }

        refresh()
    }

    func setGroupsEqualEntries(_ value: Bool) {
        query.groupsEqualEntries = value
        refresh()
    }

    func setHidesTestRuns(_ value: Bool) {
        query.hidesTestRuns = value
        refresh()
    }

    func hideEntriesLike(_ item: LogRowItem) {
        let message = item.summary.message
        query.hiddenMessages[item.row.entry.hash] = message.count > 40 ? "\(message.prefix(40))…" : message
        refresh()
    }

    func showHidden(_ hash: UInt64) {
        query.hiddenMessages[hash] = nil
        refresh()
    }

    func showOlder() {
        rowLimit += Self.rowPage
        refresh()
    }

    // MARK: Search

    func setSearch(_ text: String) {
        guard text != query.search else {
            return
        }

        query.search = text
        searchGeneration += 1
        let token = searchGeneration

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))

            guard let self, token == searchGeneration else {
                return
            }

            runSearch()
        }
    }

    func findAll(_ value: String) {
        setSearch(value)
    }

    private func runSearch() {
        guard let text = query.searchText else {
            searchHits = nil
            isSearching = false
            refresh()
            return
        }

        searchGeneration += 1
        let token = searchGeneration
        let indices = Array(indices.values)
        isSearching = true

        Task.detached(priority: .userInitiated) {
            var hits: [String: Set<UInt64>] = [:]

            for index in indices {
                index.update()
                let found = index.search(text) {
                    false
                }

                hits[index.file.id] = found ?? []
            }

            await MainActor.run { [weak self] in
                guard let self, token == searchGeneration else {
                    return
                }

                searchHits = hits
                isSearching = false
                refresh()
            }
        }
    }

    // The number of entries with the search text in each file.
    var searchCounts: [(file: LogFile, count: Int)] {
        guard let searchHits else {
            return []
        }

        return files.map { file in (file, searchHits[file.id]?.count ?? 0) }
    }

    // MARK: The open entry

    func open(_ id: String?) {
        openRowID = id
        detailGeneration += 1
        let token = detailGeneration

        guard let item = rows.first(where: { $0.id == id }), let index = indices[item.file.id] else {
            detail = nil
            return
        }

        if detail?.row.id != id {
            detail = nil
        }

        Task.detached(priority: .userInitiated) {
            let read = index.text(of: item.row.entry, limit: Self.detailBytes)
            let parsed = LogEntryParser.detail(of: read.text, kind: item.file.kind, isCut: read.isCut)

            await MainActor.run { [weak self] in
                guard let self, token == detailGeneration else {
                    return
                }

                detail = LogDetailItem(row: item, detail: parsed, text: read.text)
            }
        }
    }

    // MARK: Actions

    // Clear empties the file and keeps it in its place (owner, 2026-11-23). A queue worker can
    // keep the file open.
    func clear(_ file: LogFile) throws {
        let handle = try FileHandle(forWritingTo: URL(filePath: file.path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        ActivityTracker.log.write("logs", "Cleared \(file.path)")
        openRowID = nil
        detail = nil
        refresh()
    }

    func timeZone(of file: LogFile) -> TimeZone {
        zones[file.id] ?? .current
    }
}

// The times of the Logs screen are in the time zone of the Mac (readability, owner 2026-11-23).
nonisolated enum LogTimeText {
    nonisolated(unsafe) private static let day: DateFormatter = formatter("EEEE d MMMM")
    nonisolated(unsafe) private static let dayWithYear: DateFormatter = formatter("EEEE d MMMM yyyy")
    nonisolated(unsafe) private static let time: DateFormatter = formatter("HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // "Today · Monday 23 November", "Yesterday · Sunday 22 November" or "Friday 20 November".
    static func dayTitle(of seconds: Double) -> String {
        let date = date(seconds)
        let calendar = Calendar.current
        let name = calendar.isDate(date, equalTo: .now, toGranularity: .year) ? day.string(from: date) : dayWithYear.string(from: date)

        if calendar.isDateInToday(date) {
            return "Today · \(name)"
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday · \(name)"
        }

        return name
    }

    static func time(_ seconds: Double) -> String {
        time.string(from: date(seconds))
    }

    // "yesterday at 14:18:31" or "on Sunday 13 December at 14:18:31", after "the first".
    static func since(_ seconds: Double) -> String {
        let date = date(seconds)
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "today at \(time.string(from: date))"
        }

        if calendar.isDateInYesterday(date) {
            return "yesterday at \(time.string(from: date))"
        }

        let name = calendar.isDate(date, equalTo: .now, toGranularity: .year) ? day.string(from: date) : dayWithYear.string(from: date)
        return "on \(name) at \(time.string(from: date))"
    }

    // The HH:mm:ss of a time as the log wrote it, also of 2026-11-23T14:18:31.123456+01:00.
    static func clock(in logTime: String) -> String {
        logTime.firstMatch(of: #/\d{2}:\d{2}:\d{2}/#).map { String($0.output) } ?? logTime
    }

    // UTC for the zone of UTC and GMT, else a short name such as CET.
    static func zoneName(_ zone: TimeZone) -> String {
        if zone.secondsFromGMT() == 0, ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(zone.identifier) {
            return "UTC"
        }

        return zone.abbreviation() ?? zone.identifier
    }

    // "Today at 14:18:31" or "Friday 20 November at 14:18:31".
    static func full(_ seconds: Double) -> String {
        let date = date(seconds)
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today at \(time.string(from: date))"
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(time.string(from: date))"
        }

        return "\(dayTitle(of: seconds)) at \(time.string(from: date))"
    }
}
