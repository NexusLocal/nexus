import Foundation
import NexusCore
import Synchronization

// The caught entries in memory and in logs/dumps.jsonl. An entry is a dump or a query, a log line
// or a job row (CaughtDump). The store numbers and keeps each kind in the same way. The list holds
// only the request headers. The entries of a request are flat records next to it. So a change of
// the list never copies them. A request shows in the list from its first entry on and goes with
// its last entry. A job of a worker also shows at its end without entries.
//
// The lock guards only the memory. DumpFile writes the file on its own queue. So list and dumps
// never wait for the disk. Each change adds lines to the file. A start reads the lines again in
// their order and gets the same store, because the same limits remove the same old entries. The
// file gets only the kept records when it is larger than 10 MB and the kept records take less than
// half of it.
public final class DumpStore: Sendable {
    public static let requestLimit = 500
    public static let byteLimit = 10 * 1024 * 1024

    // The number of ends that wait for the first dump of their request. Usually that dump was too
    // large to send. Then it never comes.
    static let waitingLimit = 100

    let writer: DumpFile
    private let locate: @Sendable (DumpedRequest) -> DumpLocation
    private let state = Mutex(StoreState())

    // locate runs outside the lock of the store. So it can read other state of nexusd. It runs
    // only for a new request and in relocate.
    public init(file: URL, locate: @escaping @Sendable (DumpedRequest) -> DumpLocation = { _ in DumpLocation() }) {
        writer = DumpFile(url: file)
        self.locate = locate
    }

    public var file: URL {
        writer.url
    }

    // The gap after the highest number in the file at a start. A crash can lose the last lines of
    // the file. A client can have seen their numbers. So the store never gives these numbers again.
    public static let numberGap = 1000

    // A line that does not decode is skipped. An example is the cut last line after a crash. The
    // file then gets only the kept records. So the next line does not join the cut one. A file
    // without an epoch gets a new epoch, for example a new store.
    public func load() {
        writer.waitForWrites()

        let data = (try? Data(contentsOf: file)) ?? Data()
        let newline = UInt8(ascii: "\n")
        var loaded = StoreState()
        var damaged = data.last.map { lastByte in lastByte != newline } ?? false

        for line in data.split(separator: newline) {
            guard let record = try? DumpCoding.decoder.decode(Record.self, from: line) else {
                damaged = true
                continue
            }

            loaded.replay(record, lineBytes: line.count + 1)
        }

        if loaded.removeRequestsWithoutDumps() {
            damaged = true
        }

        if loaded.epoch.isEmpty {
            loaded.epoch = StoreState.newEpoch()
            damaged = true
        } else {
            loaded.lastNumber += Self.numberGap
        }

        loaded.isLoaded = true
        loaded.fileBytes = data.count
        loaded.forgetChanges()

        state.withLock { state in
            state = loaded

            if damaged {
                rewrite(&state)
                return
            }

            if state.fileIsLarge {
                rewrite(&state)
            }
        }
    }

    // A blocked event is not a request of the list. Part 7 shows it as a block.
    public func add(_ event: DumpEvent) {
        switch event {
        case .dump(let request, let dump):
            add([dump], of: request)
        case .entries(let request, let entries):
            add(entries, of: request)
        case .end(let request, let status, let exitCode, let duration, let outcome, let droppedQueries):
            let end = RequestEnd(status: status, exitCode: exitCode, duration: duration, outcome: outcome, droppedQueries: droppedQueries)

            change(request) { state, newHeader in
                state.end(request.id, end, newHeader: newHeader).map { line in [line] } ?? []
            }
        case .blocked:
            return
        }
    }

    // The newest request first, as DumpList has them. nil gives the requests of every place.
    public func list(place: DumpPlace? = nil) -> [DumpedRequest] {
        listAndCursor(place: place).requests
    }

    // The list and the cursor of the same moment. newDumps after this cursor gives each dump that
    // came after the list. The cursor is nil until load() ran.
    public func listAndCursor(place: DumpPlace? = nil) -> (requests: [DumpedRequest], cursor: DumpCursor?) {
        state.withLock { state in
            let requests = state.order.reversed()
                .compactMap { id in state.requests[id] }
                .filter { request in place.includes(request.place) }

            return (requests, state.cursor)
        }
    }

    // A watcher can connect before nexusd loaded the file. Its list is then empty, but not because
    // the store has no dumps.
    public var isLoaded: Bool {
        state.withLock { state in state.isLoaded }
    }

    // The entries of all kinds of one request with a number above afterNumber, in the order in which
    // they arrived. An entry with a lower seq that arrives later has a higher number. So it comes
    // too. 0 gives all entries of the request. The store knows the numbers of each request. So it
    // finds each entry with a binary search and does not walk the other requests. kinds keeps only
    // the entries of these kinds. nil keeps each kind.
    public func dumps(request: String, afterNumber: Int = 0, kinds: Set<CaughtDump.Kind>? = nil) -> [CaughtDump] {
        state.withLock { state in
            let numbers = state.entriesOf[request]?.numbers ?? []
            let first = numbers.partitionIndex { number in number > afterNumber }

            let entries = numbers[first...].compactMap { number in state.dumps.kept(number: number)?.dump }

            return entries.filter { entry in kinds?.contains(entry.kind) ?? true }
        }
    }

    public func dump(number: Int) -> CaughtDump? {
        state.withLock { state in
            state.dumps.kept(number: number)?.dump
        }
    }

    // The newest dumps of a place, at most limit, up to the cursor of a list, in the order in which
    // they arrived. nil reads up to the newest dump. newDumps after the same cursor gives the rest.
    // So no dump comes twice. The shown dumps of a request are its newest. So each dump of such a
    // request with a lower number is an older dump that the batch leaves out. olderCounts counts
    // them. A cursor of another epoch gives no dumps and the current cursor. nil means that the
    // store is not loaded yet.
    public func lastDumps(place: DumpPlace?, limit: Int, through cursor: DumpCursor? = nil) -> DumpBatch? {
        state.withLock { state in
            guard let current = state.cursor else {
                return nil
            }

            let through = cursor ?? current

            guard through.epoch == current.epoch else {
                return state.batch(of: [])
            }

            // The dumps are in the order of their numbers. So the dumps above the cursor are at the
            // end, and the walk back stops at the limit.
            let end = state.dumps.firstIndex(numberAbove: through.number)
            var shown: [KeptDump] = []

            for kept in state.dumps[..<end].reversed() {
                guard shown.count < limit else {
                    break
                }

                if state.requests[kept.dump.requestID].map({ request in place.includes(request.place) }) == true {
                    shown.append(kept)
                }
            }

            var firstShown: [String: Int] = [:]

            for kept in shown {
                firstShown[kept.dump.requestID] = kept.number
            }

            // The older entries of a request have the lower numbers of the request.
            var olderCounts: [String: Int] = [:]

            for (requestID, firstNumber) in firstShown {
                let older = (state.entriesOf[requestID]?.numbers ?? []).partitionIndex { number in number >= firstNumber }

                if older > 0 {
                    olderCounts[requestID] = older
                }
            }

            return state.batch(of: shown.reversed(), olderCounts: olderCounts)
        }
    }

    // The dumps of a place that came after the cursor. The dumps are in the order of their numbers.
    // So the walk starts at the end and stops at the first dump of the cursor or before it. A cursor
    // of another epoch gives no dumps and the current cursor. The client then starts again with
    // the newest requests. nil means that the store is not loaded yet.
    public func newDumps(place: DumpPlace?, after cursor: DumpCursor) -> DumpBatch? {
        state.withLock { state in
            guard let current = state.cursor else {
                return nil
            }

            guard cursor.epoch == current.epoch else {
                return state.batch(of: [])
            }

            let first = state.dumps.firstIndex(numberAbove: cursor.number)
            let new = state.dumps[first...].filter { kept in
                state.requests[kept.dump.requestID].map { request in place.includes(request.place) } ?? false
            }

            return state.batch(of: new)
        }
    }

    // Returns the number of removed entries. nil removes the requests of every place. A job without
    // entries goes too. So the file is written again also when only such jobs went.
    @discardableResult
    public func clear(place: DumpPlace? = nil) -> Int {
        state.withLock { state in
            let removed = state.remove(place: place)

            if removed.entries > 0 || removed.requests > 0 {
                rewrite(&state)
            }

            return removed.entries
        }
    }

    // Removes the entry with this number of the store. A request without entries goes from the
    // list. Returns false when the store has no such entry.
    @discardableResult
    public func remove(dump number: Int) -> Bool {
        state.withLock { state in
            guard state.removeDump(number: number) else {
                return false
            }

            rewrite(&state)
            return true
        }
    }

    // Removes one request with all its entries. Returns false when the list has no such request.
    @discardableResult
    public func remove(request id: String) -> Bool {
        state.withLock { state in
            guard state.requests[id] != nil else {
                return false
            }

            _ = state.removeRequestsWithTheirDumps([id])
            rewrite(&state)
            return true
        }
    }

    // nexusd calls this when a site or a workspace changes. Each request gets the location that
    // locate gives now.
    public func relocate() {
        let headers = state.withLock { state in state.allHeaders }
        let locations = headers.map { header in (id: header.id, location: locate(header)) }

        state.withLock { state in
            let lines = locations.compactMap { moved in state.move(moved.id, to: moved.location) }
            write(lines, into: &state)
        }
    }

    // nexusd groups the changes and sends them to the app.
    public func takeChanges() -> DumpChange {
        state.withLock { state in
            state.takeChanges()
        }
    }

    // For a clean shutdown and for the tests.
    public func waitForWrites() {
        writer.waitForWrites()
    }

    // The JSON of an entry is the large part of its line. The pattern of a query of WordPress needs
    // a walk over its text. So both are made outside the lock. Inside the lock the line gets its
    // number. The entries of one event get their numbers in their order.
    private func add(_ entries: [CaughtDump], of request: DumpEnvelope) {
        let opened = entries.compactMap { entry in
            Record.openLine(dump: entry).map { line in (entry: entry, line: line, pattern: KeptDump.pattern(of: entry)) }
        }

        if opened.isEmpty {
            return
        }

        change(request) { state, newHeader in
            var lines: [Data] = []

            for (entry, openLine, pattern) in opened {
                var numbered = entry
                var line = openLine
                numbered.number = state.lastNumber + 1
                Record.close(&line, number: numbered.number)

                switch state.join(KeptDump(dump: numbered, bytes: line.count, pattern: pattern), newHeader: newHeader) {
                case .refused: continue
                case .joined: lines.append(line)
                case .shown(let headerLine): lines += [headerLine, line]
                }

                lines += state.linkJobs(queuedBy: numbered)
            }

            return lines
        }
    }

    // body gets the header with its place for a request that the store does not know yet. The
    // first pass has no header. For an unknown request that pass stops. Then locate runs outside
    // the lock. A second pass gets the header.
    private func change(_ request: DumpEnvelope, _ body: (inout StoreState, DumpedRequest?) -> [Data]) {
        var newHeader: DumpedRequest?

        while true {
            let header = newHeader

            let done = state.withLock { state in
                if header == nil, !state.knows(request.id) {
                    return false
                }

                write(body(&state, header), into: &state)
                return true
            }

            if done {
                return
            }

            var placed = request.header
            placed.location = locate(placed)
            newHeader = placed
        }
    }

    // A failed write leaves the file behind the store. The next change then writes the whole file.
    private func write(_ lines: [Data], into state: inout StoreState) {
        if writer.takeFailure() {
            rewrite(&state)
            return
        }

        if lines.isEmpty {
            return
        }

        state.fileBytes += lines.reduce(0) { total, line in total + line.count }

        if state.fileIsLarge {
            rewrite(&state)
            return
        }

        writer.append(lines)
    }

    private func rewrite(_ state: inout StoreState) {
        writer.rewrite(DumpSnapshot(order: state.order, requests: state.requests, dumps: state.dumps, epoch: state.epoch, lastNumber: state.lastNumber, bytes: state.keptBytes))
        state.fileBytes = state.keptBytes
    }
}

// Writes logs/dumps.jsonl on its own serial queue. One handle with O_APPEND stays open between the
// writes. A rewrite closes it. The next append opens the new file.
final class DumpFile: Sendable {
    // Only the serial queue reads and changes the handle. So the handle needs no lock.
    private final class OpenFile: @unchecked Sendable {
        var handle: FileHandle?
    }

    let url: URL
    let queue = DispatchQueue(label: "nl.roodfruit.nexus.dumps.file")
    private let openFile = OpenFile()
    private let failed = Atomic(false)
    // The rewrites in the queue. A later rewrite holds each change of an earlier one. So only the
    // last rewrite of a quick series, for example a held Delete key, writes the file.
    private let queuedRewrites = Atomic(0)

    init(url: URL) {
        self.url = url
    }

    // Each line is its own write. So the store makes no copy that joins them.
    func append(_ lines: [Data]) {
        queue.async { [self] in
            do {
                let handle = try openedHandle()

                for line in lines {
                    try handle.write(contentsOf: line)
                }
            } catch {
                failed.store(true, ordering: .relaxed)
            }
        }
    }

    // The snapshot is encoded here, outside the lock of the store.
    func rewrite(_ snapshot: DumpSnapshot) {
        queuedRewrites.add(1, ordering: .relaxed)

        queue.async { [self] in
            guard queuedRewrites.subtract(1, ordering: .relaxed).newValue == 0 else {
                return
            }

            let data = snapshot.encoded()

            try? openFile.handle?.close()
            openFile.handle = nil

            do {
                try FileText.write(data, to: url)
            } catch {
                failed.store(true, ordering: .relaxed)
            }
        }
    }

    private func openedHandle() throws -> FileHandle {
        if let handle = openFile.handle {
            return handle
        }

        let handle = FileHandle(fileDescriptor: try AppendingFile.open(url, mode: 0o600), closeOnDealloc: true)
        openFile.handle = handle
        return handle
    }

    // True once after a failed write.
    func takeFailure() -> Bool {
        failed.exchange(false, ordering: .relaxed)
    }

    func waitForWrites() {
        queue.sync {}
    }
}

// The kept records at the time of a rewrite. The first line holds the epoch and the newest number.
// So both stay after a clear and a start. The headers come next in the order of the list. A load
// then gives the requests the same order, also when the limits removed the first dump of a
// request. The dumps follow in the order in which they arrived.
struct DumpSnapshot: Sendable {
    let order: [String]
    let requests: [String: DumpedRequest]
    let dumps: KeptEntries
    let epoch: String
    let lastNumber: Int
    let bytes: Int

    func encoded() -> Data {
        var data = Data(capacity: bytes)
        data.append(Record.line(Record(number: lastNumber, epoch: epoch)) ?? Data())

        for id in order {
            if let header = requests[id] {
                data.append(Record.line(header: header))
            }
        }

        for kept in dumps {
            data.append(Record.line(dump: kept.dump, number: kept.number) ?? Data())
        }

        return data
    }
}

// A line of logs/dumps.jsonl holds a request header, a dump with its number, or the epoch with the
// newest number. A dump line of an older build has no number. Its number is then the number before
// it plus 1.
struct Record: Codable {
    var request: DumpedRequest?
    var dump: CaughtDump?
    var number: Int?
    var epoch: String?

    // The keys of a line are sorted. So these two parts give the same line as line(dump:number:).
    static func openLine(dump: CaughtDump) -> Data? {
        guard let json = try? DumpCoding.encoder.encode(unnumbered(dump)) else {
            return nil
        }

        var line = Data(capacity: json.count + 40)
        line.append(contentsOf: #"{"dump":"#.utf8)
        line.append(json)
        return line
    }

    static func close(_ line: inout Data, number: Int) {
        line.append(contentsOf: #","number":\#(number)}"#.utf8)
        line.append(UInt8(ascii: "\n"))
    }

    // The store counts the entries of a request itself. So a header in the file has no counts. Its
    // line then keeps its size when an entry arrives.
    static func line(header: DumpedRequest) -> Data {
        line(Record(request: header.uncounted)) ?? Data()
    }

    static func line(dump: CaughtDump, number: Int? = nil) -> Data? {
        line(Record(dump: unnumbered(dump), number: number))
    }

    // The number of a dump is on its line, next to the dump. So it is in the file once.
    private static func unnumbered(_ dump: CaughtDump) -> CaughtDump {
        var plain = dump
        plain.number = 0
        return plain
    }

    static func line(_ record: Record) -> Data? {
        guard var data = try? DumpCoding.encoder.encode(record) else {
            return nil
        }

        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// The values of the end event of a request.
struct RequestEnd {
    let status: Int?
    let exitCode: Int?
    let duration: TimeInterval?
    let outcome: JobRun.Outcome?
    let droppedQueries: Int?
}

extension DumpedRequest {
    // The values that the store counts from the entries that it keeps. A header line in the file
    // has none of them. droppedQueries and job come from PHP. So they stay.
    var uncounted: DumpedRequest {
        var plain = self
        plain.take(countsOf: DumpedRequest(id: id, kind: kind, target: target, started: started))
        return plain
    }

    mutating func take(countsOf counted: DumpedRequest) {
        dumpCount = counted.dumpCount
        hasDD = counted.hasDD
        lastSeq = counted.lastSeq
        firstSeq = counted.firstSeq
        lastNumber = counted.lastNumber
        firstNumber = counted.firstNumber
        queryCount = counted.queryCount
        queryMilliseconds = counted.queryMilliseconds
        logCount = counted.logCount
        jobCount = counted.jobCount
        marks = counted.marks
    }
}

// The entry has its number. pattern is the pattern of a query for its N+1 mark. The store makes it
// once, outside its lock.
struct KeptDump: Sendable {
    let dump: CaughtDump
    // The bytes of its line in the file. The limit of 10 MB counts these.
    let bytes: Int
    let pattern: String?

    init(dump: CaughtDump, bytes: Int, pattern: String?) {
        self.dump = dump
        self.bytes = bytes
        self.pattern = pattern
    }

    var number: Int {
        dump.number
    }

    static func pattern(of entry: CaughtDump) -> String? {
        entry.kind == .query ? QueryMarks.pattern(of: entry) : nil
    }
}

// The kept entries in the order of their numbers, the oldest first. The store can hold tens of
// thousands of small queries. The limits remove the oldest entries. So a removal at the start only
// moves the start index. The array moves its entries and frees the memory when a quarter of it is
// removed.
struct KeptEntries: RandomAccessCollection, Sendable {
    private var storage: [KeptDump] = []
    private var start = 0

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        storage.count - start
    }

    subscript(position: Int) -> KeptDump {
        storage[start + position]
    }

    // The entries are in the order of their numbers. So a binary search finds a number.
    func firstIndex(numberAbove number: Int) -> Int {
        partitionIndex { kept in kept.number > number }
    }

    func kept(number: Int) -> KeptDump? {
        let index = firstIndex(numberAbove: number - 1)

        guard index < endIndex, self[index].number == number else {
            return nil
        }

        return self[index]
    }

    mutating func append(_ kept: KeptDump) {
        storage.append(kept)
    }

    mutating func removeFirst(_ count: Int) {
        start += count
        freeTheStart()
    }

    // Removes the entries with these numbers. numbers is sorted. Only the part of the array up to
    // the last of these entries changes: its other entries move back and the start moves after
    // them. So the removal of the oldest request does not move the newer entries. A number that the
    // array does not have removes nothing. Returns the removed entries, the oldest first.
    mutating func remove(numbers: [Int]) -> [KeptDump] {
        guard let last = numbers.last else {
            return []
        }

        let end = start + firstIndex(numberAbove: last)
        var removed: [KeptDump] = []
        var write = end
        var wanted = numbers.count - 1

        for read in stride(from: end - 1, through: start, by: -1) {
            let kept = storage[read]

            while wanted >= 0, numbers[wanted] > kept.number {
                wanted -= 1
            }

            if wanted >= 0, numbers[wanted] == kept.number {
                removed.append(kept)
                wanted -= 1
                continue
            }

            write -= 1
            storage[write] = kept
        }

        start = write
        freeTheStart()
        return removed.reversed()
    }

    private mutating func freeTheStart() {
        if start * 4 >= storage.count {
            storage.removeFirst(start)
            start = 0
        }
    }
}

// The entries that the store keeps of one request, for the values of its header. The numbers and
// the seqs are sorted. So the lowest and the highest are at the ends. Each change costs a binary
// search and no walk over the other entries of the store.
struct RequestEntries {
    var numbers: [Int] = []
    var seqs: [Int] = []
    var ddCount = 0
    var queries = QueryTally()

    mutating func add(_ kept: KeptDump) {
        numbers.insertSorted(kept.number)
        seqs.insertSorted(kept.dump.seq)

        if kept.dump.kind == .dd {
            ddCount += 1
        }

        if let pattern = kept.pattern {
            queries.add(kept.dump, pattern: pattern)
        }
    }

    mutating func remove(_ kept: KeptDump) {
        numbers.removeSorted(kept.number)
        seqs.removeSorted(kept.dump.seq)

        if kept.dump.kind == .dd {
            ddCount -= 1
        }

        if let pattern = kept.pattern {
            queries.remove(kept.dump, pattern: pattern)
        }
    }

    // A request without entries has no numbers and no seqs. So a start that reads the file
    // again gives it the same values.
    func apply(to header: inout DumpedRequest) {
        header.firstNumber = numbers.first ?? 0
        header.lastNumber = numbers.last ?? 0
        header.firstSeq = seqs.first ?? 0
        header.hasDD = ddCount > 0
        header.marks = queries.marks
        header.queryMilliseconds = queries.milliseconds

        if numbers.isEmpty {
            header.lastSeq = 0
        }
    }
}

extension RandomAccessCollection where Index == Int {
    // The first index where isAbove is true. isAbove is false for a first part of the collection
    // and true for the rest.
    func partitionIndex(where isAbove: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex

        while low < high {
            let middle = low + (high - low) / 2

            if isAbove(self[middle]) {
                high = middle
                continue
            }

            low = middle + 1
        }

        return low
    }
}

extension Array where Element == Int {
    // The new number of a request is its highest. So this adds it at the end without a move.
    mutating func insertSorted(_ value: Int) {
        if last.map({ highest in highest < value }) ?? true {
            append(value)
            return
        }

        insert(value, at: partitionIndex { element in element >= value })
    }

    mutating func removeSorted(_ value: Int) {
        let index = partitionIndex { element in element >= value }

        if index < count, self[index] == value {
            remove(at: index)
        }
    }
}

struct StoreState {
    enum Joined {
        case refused
        case joined
        case shown(headerLine: Data)
    }

    struct DumpKey: Hashable {
        let requestID: String
        let seq: Int

        init(_ dump: CaughtDump) {
            requestID = dump.requestID
            seq = dump.seq
        }
    }

    var requests: [String: DumpedRequest] = [:]
    // The ids of the list in the order of their first entry. So a request that shows later is
    // always the newest.
    var order: [String] = []
    // The oldest first.
    var waiting: [DumpedRequest] = []
    var dumps = KeptEntries()
    // The readers of all connections share the lock. So a new dump finds a dump that the store
    // already has without a walk through all dumps.
    var dumpKeys: Set<DumpKey> = []
    var dumpBytes = 0
    // The bytes of the header line of each request of the list.
    var headerBytes: [String: Int] = [:]
    var fileBytes = 0
    var lastNumber = 0
    var epoch = ""
    var isLoaded = false
    var changed: [String] = []
    var removed: [String] = []
    var removedDumps: [Int] = []
    var cleared = false
    // The kept entries of each request of the list, for the values of its header.
    var entriesOf: [String: RequestEntries] = [:]
    // The request of each kept job row with a ref, by that ref. A job of a worker finds the request
    // that queued it here.
    var jobRows: [String: String] = [:]

    // The bytes that a rewrite writes.
    var keptBytes: Int {
        headerBytes.values.reduce(dumpBytes, +)
    }

    var fileIsLarge: Bool {
        if fileBytes <= DumpStore.byteLimit {
            return false
        }

        return keptBytes * 2 < fileBytes
    }

    var allHeaders: [DumpedRequest] {
        order.compactMap { id in requests[id] } + waiting
    }

    var cursor: DumpCursor? {
        isLoaded ? DumpCursor(epoch: epoch, number: lastNumber) : nil
    }

    static func newEpoch() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    func knows(_ id: String) -> Bool {
        if requests[id] != nil {
            return true
        }

        return waiting.contains { header in header.id == id }
    }

    // newHeader is the header for a request that the store does not know. A dump that the store
    // already has is refused. So each id stays unique.
    mutating func join(_ kept: KeptDump, newHeader: DumpedRequest?) -> Joined {
        let requestID = kept.dump.requestID

        if dumpKeys.contains(DumpKey(kept.dump)) {
            return .refused
        }

        var headerLine: Data?

        if requests[requestID] == nil {
            guard let header = takeWaiting(requestID) ?? newHeader else {
                return .refused
            }

            headerLine = show(queued(header))
        }

        lastNumber = max(lastNumber, kept.number)
        keep(kept)
        removeOldDumps()

        guard let headerLine else {
            return .joined
        }

        return .shown(headerLine: headerLine)
    }

    // A job row can arrive after the job of the worker shows. Its ref is the uuid of that job. Each
    // such job of the list gets the request of the row as its queuedBy. The list holds at most 500
    // requests. So the walk stays short. Returns the header lines of the changed jobs.
    mutating func linkJobs(queuedBy row: CaughtDump) -> [Data] {
        guard row.kind == .job, let ref = row.ref else {
            return []
        }

        var lines: [Data] = []

        for id in order where id != row.requestID {
            guard var header = requests[id], header.job?.uuid == ref, header.job?.queuedBy == nil else {
                continue
            }

            header.job?.queuedBy = row.requestID
            requests[id] = header
            markChanged(id)
            lines.append(headerLine(of: header))
        }

        return lines
    }

    // A job of a worker that shows after the job row of the request that queued it.
    private func queued(_ header: DumpedRequest) -> DumpedRequest {
        guard let uuid = header.job?.uuid, header.job?.queuedBy == nil else {
            return header
        }

        guard let queuedBy = jobRows[uuid], queuedBy != header.id else {
            return header
        }

        var linked = header
        linked.job?.queuedBy = queuedBy
        return linked
    }

    // Returns the header line for the file when the request is in the list. Only the end of a job
    // has an outcome. A job of a worker that is not in the list shows at its end, also without
    // entries. So the list shows each job that ran. The end of a job comes in the order of the run.
    // So the job gets its right place in the list.
    mutating func end(_ id: String, _ end: RequestEnd, newHeader: DumpedRequest?) -> Data? {
        guard var header = requests[id] ?? waiting.first(where: { waitingHeader in waitingHeader.id == id }) ?? newHeader else {
            return nil
        }

        header.status = end.status
        header.exitCode = end.exitCode
        header.duration = end.duration

        if let outcome = end.outcome {
            header.job?.outcome = outcome
        }

        if let droppedQueries = end.droppedQueries {
            header.droppedQueries = droppedQueries
        }

        guard requests[id] == nil, header.staysInList else {
            return update(header)
        }

        _ = takeWaiting(id)
        let line = show(queued(header))
        markChanged(id)
        removeOldDumps()
        return line
    }

    // Returns the header line for the file when the location of a request of the list changed.
    mutating func move(_ id: String, to location: DumpLocation) -> Data? {
        if let index = waiting.firstIndex(where: { header in header.id == id }) {
            waiting[index].location = location
            return nil
        }

        guard var header = requests[id] else {
            return nil
        }

        if header.location == location {
            return nil
        }

        header.location = location
        return update(header)
    }

    // A header in the file belongs to a request of the list. A rewrite puts all headers before the
    // dumps. So the header of an unknown request shows it at once. lineBytes counts the new line
    // too, as an added line does.
    mutating func replay(_ record: Record, lineBytes: Int) {
        if let header = record.request {
            replayHeader(header)
        }

        if var dump = record.dump {
            dump.number = record.number ?? lastNumber + 1
            _ = join(KeptDump(dump: dump, bytes: lineBytes, pattern: KeptDump.pattern(of: dump)), newHeader: nil)
            return
        }

        if let epoch = record.epoch {
            self.epoch = epoch
        }

        if let number = record.number {
            lastNumber = max(lastNumber, number)
        }
    }

    // A request that does not stay in the list comes only from a damaged file. Returns true when it
    // removed one.
    mutating func removeRequestsWithoutDumps() -> Bool {
        let empty = order.filter { id in requests[id]?.staysInList == false }
        removeRequests(empty)
        return !empty.isEmpty
    }

    // Returns the number of removed entries and requests. A clear of all that removes an entry gives
    // a new epoch. So a client with a cursor of before the clear starts again with the newest
    // requests.
    mutating func remove(place: DumpPlace?) -> (entries: Int, requests: Int) {
        guard let place else {
            let removed = (entries: dumps.count, requests: order.count)
            var empty = StoreState()
            empty.fileBytes = fileBytes
            empty.lastNumber = lastNumber
            empty.isLoaded = isLoaded
            empty.epoch = removed.entries > 0 ? Self.newEpoch() : epoch
            empty.cleared = true
            self = empty
            return removed
        }

        waiting.removeAll { header in header.place == place }
        let ids = order.filter { id in requests[id]?.place == place }
        return (removeRequestsWithTheirDumps(ids), ids.count)
    }

    // Returns the number of removed entries. An id that is not in the list removes nothing. The
    // limits call this for each new request at the limit. The store knows the numbers of each
    // request. So only the entries up to the newest entry of these requests move. The keys, the
    // bytes and the job rows of the removed entries go one by one.
    mutating func removeRequestsWithTheirDumps(_ ids: [String]) -> Int {
        let listed = ids.filter { id in requests[id] != nil }

        if listed.isEmpty {
            return 0
        }

        let numbers = listed.flatMap { id in entriesOf[id]?.numbers ?? [] }.sorted()
        let gone = dumps.remove(numbers: numbers)

        for kept in gone {
            dumpKeys.remove(DumpKey(kept.dump))
            dumpBytes -= kept.bytes
            forgetJobRow(of: kept)
        }

        removeRequests(listed)
        return gone.count
    }

    // The request gets the counts of the entries that stay. The app removes the entry with its
    // number from the entries that it shows.
    mutating func removeDump(number: Int) -> Bool {
        guard let kept = dumps.remove(numbers: [number]).first else {
            return false
        }

        dumpBytes -= kept.bytes
        removedDumps.append(kept.number)
        forget([kept])
        return true
    }

    // Each header comes once, in the order of the first dump of its request in the batch.
    func batch(of kept: some Sequence<KeptDump>, olderCounts: [String: Int] = [:]) -> DumpBatch {
        var dumps: [CaughtDump] = []
        var headers: [DumpedRequest] = []
        var seen: Set<String> = []

        for dump in kept.map(\.dump) {
            dumps.append(dump)

            if seen.insert(dump.requestID).inserted, let header = requests[dump.requestID] {
                headers.append(header)
            }
        }

        return DumpBatch(dumps: dumps, requests: headers, cursor: DumpCursor(epoch: epoch, number: lastNumber), olderCounts: olderCounts)
    }

    mutating func takeChanges() -> DumpChange {
        defer { forgetChanges() }

        return DumpChange(changed: changed.compactMap { id in requests[id] }, removed: removed, cleared: cleared, removedDumps: removedDumps)
    }

    mutating func forgetChanges() {
        changed = []
        removed = []
        removedDumps = []
        cleared = false
    }

    // A header from the file or from an end event. The store counts the entries itself. A request
    // that is not in the list waits for its first entry.
    private mutating func update(_ header: DumpedRequest) -> Data? {
        guard let current = requests[header.id] else {
            wait(header)
            return nil
        }

        var updated = header
        updated.take(countsOf: current)
        requests[header.id] = updated
        markChanged(header.id)
        return headerLine(of: updated)
    }

    // The header of a new request comes where the request showed: before its first entry, or at
    // the end of a job without entries. So the limit of the requests acts at the same place as it
    // did before the start.
    private mutating func replayHeader(_ header: DumpedRequest) {
        if requests[header.id] == nil {
            _ = show(header)
            removeOldDumps()
            return
        }

        _ = update(header)
    }

    private mutating func show(_ header: DumpedRequest) -> Data {
        let shown = header.uncounted
        requests[shown.id] = shown
        order.append(shown.id)

        // A request that comes back after a removal in the same group of changes stays in removed.
        // DumpChange.apply removes it first and then puts it at the top, as the order of the store
        // has it.
        return headerLine(of: shown)
    }

    private mutating func headerLine(of header: DumpedRequest) -> Data {
        let line = Record.line(header: header)
        headerBytes[header.id] = line.count
        return line
    }

    private mutating func keep(_ kept: KeptDump) {
        let requestID = kept.dump.requestID

        dumps.append(kept)
        dumpKeys.insert(DumpKey(kept.dump))
        dumpBytes += kept.bytes

        if kept.dump.kind == .job, let ref = kept.dump.ref {
            jobRows[ref] = requestID
        }

        guard var header = requests[requestID] else {
            return
        }

        var entries = entriesOf[requestID] ?? RequestEntries()
        entries.add(kept)
        header.lastSeq = max(header.lastSeq, kept.dump.seq)
        header.count(kept.dump, by: 1)
        entries.apply(to: &header)
        entriesOf[requestID] = entries
        requests[requestID] = header
        markChanged(requestID)
    }

    private mutating func wait(_ header: DumpedRequest) {
        if let index = waiting.firstIndex(where: { waitingHeader in waitingHeader.id == header.id }) {
            waiting[index] = header
            return
        }

        waiting.append(header)

        if waiting.count > DumpStore.waitingLimit {
            waiting.removeFirst()
        }
    }

    private mutating func takeWaiting(_ id: String) -> DumpedRequest? {
        guard let index = waiting.firstIndex(where: { header in header.id == id }) else {
            return nil
        }

        return waiting.remove(at: index)
    }

    // While the list has more than requestLimit requests, the oldest request goes with all its
    // entries. A job without entries counts too. Then the oldest entries go while the entries take
    // more than byteLimit bytes. A request goes from the list when it does not stay (staysInList).
    private mutating func removeOldDumps() {
        while order.count > DumpStore.requestLimit {
            _ = removeRequestsWithTheirDumps([order[0]])
        }

        var count = 0
        var bytes = dumpBytes

        while count < dumps.count, bytes > DumpStore.byteLimit {
            bytes -= dumps[count].bytes
            count += 1
        }

        if count == 0 {
            return
        }

        let old = Array(dumps.prefix(count))
        dumps.removeFirst(count)
        dumpBytes = bytes
        forget(old)
    }

    // The entries are out of dumps already. Their requests get the values of the entries that
    // stay. A request that does not stay in the list goes, for example a request without entries.
    // A job that ended stays.
    private mutating func forget(_ removed: [KeptDump]) {
        var gone: [String] = []

        for kept in removed {
            let requestID = kept.dump.requestID

            dumpKeys.remove(DumpKey(kept.dump))
            forgetJobRow(of: kept)

            guard var header = requests[requestID] else {
                continue
            }

            var entries = entriesOf[requestID] ?? RequestEntries()
            entries.remove(kept)
            header.count(kept.dump, by: -1)
            entries.apply(to: &header)
            entriesOf[requestID] = entries
            requests[requestID] = header
            markChanged(requestID)

            if !header.staysInList {
                gone.append(requestID)
            }
        }

        removeRequests(gone)
    }

    private mutating func forgetJobRow(of kept: KeptDump) {
        guard kept.dump.kind == .job, let ref = kept.dump.ref, jobRows[ref] == kept.dump.requestID else {
            return
        }

        jobRows[ref] = nil
    }

    private mutating func removeRequests(_ ids: [String]) {
        if ids.isEmpty {
            return
        }

        let removedIDs = Set(ids)
        order.removeAll { id in removedIDs.contains(id) }

        for id in ids {
            requests[id] = nil
            headerBytes[id] = nil
            entriesOf[id] = nil
            markRemoved(id)
        }
    }

    private mutating func markChanged(_ id: String) {
        if changed.contains(id) {
            return
        }

        changed.append(id)
    }

    private mutating func markRemoved(_ id: String) {
        changed.removeAll { changedID in changedID == id }

        if removed.contains(id) {
            return
        }

        removed.append(id)
    }
}
