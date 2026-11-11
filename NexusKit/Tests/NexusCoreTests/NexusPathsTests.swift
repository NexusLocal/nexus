import Foundation
import Testing
@testable import NexusCore

struct NexusPathsTests {
    @Test func standardRootIsTheNexusFolderInApplicationSupport() {
        let root = NexusPaths.standard.root

        #expect(root.lastPathComponent == "Nexus")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func runtimeFolderContainsTheNameAndTheVersionLine() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.runtime("php", line: "8.5")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/runtimes/php/8.5/")
    }

    @Test func dataFolderJoinsTheServiceAndTheVersionLine() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.dataFolder(service: "mysql", line: "8.4")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/data/mysql-8.4/")
    }

    @Test func logFileIsNamedAfterTheService() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let file = paths.log("redis-8.2")

        #expect(file.path(percentEncoded: false) == "/tmp/Nexus Test/logs/redis-8.2.log")
    }

    @Test func theDumpFilesHaveTheirOwnPlaces() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        #expect(paths.dumpSocket.path(percentEncoded: false) == "/tmp/Nexus Test/run/dumps.sock")
        #expect(paths.dumpFolder.path(percentEncoded: false) == "/tmp/Nexus Test/run/dumps/")
        #expect(paths.dumpLog.path(percentEncoded: false) == "/tmp/Nexus Test/logs/dumps.jsonl")
        #expect(paths.dumpLibrary.path(percentEncoded: false) == "/tmp/Nexus Test/php/dumps/")
    }

    @Test(arguments: [NexusVariant.release, .dev])
    func theDumpSocketFitsInAUnixSocketPathOfEachVariant(variant: NexusVariant) {
        let paths = NexusPaths(root: .applicationSupportDirectory.appending(path: variant.name, directoryHint: .isDirectory))

        let socket = paths.dumpSocket.path(percentEncoded: false)

        #expect(socket.hasSuffix("/Library/Application Support/\(variant.name)/run/dumps.sock"))
        #expect(socket.utf8.count <= 103)
    }

    @Test func createFoldersMakesEveryFolderInAPathWithSpaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Nexus Paths \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root)

        try paths.createFolders()

        for folder in paths.allFolders {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}
