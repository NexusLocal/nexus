import Foundation
import Testing
@testable import NexusCore

struct NexusVersionTests {
    @Test(arguments: [
        ("11", "12", true),
        ("12", "12", false),
        ("12", "11", false),
        ("9", "10", true),
        ("1+100", "1+200", true),
        ("1+300", "1+200", false),
        ("12", "12+100", true),
        ("old", "12", true),
        ("unknown", "unknown", false),
    ])
    func anIdentityIsOlderOnlyWhenItsNumbersComeFirst(identity: String, other: String, older: Bool) {
        #expect(NexusVersion.isOlder(identity, than: other) == older)
    }

    @Test func anIdentityWithoutABuildIsOlder() {
        #expect(NexusVersion.isOlder(nil, than: "12"))
    }

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
