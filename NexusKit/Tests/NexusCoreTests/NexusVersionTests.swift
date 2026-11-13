import Foundation
import Testing
@testable import NexusCore

struct NexusVersionTests {
    @Test func aDebugBuildAddsTheTimeOfItsNexusdFileToTheBuild() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "nexus-version-\(UUID().uuidString)/Nexus.app", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "7"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        let withoutDaemon = NexusVersion.identityOnDisk(ofAppAt: app)

        let daemon = contents.appending(path: "MacOS/nexusd")
        try Data().write(to: daemon)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: daemon.path(percentEncoded: false))

        #if DEBUG
        #expect(withoutDaemon == nil)
        #expect(NexusVersion.identityOnDisk(ofAppAt: app) == "7+1800000000")
        #else
        #expect(withoutDaemon == "7")
        #expect(NexusVersion.identityOnDisk(ofAppAt: app) == "7")
        #endif
    }
}
