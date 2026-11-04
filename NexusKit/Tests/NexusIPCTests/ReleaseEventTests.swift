import Foundation
import NexusCore
import NexusSupervisor
import Testing
@testable import NexusIPC

// Each folder in Releases holds the events of the nexusd of one release, with every key that it
// sends. A new app meets that nexusd after an update, until nexusd starts again. An app that
// cannot read the events cannot see the running tasks, so it does not restart nexusd. Add a
// folder for each release that changes the messages.
struct ReleaseEventTests {
    private static let releases = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Releases", directoryHint: .isDirectory)

    static var eventFiles: [URL] {
        let files = FileManager.default.enumerator(at: releases, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    @Test func everyReleaseHasEvents() {
        #expect(Self.eventFiles.count >= 3)
    }

    @Test(arguments: eventFiles)
    func theEventsOfAnOlderReleaseStillRead(_ file: URL) throws {
        let data = try Data(contentsOf: file)

        #expect(throws: Never.self) {
            try NexusMessageCoding.decode(NexusEvent.self, from: data)
        }
    }

    @Test func theSitesOf011KeepTheirNodeApp() throws {
        let data = try Data(contentsOf: Self.releases.appending(path: "0.1.1/sites.json"))

        let event = try NexusMessageCoding.decode(NexusEvent.self, from: data)

        guard case .sites(let list) = event, let site = list.sites.first else {
            Issue.record("no site list")
            return
        }
        #expect(site.kind == .node)
        #expect(site.app?.port == 19000)
        #expect(site.workspaces?.first?.isolationProblem == "The .env names the main database.")
    }

    @Test func theServicesOf011HaveNoUpdateBuild() throws {
        let data = try Data(contentsOf: Self.releases.appending(path: "0.1.1/services.json"))

        let event = try NexusMessageCoding.decode(NexusEvent.self, from: data)

        guard case .services(let list) = event else {
            Issue.record("no service list")
            return
        }
        #expect(list.build == "5")
        #expect(list.updateBuild == nil)
    }
}
