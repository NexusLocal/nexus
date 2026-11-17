import Foundation
import Testing
@testable import NexusCore

struct ExecutableFileTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Executable \(UUID().uuidString)", directoryHint: .isDirectory)

    private func program(_ content: String = "first") throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "nexus")
        try Data(content.utf8).write(to: file)
        return file
    }

    @Test func theSameFileHasNoChange() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try #require(ExecutableFile(path: try program().path(percentEncoded: false)))

        #expect(file.change == nil)
    }

    @Test func aNewFileInThePlaceOfTheOldOneIsAnUpdate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try program().path(percentEncoded: false)
        let file = try #require(ExecutableFile(path: path))
        let update = root.appending(path: "nexus.new")
        try Data("second".utf8).write(to: update)

        _ = try FileManager.default.replaceItemAt(URL(filePath: path), withItemAt: update)

        #expect(file.change == .updated)
    }

    @Test func aFileWithANewDateIsAnUpdate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try program().path(percentEncoded: false)
        let file = try #require(ExecutableFile(path: path))

        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(10)], ofItemAtPath: path)

        #expect(file.change == .updated)
    }

    @Test func aFileThatIsGoneIsNoUpdate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try program().path(percentEncoded: false)
        let file = try #require(ExecutableFile(path: path))

        try FileManager.default.removeItem(atPath: path)

        #expect(file.change == .removed)
    }

    @Test func aMissingFileCountsAsAnUpdateForAShortTime() {
        let start = ContinuousClock.now
        var missingSince: ContinuousClock.Instant?

        let first = ExecutableFile.settled(.removed, missingSince: &missingSince, now: start)
        let later = ExecutableFile.settled(.removed, missingSince: &missingSince, now: start + .seconds(9))
        let afterTheWait = ExecutableFile.settled(.removed, missingSince: &missingSince, now: start + .seconds(10))
        let back = ExecutableFile.settled(.updated, missingSince: &missingSince, now: start + .seconds(11))
        let missingAgain = ExecutableFile.settled(.removed, missingSince: &missingSince, now: start + .seconds(30))

        #expect(first == .updated)
        #expect(later == .updated)
        #expect(afterTheWait == .removed)
        #expect(back == .updated)
        #expect(missingAgain == .updated)
    }

    @Test func thisProcessHasItsFile() throws {
        let file = try #require(ExecutableFile.ofThisProcess())

        #expect(file.path == RealPath.of(try #require(Bundle.main.executableURL)))
        #expect(file.change == nil)
    }

    @Test func aFileIdentityTellsTwoFilesApartAlsoWithTheSameContent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try program().path(percentEncoded: false)
        let first = try #require(FileIdentity(path: path))
        let copy = root.appending(path: "nexus.copy")
        try FileManager.default.copyItem(atPath: path, toPath: copy.path(percentEncoded: false))

        #expect(FileIdentity(path: path) == first)
        #expect(FileIdentity(path: copy.path(percentEncoded: false)) != first)
        #expect(FileIdentity(path: root.appending(path: "none").path(percentEncoded: false)) == nil)
    }
}
