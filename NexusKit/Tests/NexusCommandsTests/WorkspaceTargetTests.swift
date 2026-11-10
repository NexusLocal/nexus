import Foundation
import NexusCore
import NexusIPC
import NexusMCP
import Testing
@testable import NexusCommands

struct WorkspaceTargetTests {
    private func site(_ host: String, folder: String, workspaces: [WorkspaceInfo]) -> SiteInfo {
        SiteInfo(hosts: [host], folder: folder, documentRoot: folder, php: "8.4", server: .nginx, parked: false, url: "https://\(host)", workspaces: workspaces)
    }

    private func workspace(_ name: String, worktree: String) -> WorkspaceInfo {
        WorkspaceInfo(name: name, worktree: worktree, folder: worktree, url: "https://\(name).test", state: .ready)
    }

    private var sites: [SiteInfo] {
        [
            site("shop.test", folder: "/w/shop", workspaces: [workspace("fix", worktree: "/w/fix"), workspace("other", worktree: "/w/other")]),
            site("blog.test", folder: "/w/blog", workspaces: [workspace("fix", worktree: "/w/blog-fix")]),
        ]
    }

    private func message(_ work: () throws -> WorkspaceTarget) -> String? {
        do {
            _ = try work()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test func aFolderInAWorktreeGivesItsWorkspace() throws {
        let target = try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/other/app/Models", in: sites)

        #expect(target.workspace.name == "other")
        #expect(target.site.hosts == ["shop.test"])
    }

    @Test func aFolderOutsideAWorkspaceSaysWhatToDo() {
        let text = message { try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/shop", in: sites) }

        #expect(text == "/w/shop is in no workspace. Run nexus workspace create in a git worktree, or give the name of a workspace.")
    }

    @Test func aFolderDoesNotMatchAWorktreeWithTheSameStart() {
        #expect(message { try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/fixture", in: sites) } != nil)
    }

    @Test func aNameOfOneSiteIsEnough() throws {
        #expect(try WorkspaceTarget.find(name: "other", site: nil, folder: "/", in: sites).workspace.worktree == "/w/other")
    }

    @Test func aNameOfTwoSitesNeedsTheSite() throws {
        let text = message { try WorkspaceTarget.find(name: "fix", site: nil, folder: "/", in: sites) }

        #expect(text == "More sites have a workspace fix: shop.test, blog.test. Choose one with --site.")
        #expect(try WorkspaceTarget.find(name: "fix", site: "blog.test", folder: "/", in: sites).workspace.worktree == "/w/blog-fix")
    }

    @Test func twoSitesOfOneProjectShareTheirWorkspace() throws {
        let shared = workspace("fix", worktree: "/w/fix")
        let sites = [site("shop.test", folder: "/w/shop", workspaces: [shared]), site("admin.test", folder: "/w/shop/public", workspaces: [shared])]

        #expect(try WorkspaceTarget.find(name: "fix", site: nil, folder: "/", in: sites).workspace == shared)
    }

    @Test func aFolderInTwoSitesOfOneRepositoryGivesTheWorkspaceOfItsOwnSite() throws {
        let first = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix/shop")
        let second = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix/blog")
        let sites = [site("shop.test", folder: "/w/repo/shop", workspaces: [first]), site("blog.test", folder: "/w/repo/blog", workspaces: [second])]

        #expect(try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/fix/blog/app", in: sites).site.hosts == ["blog.test"])
    }

    @Test func aWorktreeInAWorktreeGivesTheDeepestWorkspace() throws {
        let sites = [site("shop.test", folder: "/w/shop", workspaces: [workspace("outer", worktree: "/w/fix"), workspace("inner", worktree: "/w/fix/.claude/worktrees/inner")])]

        #expect(try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/fix/.claude/worktrees/inner/app", in: sites).workspace.name == "inner")
    }

    @Test func anInnerWorktreeWithoutAWorkspaceDoesNotGiveTheOuterWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let admin = root.appending(path: "repo/.git/worktrees/inner", directoryHint: .isDirectory)
        let outer = root.appending(path: "outer", directoryHint: .isDirectory)
        let inner = outer.appending(path: ".claude/worktrees/inner", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner.appending(path: "app"), withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: admin.appending(path: "commondir"))
        try Data("gitdir: \(RealPath.of(admin))\n".utf8).write(to: inner.appending(path: ".git"))

        let folder = "\(RealPath.of(inner))/app"
        let sites = [site("shop.test", folder: "\(RealPath.of(root))/repo", workspaces: [workspace("outer", worktree: RealPath.of(outer))])]

        #expect(message { try WorkspaceTarget.find(name: nil, site: nil, folder: folder, in: sites) } == "\(folder) is in no workspace. Run nexus workspace create in a git worktree, or give the name of a workspace.")
    }

    @Test func theCurrentSiteInAWorktreeOfTwoSitesIsTheSiteOfItsOwnFolder() {
        let first = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix/shop")
        let second = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix/blog")
        let sites = [site("shop.test", folder: "/w/repo/shop", workspaces: [first]), site("blog.test", folder: "/w/repo/blog", workspaces: [second])]

        #expect(WorkspaceTarget.currentSite(folder: "/w/fix/blog/app", in: sites)?.hosts == ["blog.test"])
    }

    @Test func theCurrentSiteIsTheDeepestSite() {
        let sites = [site("mono.test", folder: "/w/mono", workspaces: []), site("api.test", folder: "/w/mono/api", workspaces: [])]

        #expect(WorkspaceTarget.currentSite(folder: "/w/mono/api/app", in: sites)?.hosts == ["api.test"])
    }

    @Test func theCurrentSiteOfAPublicFolderHoldsTheWholeProject() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        let publicFolder = project.appending(path: "public", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))

        let path = RealPath.of(project)
        let sites = [site("shop.test", folder: publicFolder.path(percentEncoded: false), workspaces: [])]

        #expect(WorkspaceTarget.currentSite(folder: "\(path)/app", in: sites)?.hosts == ["shop.test"])
    }

    @Test func anUnknownSiteOrNameGivesAClearError() {
        #expect(message { try WorkspaceTarget.find(name: "fix", site: "none.test", folder: "/", in: sites) } == "Nexus has no site none.test.")
        #expect(message { try WorkspaceTarget.find(name: "none", site: nil, folder: "/", in: sites) } == "Nexus has no workspace none. See: nexus workspace list --all")
    }

    @Test func theCurrentSiteIsTheSiteOfTheMainCheckoutOrOfAWorktree() {
        #expect(WorkspaceTarget.currentSite(folder: "/w/blog/app", in: sites)?.hosts == ["blog.test"])
        #expect(WorkspaceTarget.currentSite(folder: "/w/fix/app", in: sites)?.hosts == ["shop.test"])
        #expect(WorkspaceTarget.currentSite(folder: "/tmp", in: sites) == nil)
    }

    @Test func onlyAMissingWorkspaceCanAppearLater() {
        func error(_ work: () throws -> WorkspaceTarget) -> WorkspaceTargetError? {
            do {
                _ = try work()
                return nil
            } catch {
                return error as? WorkspaceTargetError
            }
        }

        #expect(error { try WorkspaceTarget.find(name: nil, site: nil, folder: "/w/new", in: sites) }?.canAppearLater == true)
        #expect(error { try WorkspaceTarget.find(name: "new", site: nil, folder: "/", in: sites) }?.canAppearLater == true)
        #expect(error { try WorkspaceTarget.find(name: "fix", site: "none.test", folder: "/", in: sites) }?.canAppearLater == false)
        #expect(error { try WorkspaceTarget.find(name: "fix", site: nil, folder: "/", in: sites) }?.canAppearLater == false)
    }

    @Test func theJSONKeepsAKeyWithoutAValue() throws {
        let info = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .preparing, databases: [WorkspaceDatabaseInfo(name: "shop_fix", instance: "mysql-8.4", port: nil)])
        let target = WorkspaceTarget(site: site("shop.test", folder: "/w/shop", workspaces: [info]), workspace: info)
        let details = try #require(try JSONSerialization.jsonObject(with: Data(WorkspaceDetails(target).json.utf8)) as? [String: Any])
        let database = try #require((details["databases"] as? [[String: Any]])?.first)

        #expect(details["url"] is NSNull)
        #expect(details["problem"] is NSNull)
        #expect(details["branch"] is NSNull)
        #expect(details["state"] as? String == "preparing")
        #expect(database["port"] is NSNull)
    }

    @Test func theJSONGivesTheURLTheDatabasesAndThePorts() throws {
        let info = WorkspaceInfo(
            name: "fix",
            worktree: "/w/fix",
            folder: "/w/fix",
            branch: "fix",
            hosts: ["shop-fix.test"],
            url: "https://shop-fix.test:8443",
            state: .notIsolated("The connection cms is fixed."),
            warnings: ["A warning."],
            databases: [WorkspaceDatabaseInfo(name: "shop_fix", instance: "mysql-8.4", port: 13307)],
            redisIndexes: ["REDIS_DB": 16],
            ports: ["vite": 20000]
        )
        let target = WorkspaceTarget(site: site("shop.test", folder: "/w/shop", workspaces: [info]), workspace: info)
        let details = try #require(try JSONSerialization.jsonObject(with: Data(WorkspaceDetails(target).json.utf8)) as? [String: Any])
        let database = try #require((details["databases"] as? [[String: Any]])?.first)

        #expect(details["name"] as? String == "fix")
        #expect(details["site"] as? String == "shop.test")
        #expect(details["state"] as? String == "not_isolated")
        #expect(details["problem"] as? String == "The connection cms is fixed.")
        #expect(details["url"] as? String == "https://shop-fix.test:8443")
        #expect(details["ports"] as? [String: Int] == ["vite": 20000])
        #expect(details["redisIndexes"] as? [String: Int] == ["REDIS_DB": 16])
        #expect(database["name"] as? String == "shop_fix")
        #expect(database["port"] as? Int == 13307)
    }
}
