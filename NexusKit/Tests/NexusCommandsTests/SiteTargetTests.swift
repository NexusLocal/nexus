import Foundation
import NexusCore
import NexusIPC
import NexusMCP
import Testing
@testable import NexusCommands

struct SiteTargetTests {
    private static let fix = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", hosts: ["fix.shop.test"], url: "https://fix.shop.test", state: .ready)
    private static let broken = WorkspaceInfo(name: "broken", worktree: "/w/broken", folder: "/w/broken", hosts: ["broken.shop.test"], problem: "The database server did not start.")

    private var sites: [SiteInfo] {
        [
            SiteInfo(hosts: ["shop.test", "www.shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", workspaces: [Self.fix, Self.broken]),
            SiteInfo(hosts: ["blog.test"], folder: "/w/blog", documentRoot: "/w/blog", php: "8.4", server: .nginx, parked: false, url: "https://blog.test"),
        ]
    }

    private func find(_ host: String?, from folder: String = "/") throws -> SiteTarget {
        try SiteTarget.find(host: host, folder: folder, in: sites, example: "nexus edit shop.test")
    }

    private func message(_ work: () throws -> SiteTarget) -> String? {
        do {
            _ = try work()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test func aFolderInASiteGivesTheSite() throws {
        let target = try find(nil, from: "/w/blog/wp-content")

        #expect(target.workspace == nil)
        #expect(target.host == "blog.test")
        #expect(target.url == "https://blog.test")
        #expect(target.folder == "/w/blog")
    }

    @Test func aFolderInAWorkspaceGivesTheWorkspace() throws {
        let target = try find(nil, from: "/w/fix/app")

        #expect(target.workspace == Self.fix)
        #expect(target.siteHost == "shop.test")
        #expect(target.host == "fix.shop.test")
        #expect(target.url == "https://fix.shop.test")
        #expect(target.folder == "/w/fix")
    }

    @Test func anAliasGivesItsSite() throws {
        #expect(try find("www.shop.test").host == "shop.test")
    }

    @Test func theHostOfAWorkspaceGivesTheWorkspace() throws {
        #expect(try find("fix.shop.test", from: "/w/blog").workspace == Self.fix)
    }

    @Test func aWorkspaceThatDoesNotRunHasNoURL() throws {
        #expect(try find("broken.shop.test").url == nil)
    }

    @Test func aFolderOutsideTheSitesSaysWhatToDo() {
        #expect(message { try find(nil, from: "/tmp") } == "/tmp is in no site of Nexus. Give a host, for example: nexus edit shop.test")
    }

    @Test func anUnknownHostSaysWhereToLook() {
        #expect(message { try find("nope.test", from: "/w/shop") } == "Nexus has no site or workspace nope.test. See: nexus site list")
    }

    @Test func noChoiceGivesTheFirstKnownEditor() {
        #expect(EditorChoice(preference: nil) { _ in true } == .firstKnown)
    }

    @Test func anEmptyChoiceIsNone() {
        #expect(EditorChoice(preference: "") { _ in true } == .none)
    }

    @Test func aChosenEditorIsUsed() {
        #expect(EditorChoice(preference: "/Applications/Zed.app/") { _ in true } == .app(path: "/Applications/Zed.app/"))
    }

    @Test func aChosenEditorThatIsGoneGivesTheFirstKnownEditor() {
        #expect(EditorChoice(preference: "/Applications/Zed.app/") { _ in false } == .firstKnown)
    }
}

struct DatabaseConnectionTests {
    private static let account = DatabaseAccount(user: "root", password: "root")
    private static let other = DatabaseConnectionInfo(connection: "legacy", database: "old", host: "10.0.0.5", port: 3306, instance: nil, kind: nil, account: nil)
    private static let main = DatabaseConnectionInfo(connection: "mysql", database: "shop", host: "127.0.0.1", port: 3306, instance: "mysql-8.4", kind: .mysql, account: account)
    private static let workspace = DatabaseConnectionInfo(connection: nil, database: "shop", host: "127.0.0.1", port: 42001, instance: "mysql-8.4", kind: .mysql, account: account)

    private func target(workspace: WorkspaceInfo? = nil) -> SiteTarget {
        SiteTarget(site: SiteInfo(hosts: ["shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test"), workspace: workspace)
    }

    @Test func aSiteUsesTheInstanceOfItsFirstNexusConnection() {
        #expect(DatabaseTarget.server(of: target(), connections: [Self.other, Self.main]) == .instance("mysql-8.4"))
    }

    @Test func aWorkspaceUsesItsOwnServer() {
        let fix = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix")

        #expect(DatabaseTarget.server(of: target(workspace: fix), connections: [Self.workspace]) == .workspace(site: "shop.test", name: "fix", instance: "mysql-8.4"))
    }

    @Test func aSiteWithoutANexusServerHasNoTarget() {
        #expect(DatabaseTarget.server(of: target(), connections: [Self.other]) == nil)
    }

    @Test func aConnectionOnNexusShowsItsURL() {
        #expect(ConnectionDetails.lines(Self.main, inWorkspace: false) == [
            "Database   shop on mysql-8.4, port 3306 (connection mysql)",
            "URL        mysql://root:root@127.0.0.1:3306/shop",
        ])
    }

    @Test func aWorkspaceNamesItsServer() {
        #expect(ConnectionDetails.lines(Self.workspace, inWorkspace: true).first == "Database   shop on the server of the workspace (mysql-8.4), port 42001")
    }

    @Test func anotherServerHasNoURL() {
        #expect(ConnectionDetails.lines(Self.other, inWorkspace: false) == ["Database   old on 10.0.0.5, port 3306 (connection legacy). This server is not part of Nexus."])
    }

    @Test func theJSONKeepsEveryKey() throws {
        let json = try ConnectionDetails.json([Self.other])

        #expect(json.contains("\"password\" : null"))
        #expect(json.contains("\"url\" : null"))
    }
}
