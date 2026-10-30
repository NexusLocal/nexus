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

    @Test(arguments: [
        ("my.shop.test", "my.shop-ticket-123.test"),
        ("shop.test", "shop-ticket-123.test"),
        ("blog.local", "blog-ticket-123.test"),
        ("my.roodfruit.local", "my.roodfruit-ticket-123.test"),
        ("x.home.arpa", "x-ticket-123.test"),
    ])
    func aHostGetsTheWorkspaceNameBeforeTheTLD(host: String, expected: String) throws {
        let result = HostName.workspaceHost(host, workspace: "ticket-123", tld: "test")

        #expect(result == expected)
        #expect(try HostName.validated(result) == expected)
    }

    @Test func aHostUsesTheCurrentDevTLD() {
        #expect(HostName.workspaceHost("shop.internal", workspace: "fix", tld: "internal") == "shop-fix.internal")
        #expect(HostName.workspaceHost("shop.test", workspace: "fix", tld: "internal") == "shop-fix.internal")
    }

    @Test func aHostOutsideThePrivateNamesKeepsAllItsLetters() {
        #expect(HostName.workspaceHost("shop.com", workspace: "fix", tld: "test") == "shop.com-fix.test")
    }

    @Test func aLongLabelGivesWayToTheWorkspaceName() throws {
        let label = String(repeating: "a", count: 60)
        let workspace = String(repeating: "b", count: 40)

        let result = HostName.workspaceHost("\(label).test", workspace: workspace, tld: "test")

        #expect(try HostName.validated(result) == result)
        #expect(result.hasSuffix("-\(workspace).test"))
    }

    @Test func eachHostOfASiteGetsAWorkspaceHostOnce() {
        let site = Site(host: "shop.test", folder: URL(filePath: "/shop"), aliases: ["shop.local", "www.shop.test"], php: "8.4")
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")

        #expect(workspace.hosts(of: [site], tld: "test") == ["shop-fix.test", "www.shop-fix.test"])
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
