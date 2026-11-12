import Darwin
import Foundation
import NexusCore
import NexusTestSupport
import Synchronization
import Testing
@testable import NexusDumps

final class ReceivedEvents: Sendable {
    private let events = Mutex<[DumpEvent]>([])

    func append(_ event: DumpEvent) {
        events.withLock { received in received.append(event) }
    }

    var all: [DumpEvent] {
        events.withLock { received in received }
    }
}

struct DumpLineSplitterTests {
    private func bytes(_ text: String) -> ArraySlice<UInt8> {
        Array(text.utf8)[...]
    }

    @Test func linesInSeveralChunksComeOutWhole() {
        var splitter = DumpLineSplitter(maxLength: 100)

        let first = splitter.append(bytes("one\ntw"))
        let second = splitter.append(bytes("o\nthree\n"))

        #expect(first == [Data("one".utf8)])
        #expect(second == [Data("two".utf8), Data("three".utf8)])
    }

    @Test func aLineAboveTheLimitIsDroppedAndTheNextLineCounts() {
        var splitter = DumpLineSplitter(maxLength: 5)

        let first = splitter.append(bytes("abc"))
        let second = splitter.append(bytes("defgh"))
        let third = splitter.append(bytes("ijk\nfine\n"))

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third == [Data("fine".utf8)])
    }

    @Test func aLineOfExactlyTheLimitCounts() {
        var splitter = DumpLineSplitter(maxLength: 5)

        let lines = splitter.append(bytes("abcde\nabcdef\nok\n"))

        #expect(lines == [Data("abcde".utf8), Data("ok".utf8)])
    }

    @Test func aLineWithoutItsNewLineStaysInTheSplitter() {
        var splitter = DumpLineSplitter(maxLength: 100)

        let lines = splitter.append(bytes("done\nnot done"))

        #expect(lines == [Data("done".utf8)])
    }
}

@Suite(.timeLimit(.minutes(1)))
final class DumpReceiverTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "nd-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    private var receivers: [DumpReceiver] = []

    deinit {
        for receiver in receivers {
            receiver.stop()
        }

        try? FileManager.default.removeItem(at: root)
    }

    private var socket: URL {
        root.appending(path: "run/dumps.sock", directoryHint: .notDirectory)
    }

    private var folder: URL {
        root.appending(path: "run/dumps", directoryHint: .isDirectory)
    }

    private func receiver(receive: (@Sendable (DumpEvent) -> Void)? = nil) throws -> (DumpReceiver, ReceivedEvents) {
        let received = ReceivedEvents()
        let receiver = DumpReceiver(socket: socket, folder: folder, receive: receive ?? { event in received.append(event) })
        receivers.append(receiver)
        try receiver.start()
        return (receiver, received)
    }

    private func connect() throws -> Int32 {
        try DumpSocketClient.connect(to: socket)
    }

    private func write(_ text: String, to descriptor: Int32) throws {
        try DumpSocketClient.write(text, to: descriptor)
    }

    private func send(_ text: String) throws {
        try DumpSocketClient.send(text, to: socket)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        return condition()
    }

    @Test func theRealLinesOfPHPArriveInTheirOrder() async throws {
        let (_, received) = try receiver()

        try send(WireLines.all.map { line in "\(line)\n" }.joined())

        #expect(await eventually { received.all.count == WireLines.all.count })
        #expect(try received.all == WireLines.events(WireLines.all))
    }

    @Test(arguments: [
        "Warning: not a dump",
        "",
        WireLines.pageDD.replacingOccurrences(of: #"{"v":1,"#, with: #"{"v":2,"#),
    ])
    func aBadLineIsDroppedAndTheNextLineCounts(badLine: String) async throws {
        let (_, received) = try receiver()

        try send("\(badLine)\n\(WireLines.pageEnd)\n")

        #expect(await eventually { !received.all.isEmpty })
        #expect(try received.all == WireLines.events([WireLines.pageEnd]))
    }

    @Test func aLineAbove1MBIsDroppedAndTheConnectionGoesOn() async throws {
        let (_, received) = try receiver()
        let tooLong = WireLines.pageDumps[0].replacingOccurrences(of: "array:1", with: String(repeating: "x", count: DumpReceiver.maxLineBytes))

        try send("\(tooLong)\n\(WireLines.pageEnd)\n")

        #expect(await eventually { !received.all.isEmpty })
        #expect(try received.all == WireLines.events([WireLines.pageEnd]))
    }

    @Test func aCutLastLineIsDroppedWhenTheConnectionCloses() async throws {
        let (receiver, received) = try receiver()

        try send("\(WireLines.pageDD)\n\(WireLines.pageDDEnd)")

        #expect(await eventually { !received.all.isEmpty })
        #expect(await eventually { receiver.openConnections == 0 })
        #expect(try received.all == WireLines.events([WireLines.pageDD]))
    }

    @Test func theSocketIsOnlyForTheUser() throws {
        let (receiver, _) = try receiver()

        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path(percentEncoded: false))

        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(receiver.isListening)
    }

    @Test func aStartRemovesThePauseFileOfPHP() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "paused").path(percentEncoded: false), contents: nil)

        let (receiver, _) = try receiver()

        #expect(!FileManager.default.fileExists(atPath: receiver.pauseFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test func aStartReplacesTheSocketOfAnEarlierNexusd() throws {
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socket.path(percentEncoded: false), contents: Data("old".utf8))

        _ = try receiver()

        let descriptor = try connect()
        close(descriptor)
    }

    @Test func aStopEndsTheOpenConnectionsAndRemovesTheSocket() async throws {
        let (receiver, received) = try receiver()
        let descriptor = try connect()
        defer { close(descriptor) }
        try write("\(WireLines.pageEnd)\n", to: descriptor)
        #expect(await eventually { !received.all.isEmpty })

        receiver.stop()

        var byte: UInt8 = 0
        #expect(read(descriptor, &byte, 1) == 0)
        #expect(!FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
        #expect(!receiver.isListening)
    }

    @Test func aSocketPathAbove103BytesGivesAClearError() {
        let long = root.appending(path: String(repeating: "a", count: 110), directoryHint: .notDirectory)
        let receiver = DumpReceiver(socket: long, folder: folder) { _ in }

        #expect(throws: SocketError.pathTooLong(long.path(percentEncoded: false))) {
            try receiver.start()
        }
    }

    @Test func aSecondStartWhileItListensChangesNothing() throws {
        let (receiver, _) = try receiver()
        let before = SocketFile(path: socket.path(percentEncoded: false))

        try receiver.start()

        #expect(before != nil)
        #expect(SocketFile(path: socket.path(percentEncoded: false)) == before)
        #expect(receiver.isListening)
    }

    @Test func aStopKeepsTheSocketOfANewerReceiver() throws {
        let (older, _) = try receiver()
        _ = try receiver()
        let newerSocket = SocketFile(path: socket.path(percentEncoded: false))

        older.stop()

        let descriptor = try connect()
        close(descriptor)
        #expect(newerSocket != nil)
        #expect(SocketFile(path: socket.path(percentEncoded: false)) == newerSocket)
    }

    @Test func aFailedStartKeepsThePauseFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pauseFile = folder.appending(path: "paused")
        FileManager.default.createFile(atPath: pauseFile.path(percentEncoded: false), contents: nil)
        let blocked = socket.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path(percentEncoded: false)) }

        #expect(throws: SocketError.self) {
            try self.receiver()
        }
        #expect(FileManager.default.fileExists(atPath: pauseFile.path(percentEncoded: false)))
    }

    @Test func aStopWaitsForTheEventThatReceiveHandles() async throws {
        let started = ReceivedEvents()
        let finished = ReceivedEvents()
        let (receiver, _) = try receiver { event in
            started.append(event)
            Thread.sleep(forTimeInterval: 0.2)
            finished.append(event)
        }
        let descriptor = try connect()
        defer { close(descriptor) }
        try write("\(WireLines.pageDD)\n", to: descriptor)
        #expect(await eventually { !started.all.isEmpty })

        receiver.stop()

        #expect(finished.all.count == 1)
    }

    @Test func theReceiverFillsTheStore() async throws {
        let store = DumpStore(file: root.appending(path: "logs/dumps.jsonl"))
        _ = try receiver { event in store.add(event) }

        try send(WireLines.all.map { line in "\(line)\n" }.joined())

        #expect(await eventually { store.list().first?.status == 500 })
        #expect(store.list().map(\.id) == ["cf20f53412b7", "18cffb9d2606", "cc870a6df341", "7fc34bcf0060"])
        store.waitForWrites()
    }
}
