import Foundation
import NexusCore
import Synchronization

// The data of the web page of the logs (group 7): the same entries as the Logs screen of the app.
// nexusd keeps the index of each file between two requests. So a poll of the page reads only what
// is new in a file. The page never sends a path. It names a file by its key and an entry by its
// offset. nexusd finds both again in the files of the place.
public final class LogPageStore: Sendable {
    public typealias Opener = @Sendable (String, Int?) async -> Bool

    public static let rowPage = 1000
    static let rowLimit = 100_000
    static let summaryBytes = 16 * 1024
    static let detailBytes = 2 * 1024 * 1024
    // The index of a file that no page read for this time goes.
    static let keptSeconds: TimeInterval = 600
    // The list of the sites costs a run of xcode-select. So a poll uses the list of a short time ago.
    static let placesSeconds: TimeInterval = 5
    static let summaryLimit = 20_000

    // An index and the file and the place that it belongs to.
    struct Opened {
        let place: LogPlace
        let file: LogFile
        let zone: TimeZone
        let key: String
        let index: LogIndex
    }

    private struct Kept {
        let index: LogIndex
        var used: Date
    }

    private struct Search {
        let text: String
        let signature: String
        let hits: Set<UInt64>
    }

    private struct RowText {
        let length: UInt64
        let text: LogPageRowText
    }

    // Each dictionary has the key of an index.
    private struct State {
        var kept: [String: Kept] = [:]
        // The share of the file that the index has read, while it reads a large file.
        var counting: [String: Double] = [:]
        // The texts of the rows by the offset of their entry.
        var rowTexts: [String: [UInt64: RowText]] = [:]
        var searches: [String: Search] = [:]
        var places: (date: Date, places: [LogPlace])?
    }

    private let state = Mutex(State())
    private let opener: Mutex<Opener>

    public init(opener: @escaping Opener = { path, line in await EditorChoice.current.open(path, line: line) }) {
        self.opener = Mutex(opener)
    }

    // The tests open nothing.
    public func setOpener(_ opener: @escaping Opener) {
        self.opener.withLock { $0 = opener }
    }

    public func places(load: () async -> [LogPlace]) async -> [LogPlace] {
        if let cached = state.withLock({ $0.places }), Date.now.timeIntervalSince(cached.date) < Self.placesSeconds {
            return cached.places
        }

        let places = await load()
        state.withLock { $0.places = (.now, places) }
        return places
    }

    // MARK: The entries

    public func entries(of place: LogPlace, paths: NexusPaths, request: LogPageQuery) -> PageResponse {
        let files = AppLogFiles.files(of: place, paths: paths)
        let opened = indices(of: place, files: files)
        let chosen = request.fileKey.flatMap { key in files.first { Self.key(of: $0) == key } }
        var query = request.query
        query.fileID = chosen?.id
        let counting = countingShare(of: opened)
        let snapshots = opened.map(\.index.snapshot)
        let version = Self.version(place: place, files: files, snapshots: snapshots, request: request, chosen: chosen, counting: counting)

        guard version != request.known else {
            return .json(LogPageUnchanged(version: version))
        }

        let hits = query.searchText.map { text in searchHits(of: text, in: opened, snapshots: snapshots) }
        let result = LogBrowser.result(of: snapshots, query: query, searchHits: hits, limit: request.limit)
        let texts = rowTexts(of: result.rows, in: opened)
        let keys = Dictionary(files.map { ($0.id, Self.key(of: $0)) }) { first, _ in first }

        let rows = result.rows.map { row in
            LogPageRow(row: row, fileKey: keys[row.fileID] ?? "", text: texts[row.id] ?? LogPageRowText(message: ""))
        }

        return .json(LogPageEntries(
            version: version,
            place: place.id,
            kind: place.kind,
            size: Self.sizeText(files.reduce(Int64(0)) { $0 + $1.bytes }),
            files: opened.map(LogPageFile.init),
            file: chosen.map(Self.key),
            rows: rows,
            rowCount: result.rowCount,
            matching: result.matching,
            total: result.total,
            levelCounts: Dictionary(result.levelCounts.map { ($0.key.rawValue, $0.value) }) { first, _ in first },
            hiddenTestRuns: result.hiddenTestRuns,
            hiddenByMessage: Dictionary(result.hiddenByMessage.map { (Self.hashText($0.key), $0.value) }) { first, _ in first },
            searchCounts: hits.map { found in Dictionary(files.map { (Self.key(of: $0), found[$0.id]?.count ?? 0) }) { first, _ in first } },
            counting: counting
        ))
    }

    // MARK: One entry

    public func detail(of place: LogPlace, paths: NexusPaths, fileKey: String, offset: UInt64) -> PageResponse {
        guard let (opened, entry) = find(fileKey: fileKey, offset: offset, of: place, paths: paths) else {
            return .message("This entry is not in the log anymore.", status: 404)
        }

        let read = opened.index.text(of: entry, limit: Self.detailBytes)
        let detail = LogEntryParser.detail(of: read.text, kind: opened.file.kind, isCut: read.isCut)
        return .json(LogPageDetail(entry: entry, fileKey: fileKey, detail: detail, text: read.text, project: place.projectFolder))
    }

    // MARK: Open in the editor

    public enum OpenTarget: Sendable, Equatable {
        case file(path: String, line: Int?)
        case refused(PageResponse)
    }

    // Without an exception the log file itself opens at the line of the entry. A file of an
    // exception or of a frame comes from the text of the log. So it opens only when it is in the
    // project folder of the place.
    public func openTarget(of place: LogPlace, paths: NexusPaths, request: LogPageOpen) -> OpenTarget {
        guard let (opened, entry) = find(fileKey: request.file, offset: request.offset, of: place, paths: paths) else {
            return .refused(.message("This entry is not in the log anymore.", status: 404))
        }

        guard let exceptionIndex = request.exception else {
            return .file(path: opened.file.path, line: entry.line > 0 ? entry.line : nil)
        }

        let text = opened.index.text(of: entry, limit: Self.detailBytes).text
        let exceptions = LogEntryParser.detail(of: text, kind: opened.file.kind, isCut: false).exceptions

        guard exceptions.indices.contains(exceptionIndex) else {
            return .refused(.message("This entry has no such exception.", status: 404))
        }

        let exception = exceptions[exceptionIndex]
        var source = (file: exception.file, line: exception.line)

        if let frameIndex = request.frame {
            guard exception.frames.indices.contains(frameIndex) else {
                return .refused(.message("This exception has no such frame.", status: 404))
            }

            source = (exception.frames[frameIndex].file, exception.frames[frameIndex].line)
        }

        guard let path = source.file else {
            return .refused(.message("This line has no file.", status: 404))
        }

        let standardized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)

        guard LogFolders.prefixes(of: place.projectFolder).contains(where: { standardized.hasPrefix($0) }) else {
            return .refused(.message("Nexus opens only the files in the project folder of \(place.id).", status: 403))
        }

        guard FileManager.default.fileExists(atPath: standardized) else {
            return .refused(.message("\(standardized) does not exist anymore.", status: 409))
        }

        return .file(path: standardized, line: source.line)
    }

    public func open(_ path: String, line: Int?) async -> Bool {
        let opener = opener.withLock { $0 }
        return await opener(path, line)
    }

    // MARK: The indices

    private func find(fileKey: String, offset: UInt64, of place: LogPlace, paths: NexusPaths) -> (Opened, LogIndex.Entry)? {
        guard let file = AppLogFiles.files(of: place, paths: paths).first(where: { Self.key(of: $0) == fileKey }), let opened = indices(of: place, files: [file]).first else {
            return nil
        }

        let snapshot = opened.index.snapshot

        if let last = snapshot.last, last.offset == offset {
            return (opened, last)
        }

        return Self.entry(at: offset, in: snapshot.closed).map { (opened, $0) }
    }

    // The closed entries are in the order of their offsets.
    static func entry(at offset: UInt64, in entries: [LogIndex.Entry]) -> LogIndex.Entry? {
        var low = 0
        var high = entries.count - 1

        while low <= high {
            let middle = (low + high) / 2

            if entries[middle].offset == offset {
                return entries[middle]
            }

            if entries[middle].offset < offset {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        return nil
    }

    // The zone of a Laravel log comes from its .env, as on the Logs screen. A changed zone or
    // changed folders of the PHP errors give a new index.
    func indices(of place: LogPlace, files: [LogFile]) -> [Opened] {
        let laravelZone = place.kind == .laravel ? LaravelTimeZone.of(project: URL(filePath: place.projectFolder, directoryHint: .isDirectory)) : TimeZone.current
        let now = Date.now

        let opened = state.withLock { state in
            forgetUnused(&state, now: now)

            return files.map { file in
                let zone = file.kind == .app ? laravelZone : TimeZone.current
                let key = [place.id, file.id, zone.identifier, file.folders.joined(separator: ","), file.excludedFolders.joined(separator: ",")].joined(separator: "\n")
                let index = state.kept[key]?.index ?? LogIndex(file: file, zone: zone)
                state.kept[key] = Kept(index: index, used: now)
                return Opened(place: place, file: file, zone: zone, key: key, index: index)
            }
        }

        for item in opened {
            update(item)
        }

        return opened
    }

    private func forgetUnused(_ state: inout State, now: Date) {
        for (key, kept) in state.kept where now.timeIntervalSince(kept.used) >= Self.keptSeconds {
            state.kept[key] = nil
            state.searches[key] = nil
            state.rowTexts[key] = nil
        }
    }

    // A large new file first gets the index of its end. A task then reads the whole file. Meanwhile
    // the page shows the end. A poll does not update the index while the task reads.
    private func update(_ item: Opened) {
        guard state.withLock({ $0.counting[item.key] == nil }) else {
            return
        }

        item.index.update(quickStart: true)

        guard !item.index.isComplete else {
            return
        }

        let starts = state.withLock { state in
            guard state.counting[item.key] == nil else {
                return false
            }

            state.counting[item.key] = 0
            return true
        }

        guard starts else {
            return
        }

        let index = item.index
        let key = item.key

        Task.detached(priority: .utility) { [self] in
            index.update { [self] done in
                state.withLock { $0.counting[key] = done }
            }

            state.withLock { $0.counting[key] = nil }
        }
    }

    private func countingShare(of opened: [Opened]) -> Double? {
        let shares = state.withLock { state in opened.compactMap { state.counting[$0.key] } }
        return shares.min().map { ($0 * 100).rounded() / 100 }
    }

    // A search reads the whole file. So its hits stay until the file changes or the text changes.
    private func searchHits(of text: String, in opened: [Opened], snapshots: [LogIndex.Snapshot]) -> [String: Set<UInt64>] {
        var hits: [String: Set<UInt64>] = [:]

        for (item, snapshot) in zip(opened, snapshots) {
            let signature = "\(snapshot.bytes) \(snapshot.count) \(snapshot.isComplete)"

            if let known = state.withLock({ $0.searches[item.key] }), known.text == text, known.signature == signature {
                hits[item.file.id] = known.hits
                continue
            }

            let found = item.index.search(text) ?? []
            state.withLock { $0.searches[item.key] = Search(text: text, signature: signature, hits: found) }
            hits[item.file.id] = found
        }

        return hits
    }

    // The texts of a row are read once for each entry. The last entry of a file can still grow.
    // So its length is part of the key.
    private func rowTexts(of rows: [LogRow], in opened: [Opened]) -> [String: LogPageRowText] {
        var texts: [String: LogPageRowText] = [:]

        for item in opened {
            let own = rows.filter { $0.fileID == item.file.id }

            guard !own.isEmpty else {
                continue
            }

            let known = state.withLock { $0.rowTexts[item.key] ?? [:] }
            var found: [UInt64: RowText] = [:]

            for row in own {
                if let cached = known[row.entry.offset], cached.length == row.entry.length {
                    texts[row.id] = cached.text
                }
            }

            let missing = own.filter { texts[$0.id] == nil }

            guard !missing.isEmpty else {
                continue
            }

            let read = item.index.texts(of: missing.map(\.entry), limit: Self.summaryBytes)

            for (row, text) in zip(missing, read) {
                let rowText = LogPageRowText(summary: LogEntryParser.summary(of: text, kind: item.file.kind), project: item.place.projectFolder)
                texts[row.id] = rowText
                found[row.entry.offset] = RowText(length: row.entry.length, text: rowText)
            }

            state.withLock { state in
                var cached = state.rowTexts[item.key] ?? [:]

                if cached.count + found.count > Self.summaryLimit {
                    cached = [:]
                }

                cached.merge(found) { _, new in new }
                state.rowTexts[item.key] = cached
            }
        }

        return texts
    }

    // MARK: Texts and keys

    // The key of a file on the page is a hash of its id. So the page never holds a path to send.
    static func key(of file: LogFile) -> String {
        hashText(fnv(file.id))
    }

    static func hashText(_ value: UInt64) -> String {
        String(value, radix: 16)
    }

    static func fnv(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325

        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
        }

        return value
    }

    // The version changes with each change of the files, of the query and of the count. A page
    // that sends the version it has gets only "unchanged" while nothing changed.
    static func version(place: LogPlace, files: [LogFile], snapshots: [LogIndex.Snapshot], request: LogPageQuery, chosen: LogFile?, counting: Double?) -> String {
        var parts = [place.id, place.projectFolder, request.signature, chosen?.id ?? "", counting.map { String($0) } ?? ""]
        parts += files.map { "\($0.id) \($0.bytes) \($0.modified?.timeIntervalSince1970 ?? 0)" }
        parts += snapshots.map { "\($0.file.id) \($0.bytes) \($0.count) \($0.isComplete) \($0.last?.length ?? 0)" }
        return hashText(fnv(parts.joined(separator: "\n")))
    }

    // As the file menu of the Logs screen: 48.2 MB.
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // UTC for the zone of UTC and GMT, else a short name such as CET, as on the Logs screen.
    static func zoneName(_ zone: TimeZone) -> String {
        if zone.secondsFromGMT() == 0, ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(zone.identifier) {
            return "UTC"
        }

        return zone.abbreviation() ?? zone.identifier
    }
}

// The filters of the page, from the query of a request: place, file, levels, tests, hidden, group,
// search, limit and known.
public struct LogPageQuery: Sendable, Equatable {
    public let place: String
    public let fileKey: String?
    public let query: LogQuery
    public let limit: Int
    public let known: String?
    // The filters as text, for the version.
    let signature: String

    public init(_ values: [String: String]) {
        var query = LogQuery()

        if let levels = values["levels"] {
            query.levels = Set(levels.split(separator: ",").compactMap { LogLevelGroup(rawValue: String($0)) })
        }

        query.hidesTestRuns = values["tests"] != "shown"
        query.groupsEqualEntries = values["group"] != "0"
        query.search = values["search"] ?? ""

        for hash in (values["hidden"] ?? "").split(separator: ",") {
            if let value = UInt64(hash, radix: 16) {
                query.hiddenMessages[value] = ""
            }
        }

        place = values["place"] ?? ""
        fileKey = values["file"].flatMap { $0.isEmpty ? nil : $0 }
        self.query = query
        limit = min(max(Int(values["limit"] ?? "") ?? LogPageStore.rowPage, 1), LogPageStore.rowLimit)
        known = values["known"]
        signature = values.filter { $0.key != "known" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}

// The body of a request to open a file. Without exception the log file opens at the line of the
// entry. frame names a frame of the stack trace of that exception.
public struct LogPageOpen: Codable, Sendable, Equatable {
    public let place: String
    public let file: String
    public let offset: UInt64
    public let exception: Int?
    public let frame: Int?

    public init(place: String, file: String, offset: UInt64, exception: Int? = nil, frame: Int? = nil) {
        self.place = place
        self.file = file
        self.offset = offset
        self.exception = exception
        self.frame = frame
    }
}

// MARK: The JSON of the page

// Times are milliseconds since 1970, as JavaScript counts them. A hash is text, because a number
// of JavaScript cannot hold 64 bits.

public struct LogPagePlace: Encodable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let kind: LogPlace.Kind

    public init(_ place: LogPlace) {
        id = place.id
        label = place.workspace == nil ? place.id : "\(place.id) (workspace)"
        kind = place.kind
    }
}

public struct LogPagePlaces: Encodable, Sendable {
    public let places: [LogPagePlace]

    public init(places: [LogPlace]) {
        self.places = places.map(LogPagePlace.init)
    }
}

struct LogPageUnchanged: Encodable {
    let version: String
    let unchanged = true
}

// zone names the zone of the times in the file and zoneOffset gives its seconds from UTC now. The
// page shows the time of the log too when the zone of the browser has another offset.
struct LogPageFile: Encodable {
    let key: String
    let name: String
    let kind: LogFile.Kind
    let size: String
    let path: String
    let zone: String
    let zoneOffset: Int

    init(_ opened: LogPageStore.Opened) {
        key = LogPageStore.key(of: opened.file)
        name = opened.file.name
        kind = opened.file.kind
        size = LogPageStore.sizeText(opened.file.bytes)
        path = opened.file.path
        zone = LogPageStore.zoneName(opened.zone)
        zoneOffset = opened.zone.secondsFromGMT()
    }
}

// The parts of the row of an entry that come from its text.
struct LogPageRowText: Sendable {
    let message: String
    var exception: String?
    var source: String?
    var sourceLine: Int?
    var context: [String] = []

    init(message: String) {
        self.message = message
    }

    init(summary: LogEntrySummary, project: String) {
        message = summary.message
        exception = summary.exceptionClass
        source = summary.sourceFile.map { LogEntryParser.relative($0, to: project) }
        sourceLine = summary.sourceLine
        context = summary.context
    }
}

struct LogPageRow: Encodable {
    let id: String
    let file: String
    let offset: UInt64
    let length: UInt64
    let line: Int
    let time: Double?
    let sortTime: Double
    let level: String
    let group: LogLevelGroup
    let testRun: Bool
    let hash: String
    let count: Int
    let firstTime: Double?
    let message: String
    let exception: String?
    let source: String?
    let sourceLine: Int?
    let context: [String]

    init(row: LogRow, fileKey: String, text: LogPageRowText) {
        id = "\(fileKey)#\(row.entry.offset)"
        file = fileKey
        offset = row.entry.offset
        length = row.entry.length
        line = row.entry.line
        time = row.entry.date.map { $0 * 1000 }
        sortTime = row.sortDate * 1000
        level = row.entry.level
        group = row.group
        testRun = row.entry.isTestRun
        hash = LogPageStore.hashText(row.entry.hash)
        count = row.count
        firstTime = row.firstDate.map { $0 * 1000 }
        message = text.message
        exception = text.exception
        source = text.source
        sourceLine = text.sourceLine
        context = text.context
    }
}

struct LogPageEntries: Encodable {
    let version: String
    let place: String
    let kind: LogPlace.Kind
    let size: String
    let files: [LogPageFile]
    let file: String?
    let rows: [LogPageRow]
    let rowCount: Int
    let matching: Int
    let total: Int
    let levelCounts: [String: Int]
    let hiddenTestRuns: Int
    let hiddenByMessage: [String: Int]
    let searchCounts: [String: Int]?
    let counting: Double?
}

struct LogPageFrame: Encodable {
    let number: Int?
    let file: String?
    let shortFile: String?
    let line: Int?
    let call: String
    // A frame without a file counts as vendor/ too, as in LogFrame.
    let vendor: Bool
}

struct LogPageException: Encodable {
    let className: String
    let namespace: String
    let shortName: String
    let message: String
    let file: String?
    let shortFile: String?
    let line: Int?
    let frames: [LogPageFrame]

    init(_ exception: LogException, project: String) {
        className = exception.className
        namespace = exception.namespace
        shortName = exception.shortClassName
        message = exception.message
        file = exception.file
        shortFile = exception.file.map { LogEntryParser.relative($0, to: project) }
        line = exception.line
        frames = exception.frames.map { frame in
            LogPageFrame(number: frame.number, file: frame.file, shortFile: frame.file.map { LogEntryParser.relative($0, to: project) }, line: frame.line, call: frame.call, vendor: frame.isVendor)
        }
    }
}

struct LogPageID: Encodable {
    let key: String
    let value: String
}

struct LogPageDetail: Encodable {
    let id: String
    let file: String
    let offset: UInt64
    let length: UInt64
    let line: Int
    let time: Double?
    let level: String
    let group: LogLevelGroup
    let message: String
    let characters: Int
    let isCut: Bool
    let channel: String?
    let logTime: String?
    let exceptions: [LogPageException]
    let context: DumpNode?
    let ids: [LogPageID]
    let text: String

    init(entry: LogIndex.Entry, fileKey: String, detail: LogEntryDetail, text: String, project: String) {
        id = "\(fileKey)#\(entry.offset)"
        file = fileKey
        offset = entry.offset
        length = entry.length
        line = entry.line
        time = entry.date.map { $0 * 1000 }
        level = entry.level
        group = LogLevelGroup.of(level: entry.level)
        message = detail.message
        characters = detail.characters
        isCut = detail.isCut
        channel = detail.channel
        logTime = detail.logTime
        exceptions = detail.exceptions.map { LogPageException($0, project: project) }
        context = detail.context
        ids = detail.ids.map { LogPageID(key: $0.key, value: $0.value) }
        self.text = text
    }
}
