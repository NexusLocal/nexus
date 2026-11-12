import Foundation
import NexusCore
import Synchronization

// The caught dumps in memory and in logs/dumps.jsonl. The list holds only the request headers. The
// dumps of a request are flat records next to it. So a change of the list never copies them. A
// request shows in the list from its first dump on and goes with its last dump.
//
// The lock guards only the memory. DumpFile writes the file on its own queue. So list and dumps
// never wait for the disk. Each change adds lines to the file. A start reads the lines again in
// their order and gets the same store, because the same limits remove the same old dumps. The
// file gets only the kept records when it is larger than 10 MB and the kept records take less than
// half of it.
public final class DumpStore: Sendable {
    public static let dumpLimit = 1000
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
            add(dump, of: request)
        case .end(let request, let status, let exitCode, let duration):
            change(request) { state, newHeader in
                state.end(request.id, status: status, exitCode: exitCode, duration: duration, newHeader: newHeader).map { line in [line] } ?? []
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

    // The dumps of one request with a number above afterNumber, in the order in which they arrived.
    // A dump with a lower seq that arrives later has a higher number. So it comes too. 0 gives all
    // dumps of the request.
    public func dumps(request: String, afterNumber: Int = 0) -> [CaughtDump] {
        state.withLock { state in
            state.dumps
                .filter { kept in kept.dump.requestID == request && kept.number > afterNumber }
                .map(\.dump)
        }
    }

    public func dump(number: Int) -> CaughtDump? {
        state.withLock { state in
            state.dumps.first { kept in kept.number == number }?.dump
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
            let end = state.dumps.lastIndex { kept in kept.number <= through.number }.map { index in index + 1 } ?? 0
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

            var olderCounts: [String: Int] = [:]

            for kept in state.dumps[..<end] where kept.number < firstShown[kept.dump.requestID] ?? Int.min {
                olderCounts[kept.dump.requestID, default: 0] += 1
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

            let first = state.dumps.lastIndex { kept in kept.number <= cursor.number }.map { index in index + 1 } ?? 0
            let new = state.dumps[first...].filter { kept in
                state.requests[kept.dump.requestID].map { request in place.includes(request.place) } ?? false
            }

            return state.batch(of: new)
        }
    }

    // Returns the number of removed dumps. nil removes the requests of every place.
    @discardableResult
    public func clear(place: DumpPlace? = nil) -> Int {
        state.withLock { state in
            let removedDumps = state.remove(place: place)

            if removedDumps > 0 {
                rewrite(&state)
            }

            return removedDumps
        }
    }

    // Removes the dump with this number of the store. A request without dumps goes from the list.
    // Returns false when the store has no such dump.
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

    // Removes one request with all its dumps. Returns the number of removed dumps, or nil when the
    // list has no such request.
    @discardableResult
    public func remove(request id: String) -> Int? {
        state.withLock { state in
            guard state.requests[id] != nil else {
                return nil
            }

            let removedDumps = state.removeRequestsWithTheirDumps([id])
            rewrite(&state)
            return removedDumps
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

    // The JSON of the dump is the large part of its line. So it is made outside the lock. Inside
    // the lock the line gets its number.
    private func add(_ dump: CaughtDump, of request: DumpEnvelope) {
        guard var line = Record.openLine(dump: dump) else {
            return
        }

        change(request) { state, newHeader in
            var numbered = dump
            numbered.number = state.lastNumber + 1
            Record.close(&line, number: numbered.number)

            switch state.join(KeptDump(dump: numbered, bytes: line.count), newHeader: newHeader) {
            case .refused: return []
            case .joined: return [line]
            case .shown(let headerLine): return [headerLine, line]
            }
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
    let dumps: [KeptDump]
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

    // The store counts the dumps of a request itself. So a header in the file has no counts. Its
    // line then keeps its size when a dump arrives.
    static func line(header: DumpedRequest) -> Data {
        var uncounted = header
        uncounted.dumpCount = 0
        uncounted.hasDD = false
        uncounted.lastSeq = 0
        uncounted.firstSeq = 0
        uncounted.lastNumber = 0
        uncounted.firstNumber = 0
        return line(Record(request: uncounted)) ?? Data()
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

// The dump has its number.
struct KeptDump: Sendable {
    let dump: CaughtDump
    // The bytes of its line in the file. The limit of 10 MB counts these.
    let bytes: Int

    var number: Int {
        dump.number
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
    // The ids of the list in the order of their first dump. So a request that shows later is
    // always the newest.
    var order: [String] = []
    // The oldest first.
    var waiting: [DumpedRequest] = []
    var dumps: [KeptDump] = []
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

            headerLine = show(header)
        }

        lastNumber = max(lastNumber, kept.number)
        keep(kept)
        removeOldDumps()

        guard let headerLine else {
            return .joined
        }

        return .shown(headerLine: headerLine)
    }

    // Returns the header line for the file when the request is in the list.
    mutating func end(_ id: String, status: Int?, exitCode: Int?, duration: TimeInterval?, newHeader: DumpedRequest?) -> Data? {
        guard var header = requests[id] ?? waiting.first(where: { waitingHeader in waitingHeader.id == id }) ?? newHeader else {
            return nil
        }

        header.status = status
        header.exitCode = exitCode
        header.duration = duration
        return update(header)
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
            _ = join(KeptDump(dump: dump, bytes: lineBytes), newHeader: nil)
            return
        }

        if let epoch = record.epoch {
            self.epoch = epoch
        }

        if let number = record.number {
            lastNumber = max(lastNumber, number)
        }
    }

    // A header without a dump comes only from a damaged file. Returns true when it removed one.
    mutating func removeRequestsWithoutDumps() -> Bool {
        let empty = order.filter { id in requests[id]?.dumpCount == 0 }
        removeRequests(empty)
        return !empty.isEmpty
    }

    // Returns the number of removed dumps. A clear of all that removes a dump gives a new epoch.
    // So a client with a cursor of before the clear starts again with the newest requests. Only
    // such a clear writes the file again with the new epoch.
    mutating func remove(place: DumpPlace?) -> Int {
        guard let place else {
            let removedDumps = dumps.count
            var empty = StoreState()
            empty.fileBytes = fileBytes
            empty.lastNumber = lastNumber
            empty.isLoaded = isLoaded
            empty.epoch = removedDumps > 0 ? Self.newEpoch() : epoch
            empty.cleared = true
            self = empty
            return removedDumps
        }

        waiting.removeAll { header in header.place == place }
        return removeRequestsWithTheirDumps(order.filter { id in requests[id]?.place == place })
    }

    // Returns the number of removed dumps. An id that is not in the list removes nothing.
    mutating func removeRequestsWithTheirDumps(_ ids: [String]) -> Int {
        let listed = ids.filter { id in requests[id] != nil }

        if listed.isEmpty {
            return 0
        }

        let removedIDs = Set(listed)
        let before = dumps.count

        dumps.removeAll { kept in removedIDs.contains(kept.dump.requestID) }
        dumpKeys = Set(dumps.map { kept in DumpKey(kept.dump) })
        dumpBytes = dumps.reduce(0) { total, kept in total + kept.bytes }
        removeRequests(listed)
        return before - dumps.count
    }

    // The request gets the counts of the dumps that stay. The app removes the dump with its id
    // from the dumps that it shows.
    mutating func removeDump(number: Int) -> Bool {
        guard let index = dumps.firstIndex(where: { kept in kept.number == number }) else {
            return false
        }

        let kept = dumps.remove(at: index)
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

    // A header from the file or from an end event. The store counts the dumps itself. A request
    // that is not in the list waits for its first dump.
    private mutating func update(_ header: DumpedRequest) -> Data? {
        guard let current = requests[header.id] else {
            wait(header)
            return nil
        }

        var updated = header
        updated.dumpCount = current.dumpCount
        updated.hasDD = current.hasDD
        updated.lastSeq = current.lastSeq
        updated.firstSeq = current.firstSeq
        updated.lastNumber = current.lastNumber
        updated.firstNumber = current.firstNumber
        requests[header.id] = updated
        markChanged(header.id)
        return headerLine(of: updated)
    }

    private mutating func replayHeader(_ header: DumpedRequest) {
        if requests[header.id] == nil {
            _ = show(header)
            return
        }

        _ = update(header)
    }

    private mutating func show(_ header: DumpedRequest) -> Data {
        var shown = header
        shown.dumpCount = 0
        shown.hasDD = false
        shown.lastSeq = 0
        shown.firstSeq = 0
        shown.lastNumber = 0
        shown.firstNumber = 0
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

        guard let current = requests[requestID] else {
            return
        }

        requests[requestID]?.lastSeq = max(current.lastSeq, kept.dump.seq)
        requests[requestID]?.firstSeq = current.dumpCount == 0 ? kept.dump.seq : min(current.firstSeq, kept.dump.seq)
        requests[requestID]?.lastNumber = kept.number
        requests[requestID]?.firstNumber = current.dumpCount == 0 ? kept.number : current.firstNumber
        requests[requestID]?.dumpCount += 1

        if kept.dump.kind == .dd {
            requests[requestID]?.hasDD = true
        }

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

    // The oldest dumps go first.
    private mutating func removeOldDumps() {
        var count = 0
        var bytes = dumpBytes

        while Self.isOverLimit(count: dumps.count - count, bytes: bytes) {
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

    // The dumps are out of dumps already. Their requests get the counts of the dumps that stay. A
    // request without dumps goes from the list.
    private mutating func forget(_ removed: [KeptDump]) {
        var emptied: [String] = []
        var touched: Set<String> = []

        for kept in removed {
            let requestID = kept.dump.requestID

            dumpKeys.remove(DumpKey(kept.dump))
            requests[requestID]?.dumpCount -= 1
            markChanged(requestID)
            touched.insert(requestID)

            if requests[requestID]?.dumpCount == 0 {
                emptied.append(requestID)
            }
        }

        recount(touched)
        removeRequests(emptied)
    }

    // A dump with a lower seq can arrive after a higher one. So firstSeq is the lowest seq of the
    // dumps that stay. The dumps are in the order of their numbers. So the first kept dump of a
    // request has its lowest number and the last kept dump its highest. One walk over the kept
    // dumps finds them for each touched request. lastSeq stays, as DumpedRequest says.
    private mutating func recount(_ touched: Set<String>) {
        var lowestSeq: [String: Int] = [:]
        var lowestNumber: [String: Int] = [:]
        var highestNumber: [String: Int] = [:]
        var withDD: Set<String> = []

        for kept in dumps where touched.contains(kept.dump.requestID) {
            let requestID = kept.dump.requestID
            lowestSeq[requestID] = min(lowestSeq[requestID] ?? kept.dump.seq, kept.dump.seq)
            lowestNumber[requestID] = lowestNumber[requestID] ?? kept.number
            highestNumber[requestID] = kept.number

            if kept.dump.kind == .dd {
                withDD.insert(requestID)
            }
        }

        for requestID in touched where requests[requestID]?.dumpCount ?? 0 > 0 {
            requests[requestID]?.firstSeq = lowestSeq[requestID] ?? 0
            requests[requestID]?.firstNumber = lowestNumber[requestID] ?? 0
            requests[requestID]?.lastNumber = highestNumber[requestID] ?? 0
            requests[requestID]?.hasDD = withDD.contains(requestID)
        }
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

    private static func isOverLimit(count: Int, bytes: Int) -> Bool {
        if count > DumpStore.dumpLimit {
            return true
        }

        return bytes > DumpStore.byteLimit
    }
}
