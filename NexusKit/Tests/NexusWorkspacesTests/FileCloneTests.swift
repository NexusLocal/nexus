import Foundation
import NexusCore
import NexusSupervisor
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

    private func sqlite(_ file: String, _ commands: String...) async throws -> String {
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/sqlite3"), arguments: [file] + commands)).trimmed
    }

    @Test func aBackupHoldsTheLastChangesAndKeepsTheWriteAheadFileOfTheSource() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "main.sqlite").path(percentEncoded: false)
        let target = root.appending(path: #"it's "a" \ folder/main.sqlite"#).path(percentEncoded: false)
        _ = try await sqlite(source, ".dbconfig no_ckpt_on_close on", "PRAGMA journal_mode=WAL;", "CREATE TABLE orders(id);", "INSERT INTO orders VALUES (1);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source)
        let writeAheadFile = try Data(contentsOf: URL(filePath: "\(source)-wal"))

        try await FileClone.backUpSQLiteFile(source, to: target, readOnly: true)

        let attributes = try FileManager.default.attributesOfItem(atPath: target)

        #expect(try await sqlite(target, "SELECT COUNT(*) FROM orders;") == "1")
        #expect(try Data(contentsOf: URL(filePath: "\(source)-wal")) == writeAheadFile)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func aBackupThatFailsLeavesNoFile() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "main.sqlite")
        let target = root.appending(path: "new/main.sqlite")
        try Data("no database".utf8).write(to: source)

        await #expect(throws: FileCloneError.self) {
            try await FileClone.backUpSQLiteFile(source.path(percentEncoded: false), to: target.path(percentEncoded: false), readOnly: true)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path(percentEncoded: false)).isEmpty)
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

    @Test func thePartOfACloneIsOutsideTheWorktreeAndOnTheDiskOfTheTarget() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "worktree/vendor").path(percentEncoded: false)

        let part = try FileClone.partPath(of: target)
        defer { try? FileManager.default.removeItem(atPath: (part as NSString).deletingLastPathComponent) }

        let volume = { (path: String) in try URL(filePath: path).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }

        #expect(!RealPath.contains(RealPath.of(root), RealPath.of(URL(filePath: (part as NSString).deletingLastPathComponent))))
        #expect(try volume((part as NSString).deletingLastPathComponent) == volume(root.path(percentEncoded: false)))
    }

    @Test func aCloneLeavesNoPartInItsTemporaryFolder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "main.sqlite")
        try Data("the data".utf8).write(to: source)

        try FileClone.clone(source.path(percentEncoded: false), to: root.appending(path: "copy/main.sqlite").path(percentEncoded: false))

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "copy").path(percentEncoded: false)) == ["main.sqlite"])
    }
}
