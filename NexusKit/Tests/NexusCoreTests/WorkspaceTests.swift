import Foundation
import Testing
@testable import NexusCore

struct WorkspaceTests {
    @Test(arguments: [
        ("TICKET-123", "ticket-123"),
        ("feature_new login", "feature-new-login"),
        ("v1.2", "v1-2"),
        ("één", "n"),
        ("b\u{301}x", "x"),
        ("fix_", "fix"),
        ("_private", "private"),
        ("1\u{20E3}", "workspace"),
    ])
    func aFolderNameGivesTheWorkspaceName(folder: String, name: String) {
        #expect(Workspace.name(forFolder: folder, taken: []) == name)
    }

    @Test func aLongFolderNameFitsInAHost() {
        let name = Workspace.name(forFolder: String(repeating: "a", count: 39) + "_b" + String(repeating: "c", count: 30), taken: [])

        #expect(name == String(repeating: "a", count: 39))
    }

    @Test func aTakenNameGetsTheFirstFreeNumber() {
        #expect(Workspace.name(forFolder: "fix", taken: ["fix", "fix-2"]) == "fix-3")
    }

    @Test func aSiteWithoutTheSettingCreatesWorkspaces() throws {
        let stored = #"{"host":"shop.test","folder":"file:///shop/","aliases":[],"php":"8.4","server":"nginx"}"#

        let site = try JSONDecoder().decode(Site.self, from: Data(stored.utf8))

        #expect(site.createsWorkspaces)
        #expect(!Site(host: "shop.test", folder: URL(filePath: "/shop"), php: "8.4", automaticWorkspaces: false).createsWorkspaces)
    }
}
