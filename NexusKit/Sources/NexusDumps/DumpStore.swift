import Foundation
import NexusCore
import Synchronization

// The site or the workspace of a request. Part 7 finds it from the host and the root. A filter
// with a place gives only the requests with the same site and the same workspace.
public struct DumpPlace: Sendable, Equatable {
    public var site: String?
    public var workspace: String?

    public init(site: String? = nil, workspace: String? = nil) {
        self.site = site
        self.workspace = workspace
    }
}

extension DumpedRequest {
    var place: DumpPlace {
        DumpPlace(site: site, workspace: workspace)
    }
}

// What changed since the last call of takeChanges. cleared means that the store removed all
// requests before the other changes. removed holds each removed id. The app ignores an id that it
// does not have.
public struct DumpStoreChanges: Sendable, Equatable {
    public var changed: [DumpedRequest]
    public var removed: [String]
    public var cleared: Bool

    public init(changed: [DumpedRequest] = [], removed: [String] = [], cleared: Bool = false) {
        self.changed = changed
        self.removed = removed
        self.cleared = cleared
    }

    public var isEmpty: Bool {
        changed.isEmpty && removed.isEmpty && !cleared
    }
}

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
    private let locate: @Sendable (DumpedRequest) -> DumpPlace
    private let state = Mutex(StoreState())

    // locate runs outside the lock of the store. So it can read other state of nexusd. It runs
    // only for a new request and in relocate.
    public init(file: URL, locate: @escaping @Sendable (DumpedRequest) -> DumpPlace = { _ in DumpPlace() }) {
        writer = DumpFile(url: file)
        self.locate = locate
    }

    public var file: URL {
        writer.url
    }

    // A line that does not decode is skipped. An example is the cut last line after a crash. The
    // file then gets only the kept records. So the next line does not join the cut one.
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
        state.withLock { state in
            state.order.reversed()
                .compactMap { id in state.requests[id] }
                .filter { request in StoreState.request(request, isIn: place) }
        }
    }

    // The dumps of one request in the order in which they arrived. A watcher gives the last seq
    // that it has and gets only the newer dumps.
    public func dumps(request: String, after seq: Int = 0) -> [CaughtDump] {
        state.withLock { state in
            state.dumps
                .filter { kept in kept.dump.requestID == request }
                .filter { kept in kept.dump.seq > seq }
                .map(\.dump)
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

    // Part 7 calls this when a site or a workspace changes. Each request gets the place that
    // locate gives now.
    public func relocate() {
        let headers = state.withLock { state in state.allHeaders }
        let places = headers.map { header in (id: header.id, place: locate(header)) }

        state.withLock { state in
            let lines = places.compactMap { moved in state.move(moved.id, to: moved.place) }
            write(lines, into: &state)
        }
    }

    // Part 7 groups the changes and sends them to the app.
    public func takeChanges() -> DumpStoreChanges {
        state.withLock { state in
            state.takeChanges()
        }
    }

    // For a clean shutdown and for the tests.
    public func waitForWrites() {
        writer.waitForWrites()
    }

    private func add(_ dump: CaughtDump, of request: DumpEnvelope) {
        guard let line = Record.line(dump: dump) else {
            return
        }

        let kept = KeptDump(dump: dump, bytes: line.count)

        change(request) { state, newHeader in
            switch state.join(kept, newHeader: newHeader) {
            case .refused: []
            case .joined: [line]
            case .shown(let headerLine): [headerLine, line]
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
            let place = locate(placed)
            placed.site = place.site
            placed.workspace = place.workspace
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
        writer.rewrite(DumpSnapshot(order: state.order, requests: state.requests, dumps: state.dumps, bytes: state.keptBytes))
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
        queue.async { [self] in
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

// The kept records at the time of a rewrite. The headers come first in the order of the list. A
// load then gives the requests the same order, also when the limits removed the first dump of a
// request. The dumps follow in the order in which they arrived.
struct DumpSnapshot: Sendable {
    let order: [String]
    let requests: [String: DumpedRequest]
    let dumps: [KeptDump]
    let bytes: Int

    func encoded() -> Data {
        var data = Data(capacity: bytes)

        for id in order {
            if let header = requests[id] {
                data.append(Record.line(header: header))
            }
        }

        for kept in dumps {
            data.append(Record.line(dump: kept.dump) ?? Data())
        }

        return data
    }
}

// A line of logs/dumps.jsonl holds a request header or a dump.
struct Record: Codable {
    var request: DumpedRequest?
    var dump: CaughtDump?

    // The store counts the dumps of a request itself. So a header in the file has no counts. Its
    // line then keeps its size when a dump arrives.
    static func line(header: DumpedRequest) -> Data {
        var uncounted = header
        uncounted.dumpCount = 0
        uncounted.hasDD = false
        return line(Record(request: uncounted)) ?? Data()
    }

    static func line(dump: CaughtDump) -> Data? {
        line(Record(dump: dump))
    }

    private static func line(_ record: Record) -> Data? {
        guard var data = try? DumpCoding.encoder.encode(record) else {
            return nil
        }

        data.append(UInt8(ascii: "\n"))
        return data
    }
}

struct KeptDump: Sendable {
    let dump: CaughtDump
    // The bytes of its line in the file. The limit of 10 MB counts these.
    let bytes: Int
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
    var changed: [String] = []
    var removed: [String] = []
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

    // Returns the header line for the file when the place of a request of the list changed.
    mutating func move(_ id: String, to place: DumpPlace) -> Data? {
        if let index = waiting.firstIndex(where: { header in header.id == id }) {
            waiting[index].site = place.site
            waiting[index].workspace = place.workspace
            return nil
        }

        guard var header = requests[id] else {
            return nil
        }

        if header.place == place {
            return nil
        }

        header.site = place.site
        header.workspace = place.workspace
        return update(header)
    }

    // A header in the file belongs to a request of the list. A rewrite puts all headers before the
    // dumps. So the header of an unknown request shows it at once. lineBytes counts the new line
    // too, as an added line does.
    mutating func replay(_ record: Record, lineBytes: Int) {
        if let header = record.request {
            replayHeader(header)
        }

        if let dump = record.dump {
            _ = join(KeptDump(dump: dump, bytes: lineBytes), newHeader: nil)
        }
    }

    // A header without a dump comes only from a damaged file. Returns true when it removed one.
    mutating func removeRequestsWithoutDumps() -> Bool {
        let empty = order.filter { id in requests[id]?.dumpCount == 0 }
        removeRequests(empty)
        return !empty.isEmpty
    }

    // Returns the number of removed dumps.
    mutating func remove(place: DumpPlace?) -> Int {
        guard let place else {
            let removedDumps = dumps.count
            let bytes = fileBytes
            self = StoreState()
            fileBytes = bytes
            cleared = true
            return removedDumps
        }

        let ids = order.filter { id in requests[id]?.place == place }
        let removedIDs = Set(ids)
        let before = dumps.count

        dumps.removeAll { kept in removedIDs.contains(kept.dump.requestID) }
        dumpKeys = Set(dumps.map { kept in DumpKey(kept.dump) })
        dumpBytes = dumps.reduce(0) { total, kept in total + kept.bytes }
        waiting.removeAll { header in header.place == place }
        removeRequests(ids)
        return before - dumps.count
    }

    mutating func takeChanges() -> DumpStoreChanges {
        defer { forgetChanges() }

        return DumpStoreChanges(changed: changed.compactMap { id in requests[id] }, removed: removed, cleared: cleared)
    }

    mutating func forgetChanges() {
        changed = []
        removed = []
        cleared = false
    }

    static func request(_ request: DumpedRequest, isIn place: DumpPlace?) -> Bool {
        guard let place else {
            return true
        }

        return request.place == place
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
        requests[shown.id] = shown
        order.append(shown.id)

        // The request is back after a removal in the same group of changes.
        removed.removeAll { id in id == shown.id }

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

        var emptied: [String] = []
        var lostDD: Set<String> = []

        for kept in dumps.prefix(count) {
            let requestID = kept.dump.requestID

            dumpKeys.remove(DumpKey(kept.dump))
            requests[requestID]?.dumpCount -= 1
            markChanged(requestID)

            if kept.dump.kind == .dd {
                lostDD.insert(requestID)
            }

            if requests[requestID]?.dumpCount == 0 {
                emptied.append(requestID)
            }
        }

        dumps.removeFirst(count)
        dumpBytes = bytes

        for requestID in lostDD {
            requests[requestID]?.hasDD = dumps.contains { kept in kept.dump.requestID == requestID && kept.dump.kind == .dd }
        }

        removeRequests(emptied)
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
