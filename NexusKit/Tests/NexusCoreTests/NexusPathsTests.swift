import Foundation
import Testing
@testable import NexusCore

struct NexusPathsTests {
    @Test func standardRootIsTheNexusFolderInApplicationSupport() {
        let root = NexusPaths.standard.root

        #expect(root.lastPathComponent == "Nexus")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func runtimeFolderContainsTheNameAndTheVersion() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.runtime("php", version: "8.5")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/runtimes/php/8.5/")
    }

    @Test func dataFolderJoinsTheServiceAndTheVersion() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.dataFolder(service: "mysql", version: "8.4")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/data/mysql-8.4/")
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
