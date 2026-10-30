import Foundation
import Testing
@testable import NexusWorkspaces

struct FileCloneTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aCloneHasTheSameContentAndChangesAloneFromThere() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "main.sqlite")
        let target = root.appending(path: "new/folder/main.sqlite")
        try Data("the data".utf8).write(to: source)

        try FileClone.clone(source.path(percentEncoded: false), to: target.path(percentEncoded: false))
        try Data("changed".utf8).write(to: target)

        #expect(try String(contentsOf: source, encoding: .utf8) == "the data")
        #expect(try String(contentsOf: target, encoding: .utf8) == "changed")
    }

    @Test func aFolderCloneHoldsItsFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "vendor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source.appending(path: "a"), withIntermediateDirectories: true)
        try Data("file".utf8).write(to: source.appending(path: "a/file.php"))

        try FileClone.clone(source.path(percentEncoded: false), to: root.appending(path: "copy/vendor").path(percentEncoded: false))

        #expect(try String(contentsOf: root.appending(path: "copy/vendor/a/file.php"), encoding: .utf8) == "file")
    }

    @Test func aMissingFileGivesAnErrorAndNoFileAtTheTarget() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: FileCloneError.self) {
            try FileClone.clone(root.appending(path: "none").path(percentEncoded: false), to: root.appending(path: "copy").path(percentEncoded: false))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
    }

    @Test func aPartOfAnEarlierCloneDoesNotStayAndDoesNotBlockTheNextClone() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "main.sqlite")
        let target = root.appending(path: "copy/main.sqlite")
        let part = root.appending(path: "copy/.nexus-part-main.sqlite")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the da".utf8).write(to: part)
        try Data("the data".utf8).write(to: source)

        try FileClone.clone(source.path(percentEncoded: false), to: target.path(percentEncoded: false))

        #expect(try String(contentsOf: target, encoding: .utf8) == "the data")
        #expect(!FileManager.default.fileExists(atPath: part.path(percentEncoded: false)))
    }
}
