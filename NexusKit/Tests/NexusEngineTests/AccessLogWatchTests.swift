import Foundation
import Synchronization
import Testing
@testable import NexusEngine

struct AccessLogWatchTests {
    private final class Reports: Sendable {
        let owners = Mutex<[String]>([])

        var count: Int {
            owners.withLock { $0.count }
        }

        var list: [String] {
            owners.withLock { $0 }
        }
    }

    private func folder() throws -> URL {
        let folder = shortTemporaryRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func openLog(_ file: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        return handle
    }

    private func addLine(to handle: FileHandle) throws {
        try handle.write(contentsOf: Data("127.0.0.1 - - \"GET / HTTP/1.1\" 200\n".utf8))
    }

    private func watch(_ reports: Reports) -> AccessLogWatch {
        AccessLogWatch { owner in
            reports.owners.withLock { $0.append(owner) }
        }
    }

    @Test func aLineInAWatchedLogReportsItsOwner() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop.test.log")
        let handle = try openLog(log)
        defer { try? handle.close() }
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\n"])
        try addLine(to: handle)

        #expect(await eventually { reports.count == 1 })
        #expect(reports.list == ["shop\n"])
    }

    @Test func anOwnerGetsAtMostOneReportEachSecond() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop.test.log")
        let handle = try openLog(log)
        defer { try? handle.close() }
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\n"])
        let start = ContinuousClock.now
        try addLine(to: handle)
        #expect(await eventually { reports.count == 1 })

        try addLine(to: handle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.count == 1)

        try await Task.sleep(until: start + .milliseconds(1200))
        try addLine(to: handle)

        #expect(await eventually { reports.count == 2 })
    }

    @Test func aLogThatIsNotThereGetsAFileThatReportsItsLines() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop-fix.test.log")
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\nfix"])
        let created = exists(log)
        let handle = try openLog(log)
        defer { try? handle.close() }
        try addLine(to: handle)

        #expect(created)
        #expect(await eventually { reports.list == ["shop\nfix"] })
    }

    @Test func aLogThatLeavesTheMapReportsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop.test.log")
        let other = root.appending(path: "blog.test.log")
        let handle = try openLog(log)
        defer { try? handle.close() }
        let otherHandle = try openLog(other)
        defer { try? otherHandle.close() }
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\n", other.path(percentEncoded: false): "blog\n"])
        watch.watch([other.path(percentEncoded: false): "blog\n"])
        try addLine(to: handle)
        try addLine(to: otherHandle)

        #expect(await eventually { reports.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.list == ["blog\n"])
    }

    @Test func aDeletedLogReportsTheLinesOfItsOpenFileUntilTheNewFileAtItsPathHasALine() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop.test.log")
        let first = try openLog(log)
        defer { try? first.close() }
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\n"])
        try FileManager.default.removeItem(at: log)
        let start = ContinuousClock.now
        try addLine(to: first)
        #expect(await eventually { reports.count == 1 })

        watch.refresh()
        let created = exists(log)
        let second = try openLog(log)
        defer { try? second.close() }
        try await Task.sleep(until: start + .milliseconds(1200))
        try addLine(to: second)
        #expect(await eventually { reports.count == 2 })

        try await Task.sleep(until: start + .milliseconds(2400))
        try addLine(to: first)
        try await Task.sleep(for: .milliseconds(300))

        #expect(created)
        #expect(reports.count == 2)
    }

    @Test func anOwnerThatLeavesAndComesBackReportsItsFirstLineAtOnce() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop-fix.test.log")
        let handle = try openLog(log)
        defer { try? handle.close() }
        let reports = Reports()
        let watch = watch(reports)
        defer { watch.stop() }

        watch.watch([log.path(percentEncoded: false): "shop\nfix"])
        try addLine(to: handle)
        #expect(await eventually { reports.count == 1 })

        watch.watch([:])
        watch.watch([log.path(percentEncoded: false): "shop\nfix"])
        try addLine(to: handle)

        #expect(await eventually { reports.count == 2 })
    }

    @Test func aStoppedWatchReportsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shop.test.log")
        let handle = try openLog(log)
        defer { try? handle.close() }
        let reports = Reports()
        let watch = watch(reports)

        watch.watch([log.path(percentEncoded: false): "shop\n"])
        watch.stop()
        try addLine(to: handle)
        try await Task.sleep(for: .milliseconds(300))

        #expect(reports.count == 0)
    }
}
