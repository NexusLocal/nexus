import Darwin
import Foundation

// The entries of one log file (group 7). The index holds the place, the line, the time, the level
// and a hash of the message of each entry, not the text. So a file of several hundred MB costs a
// few MB of memory. The text of an entry comes from the file when the screen shows it.
public final class LogIndex: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let offset: UInt64
        public let length: UInt64
        // The line of the entry in the file, from 1. 0 while Nexus read only the end of the file.
        public let line: Int
        public let date: Double?
        // An entry without a time sorts after the entry above it.
        public let sortDate: Double
        // The same message with the same level gives the same hash.
        public let hash: UInt64
        public let level: String
        public let isTestRun: Bool
    }

    // The closed entries and the last entry, which can still grow. They are apart, so a snapshot
    // of a large index does not copy its list.
    public struct Snapshot: Sendable {
        public let file: LogFile
        public let closed: [Entry]
        public let last: Entry?
        // false while the index holds only the end of the file.
        public let isComplete: Bool
        public let bytes: UInt64
        // The last change of the file. An entry with no time above it sorts at this time.
        public let modified: Double?

        public init(file: LogFile, closed: [Entry], last: Entry?, isComplete: Bool, bytes: UInt64, modified: Double? = nil) {
            self.file = file
            self.closed = closed
            self.last = last
            self.isComplete = isComplete
            self.bytes = bytes
            self.modified = modified
        }

        // The time by which an entry sorts. An entry with no time and no entry with a time above it
        // gets the last change of the file, so it does not sort as 1970.
        public func sortDate(of entry: Entry) -> Double {
            entry.date ?? (entry.sortDate > 0 ? entry.sortDate : modified ?? 0)
        }

        public var count: Int {
            closed.count + (last == nil ? 0 : 1)
        }

        public var entries: [Entry] {
            last.map { closed + [$0] } ?? closed
        }

        public func forEach(_ body: (Entry) -> Void) {
            for entry in closed {
                body(entry)
            }

            if let last {
                body(last)
            }
        }
    }

    public enum Change: Sendable, Equatable {
        case unchanged
        case grew
        case replaced
    }

    // A file above this size first gets the index of its end, so the screen shows entries at once.
    public static let quickStartBytes: UInt64 = 8 * 1024 * 1024
    static let tailBytes: UInt64 = 4 * 1024 * 1024
    static let chunkBytes = 1024 * 1024
    // Nexus reads this much of a line. A longer line counts as one line, and the rest of it is
    // only skipped.
    static let keptLineBytes = 64 * 1024

    private enum Mode {
        case undecided
        case entries
        case lines
    }

    private struct OpenEntry {
        let offset: UInt64
        var end: UInt64
        let line: Int
        let date: Double?
        let sortDate: Double
        let hash: UInt64
        let level: String
        let isTestRun: Bool
        var matched: Bool
        var excluded: Bool

        var entry: Entry {
            Entry(offset: offset, length: end - offset, line: line, date: date, sortDate: sortDate, hash: hash, level: level, isTestRun: isTestRun)
        }
    }

    private struct State {
        var entries: [Entry] = []
        var open: OpenEntry?
        var scanned: UInt64 = 0
        var base: UInt64 = 0
        var lines = 0
        var identity: FileIdentity?
        var mode = Mode.undecided
        var lastDate = 0.0
        var isComplete = true
        var modified: Double?
    }

    public let file: LogFile
    private let zone: TimeZone
    private let folders: [[UInt8]]
    private let excludedFolders: [[UInt8]]
    private let lock = NSLock()
    private let updates = NSLock()
    private var state = State()

    public init(file: LogFile, zone: TimeZone) {
        self.file = file
        self.zone = zone
        folders = file.folders.map { Array($0.utf8) }
        excludedFolders = file.excludedFolders.map { Array($0.utf8) }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            let last = state.open.flatMap { qualifies($0) ? $0.entry : nil }
            return Snapshot(file: file, closed: state.entries, last: last, isComplete: state.isComplete, bytes: state.scanned, modified: state.modified)
        }
    }

    // Reads what is new in the file. A file that became smaller or that is another file now gets a
    // new index. With quickStart, a large new file first gets the index of its end. Call update
    // again for the rest.
    @discardableResult
    public func update(quickStart: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) -> Change {
        updates.withLock {
            let path = file.path
            var status = stat()

            guard stat(path, &status) == 0 else {
                let hadEntries = lock.withLock { !state.entries.isEmpty || state.open != nil }
                lock.withLock { state = State() }
                return hadEntries ? .replaced : .unchanged
            }

            let size = UInt64(status.st_size)
            let identity = FileIdentity(status)
            var current = lock.withLock { state }
            var change = Change.unchanged

            if current.identity != nil, current.identity != identity || size < current.scanned {
                current = State()
                change = .replaced
            }

            current.identity = identity
            current.modified = Double(status.st_mtimespec.tv_sec)

            guard let handle = FileHandle(forReadingAtPath: path) else {
                return change
            }

            defer { try? handle.close() }

            if current.mode == .undecided {
                let decided = decideMode(handle: handle, size: size)

                // Entries of a file that turns out to have no time in its lines are wrong.
                if decided == .lines, current.scanned > 0 {
                    current = State()
                    current.identity = identity
                    current.modified = Double(status.st_mtimespec.tv_sec)
                    change = .replaced
                }

                current.mode = decided
            }

            if current.scanned == 0, current.entries.isEmpty, current.open == nil, size > Self.quickStartBytes, quickStart {
                current.base = size - Self.tailBytes
                current.scanned = current.base
                current.isComplete = false
                scan(handle: handle, state: &current, to: size, skipFirstLine: true, progress: nil)
                lock.withLock { state = current }
                return .replaced
            }

            if !current.isComplete {
                var full = State()
                full.identity = identity
                full.modified = current.modified
                full.mode = current.mode
                scan(handle: handle, state: &full, to: size, skipFirstLine: false, progress: progress)
                lock.withLock { state = full }
                return .replaced
            }

            guard size > current.scanned else {
                lock.withLock { state = current }
                return change
            }

            let before = current.entries.count
            let openBefore = current.open?.end
            scan(handle: handle, state: &current, to: size, skipFirstLine: false, progress: progress)
            lock.withLock { state = current }

            if change == .replaced {
                return .replaced
            }

            return current.entries.count != before || current.open?.end != openBefore ? .grew : .unchanged
        }
    }

    public var isComplete: Bool {
        lock.withLock { state.isComplete }
    }

    // The text of an entry, at most limit bytes. A cut in the middle of a character of UTF-8 gives
    // a replacement character at the end.
    public func text(of entry: Entry, limit: Int) -> (text: String, isCut: Bool) {
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            return ("", false)
        }

        defer { try? handle.close() }

        return Self.text(of: entry, limit: limit, handle: handle)
    }

    // The texts of many entries with one open file, for the rows of the screen.
    public func texts(of entries: [Entry], limit: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            return entries.map { _ in "" }
        }

        defer { try? handle.close() }

        return entries.map { Self.text(of: $0, limit: limit, handle: handle).text }
    }

    private static func text(of entry: Entry, limit: Int, handle: FileHandle) -> (text: String, isCut: Bool) {
        let count = Int(min(entry.length, UInt64(limit)))

        guard (try? handle.seek(toOffset: entry.offset)) != nil, let data = try? handle.read(upToCount: count) else {
            return ("", false)
        }

        var text = String(decoding: data, as: UTF8.self)

        while text.last?.isNewline == true {
            text.removeLast()
        }

        return (text, entry.length > UInt64(limit))
    }

    // The offsets of the entries that hold the text, without a difference between capitals and
    // small letters (only for ASCII). nil when the search stopped.
    public func search(_ text: String, isCancelled: @Sendable () -> Bool = { false }) -> Set<UInt64>? {
        let needle = Array(text.lowercased().utf8)
        let snapshot = snapshot
        let entries = snapshot.entries

        guard !needle.isEmpty, !entries.isEmpty, let handle = FileHandle(forReadingAtPath: file.path) else {
            return []
        }

        defer { try? handle.close() }

        var found: Set<UInt64> = []
        var position = entries[0].offset
        let end = entries[entries.count - 1].offset + entries[entries.count - 1].length
        let overlap = UInt64(needle.count - 1)

        while position < end {
            if isCancelled() {
                return nil
            }

            guard (try? handle.seek(toOffset: position)) != nil, let data = try? handle.read(upToCount: Int(min(UInt64(Self.chunkBytes), end - position))), !data.isEmpty else {
                break
            }

            var lowered = [UInt8](data)

            for index in lowered.indices where lowered[index] >= 65 && lowered[index] <= 90 {
                lowered[index] += 32
            }

            var searchFrom = 0
            var skipTo = position + UInt64(lowered.count)

            lowered.withUnsafeBytes { haystack in
                needle.withUnsafeBytes { pattern in
                    while searchFrom + needle.count <= haystack.count, let hit = memmem(haystack.baseAddress! + searchFrom, haystack.count - searchFrom, pattern.baseAddress!, pattern.count) {
                        let local = haystack.baseAddress!.distance(to: UnsafeRawPointer(hit))
                        let absolute = position + UInt64(local)

                        guard let entry = Self.entry(holding: absolute, in: entries) else {
                            searchFrom = local + 1
                            continue
                        }

                        found.insert(entry.offset)
                        let entryEnd = entry.offset + entry.length

                        if entryEnd >= position + UInt64(haystack.count) {
                            skipTo = max(entryEnd, position + UInt64(haystack.count))
                            searchFrom = haystack.count
                        } else {
                            searchFrom = Int(entryEnd - position)
                        }
                    }
                }
            }

            let next = skipTo > position + UInt64(lowered.count) ? skipTo : position + UInt64(lowered.count) - min(overlap, UInt64(lowered.count))

            guard next > position else {
                break
            }

            position = next
        }

        return found
    }

    static func entry(holding offset: UInt64, in entries: [Entry]) -> Entry? {
        var low = 0
        var high = entries.count - 1
        var best: Int?

        while low <= high {
            let middle = (low + high) / 2

            if entries[middle].offset <= offset {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        guard let best, offset < entries[best].offset + entries[best].length else {
            return nil
        }

        return entries[best]
    }

    // A Laravel log or a WordPress log has entries with a time. A file without such a line in its
    // first 64 KB gets one entry for each line.
    private func decideMode(handle: FileHandle, size: UInt64) -> Mode {
        switch file.kind {
        case .output:
            return .lines
        case .phpErrors, .requests:
            return .entries
        case .app:
            break
        }

        guard size > 0, (try? handle.seek(toOffset: 0)) != nil, let sample = try? handle.read(upToCount: 64 * 1024) else {
            return .undecided
        }

        var parser = LogLineParser(kind: file.kind, zone: zone)
        var found = false

        sample.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0

            for index in bytes.indices where bytes[index] == 10 {
                if parser.start(of: UnsafeBufferPointer(rebasing: bytes[start..<index])) != nil {
                    found = true
                    return
                }

                start = index + 1
            }
        }

        if found {
            return .entries
        }

        return size > 64 * 1024 || sample.contains(10) ? .lines : .undecided
    }

    private func scan(handle: FileHandle, state: inout State, to size: UInt64, skipFirstLine: Bool, progress: (@Sendable (Double) -> Void)?) {
        var parser = LogLineParser(kind: file.kind, zone: zone)
        var position = state.scanned
        var lineStart = position
        var kept: [UInt8] = []
        kept.reserveCapacity(4096)
        var skipping = skipFirstLine && position > 0
        let total = Double(max(size - state.scanned, 1))
        let first = state.scanned
        var lastReport = 0.0

        guard (try? handle.seek(toOffset: position)) != nil else {
            return
        }

        while position < size {
            let want = Int(min(UInt64(Self.chunkBytes), size - position))

            guard let data = try? handle.read(upToCount: want), !data.isEmpty else {
                break
            }

            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var start = 0

                while start < bytes.count {
                    let rest = bytes.count - start
                    let found = memchr(bytes.baseAddress! + start, 10, rest)

                    guard let found else {
                        keep(bytes, from: start, to: bytes.count, into: &kept)
                        start = bytes.count
                        continue
                    }

                    let newline = UnsafeRawPointer(bytes.baseAddress!).distance(to: UnsafeRawPointer(found))
                    keep(bytes, from: start, to: newline, into: &kept)
                    let lineEnd = position + UInt64(newline) + 1

                    if skipping {
                        skipping = false
                    } else {
                        kept.withUnsafeBufferPointer { line in
                            process(line, start: lineStart, end: lineEnd, state: &state, parser: &parser)
                        }
                    }

                    state.scanned = lineEnd
                    lineStart = lineEnd
                    kept.removeAll(keepingCapacity: true)
                    start = newline + 1
                }
            }

            position += UInt64(data.count)

            if let progress {
                let done = Double(position - first) / total

                if done - lastReport > 0.02 {
                    lastReport = done
                    progress(done)
                }
            }
        }

        if let open = state.open {
            state.open?.end = max(open.end, state.scanned)
        }
    }

    private func keep(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, into kept: inout [UInt8]) {
        let room = Self.keptLineBytes - kept.count

        guard room > 0, end > start else {
            return
        }

        kept.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<min(end, start + room)]))
    }

    private func process(_ line: UnsafeBufferPointer<UInt8>, start: UInt64, end: UInt64, state: inout State, parser: inout LogLineParser) {
        if state.base == 0 || state.isComplete {
            state.lines += 1
        }

        let number = state.isComplete ? state.lines : 0

        if state.mode == .lines {
            let trimmed = LogLineParser.trimmedEnd(line)

            guard trimmed > 0 else {
                if state.open != nil {
                    state.open?.end = end
                }

                return
            }

            close(&state)
            state.open = OpenEntry(offset: start, end: end, line: number, date: nil, sortDate: state.lastDate, hash: Self.hash(level: "", line, from: 0, to: trimmed), level: "", isTestRun: false, matched: true, excluded: false)
            return
        }

        if let found = parser.start(of: line) {
            close(&state)

            if let date = found.date {
                state.lastDate = date
            }

            state.open = OpenEntry(offset: start, end: end, line: number, date: found.date, sortDate: found.date ?? state.lastDate, hash: Self.hash(level: found.level, line, from: found.messageStart, to: found.messageEnd), level: found.level, isTestRun: found.channel == "testing", matched: matches(line), excluded: isExcluded(line))
            return
        }

        guard state.open != nil else {
            // The end of a large file starts in the middle of an entry. That part is left out.
            guard state.isComplete else {
                return
            }

            state.open = OpenEntry(offset: start, end: end, line: number, date: nil, sortDate: state.lastDate, hash: Self.hash(level: "", line, from: 0, to: LogLineParser.trimmedEnd(line)), level: "", isTestRun: false, matched: matches(line), excluded: isExcluded(line))
            return
        }

        state.open?.end = end

        if state.open?.matched == false, matches(line) {
            state.open?.matched = true
        }

        if state.open?.excluded == false, isExcluded(line) {
            state.open?.excluded = true
        }
    }

    private func close(_ state: inout State) {
        if let open = state.open, qualifies(open) {
            state.entries.append(open.entry)
        }

        state.open = nil
    }

    private func qualifies(_ open: OpenEntry) -> Bool {
        folders.isEmpty || (open.matched && !open.excluded)
    }

    private func matches(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        folders.isEmpty || folders.contains { Self.contains($0, in: line) }
    }

    private func isExcluded(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        excludedFolders.contains { Self.contains($0, in: line) }
    }

    static func contains(_ needle: [UInt8], in line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !needle.isEmpty, needle.count <= line.count, let base = line.baseAddress else {
            return false
        }

        return needle.withUnsafeBytes { pattern in
            memmem(base, line.count, pattern.baseAddress!, pattern.count) != nil
        }
    }

    // FNV-1a of the level and the first 300 bytes of the message.
    static func hash(level: String, _ line: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325

        for byte in level.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
        }

        value = (value ^ 0x1f) &* 0x100_0000_01b3

        guard start < end else {
            return value
        }

        for index in start..<min(end, start + 300, line.count) {
            value = (value ^ UInt64(line[index])) &* 0x100_0000_01b3
        }

        return value
    }
}
