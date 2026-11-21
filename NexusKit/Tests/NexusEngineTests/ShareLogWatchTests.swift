import Foundation
import NexusCore
import Synchronization
import Testing
@testable import NexusEngine

private final class Arrivals: Sendable {
    private let arrivals = Mutex<[(id: String, lines: [ShareLogLine])]>([])

    func add(_ id: String, _ lines: [ShareLogLine]) {
        arrivals.withLock { $0.append((id, lines)) }
    }

    var lines: [ShareLogLine] {
        arrivals.withLock { $0.flatMap(\.lines) }
    }

    var ids: [String] {
        arrivals.withLock { $0.map(\.id) }
    }
}

private final class Spots: Sendable {
    private let lines = Mutex<[ShareLogWatch.Line]>([])

    func add(_ new: [ShareLogWatch.Line]) {
        lines.withLock { $0 += new }
    }

    var all: [ShareLogWatch.Line] {
        lines.withLock { $0 }
    }
}

struct ShareLogWatchTests {
    @Test func eachLineCanBeReadAgainAtItsSpotAfterAHalfLineAndABrokenLine() async throws {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "share-abc.jsonl")
        let spots = Spots()
        let watch = ShareLogWatch { spots.add($1) }
        defer { watch.stop() }
        let second = line("second")

        watch.watch([log.path(percentEncoded: false): "abc"])
        try append(line("first") + "{broken\n" + second.prefix(20), to: log)
        #expect(await eventually { spots.all.count == 1 })
        try append(String(second.dropFirst(20)) + line("third"), to: log)

        #expect(await eventually { spots.all.count == 3 })
        #expect(spots.all.map { ShareLogWatch.line(at: $0.spot, in: log)?.request } == ["first", "second", "third"])
    }

    private func append(_ text: String, to file: URL) throws {
        try writeAtEnd(text, of: file)
    }

    private func line(_ request: String, visitor: String = "203.0.113.7") -> String {
        visitorLine(request, visitor: visitor)
    }

    @Test func twoLinesArriveWithTheirIDInTheirOrder() async throws {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "share-abc.jsonl")
        let arrivals = Arrivals()
        let watch = ShareLogWatch { arrivals.add($0, $1.map(\.line)) }
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "abc"])
        try append(line("first") + line("second", visitor: ""), to: log)

        #expect(await eventually { arrivals.lines.count == 2 })
        #expect(arrivals.lines.map(\.request) == ["first", "second"])
        #expect(arrivals.lines.map(\.visitor) == ["203.0.113.7", ""])
        #expect(Set(arrivals.ids) == ["abc"])
    }

    @Test func aHalfLineWaitsForItsEndAndABrokenLineIsSkipped() async throws {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "share-abc.jsonl")
        let arrivals = Arrivals()
        let watch = ShareLogWatch { arrivals.add($0, $1.map(\.line)) }
        defer { watch.stop() }
        let whole = line("long")

        watch.watch([log.path(percentEncoded: false): "abc"])
        try append("not json\n" + String(whole.prefix(20)), to: log)
        try await Task.sleep(for: .milliseconds(300))
        let beforeEnd = arrivals.lines.count
        try append(String(whole.dropFirst(20)), to: log)

        #expect(beforeEnd == 0)
        #expect(await eventually { arrivals.lines.count == 1 })
        #expect(arrivals.lines.first?.request == "long")
    }

    @Test func aLongLineArrivesWhole() async throws {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "share-abc.jsonl")
        let arrivals = Arrivals()
        let watch = ShareLogWatch { arrivals.add($0, $1.map(\.line)) }
        defer { watch.stop() }
        let request = String(repeating: "a", count: 200_000)

        watch.watch([log.path(percentEncoded: false): "abc"])
        try append(line(request), to: log)

        #expect(await eventually { arrivals.lines.count == 1 })
        #expect(arrivals.lines.first?.request.count == 200_000)
    }

    @Test func aLogThatGoesAwayGivesNoMoreLines() async throws {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "share-abc.jsonl")
        let arrivals = Arrivals()
        let watch = ShareLogWatch { arrivals.add($0, $1.map(\.line)) }
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "abc"])
        try append(line("first"), to: log)
        #expect(await eventually { arrivals.lines.count == 1 })

        try FileManager.default.removeItem(at: log)
        try await Task.sleep(for: .milliseconds(200))
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: Data(line("late").utf8))
        try await Task.sleep(for: .milliseconds(500))

        #expect(arrivals.lines.count == 1)
    }
}
