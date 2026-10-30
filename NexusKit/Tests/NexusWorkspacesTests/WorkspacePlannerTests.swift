import NexusCore
import Testing
@testable import NexusWorkspaces

struct WorkspacePlannerTests {
    private func update(
        _ known: SiteWorktrees?,
        _ listed: [Worktree],
        automatic: Bool = true,
        subfolder: String = "",
        excluded: Set<String> = []
    ) -> SiteWorktrees {
        WorkspacePlanner.update(known, listed: listed, automatic: automatic, subfolder: subfolder, excluded: excluded)
    }

    private func workspace(_ name: String, at worktree: String, branch: String? = nil) -> Workspace {
        Workspace(name: name, worktree: worktree, folder: worktree, branch: branch)
    }

    @Test func aNewSiteKeepsItsWorktreesWithoutAWorkspace() {
        let result = update(nil, [Worktree(path: "/w/old")])

        #expect(result == SiteWorktrees(listed: ["/w/old"]))
    }

    @Test func aNewWorktreeGetsAWorkspace() {
        let result = update(SiteWorktrees(listed: ["/w/old"]), [Worktree(path: "/w/old"), Worktree(path: "/w/TICKET-123", branch: "fix")])

        #expect(result.workspaces == [workspace("ticket-123", at: "/w/TICKET-123", branch: "fix")])
        #expect(result.listed == ["/w/old", "/w/TICKET-123"])
    }

    @Test func aSiteInASubfolderGetsThatSubfolderInTheWorktree() {
        let result = update(SiteWorktrees(), [Worktree(path: "/w/new")], subfolder: "/backend")

        #expect(result.workspaces == [Workspace(name: "new", worktree: "/w/new", folder: "/w/new/backend")])
    }

    @Test func withTheSettingOffANewWorktreeGetsNoWorkspaceAlsoNotLater() {
        let off = update(SiteWorktrees(), [Worktree(path: "/w/new")], automatic: false)
        let on = update(off, [Worktree(path: "/w/new")], automatic: true)

        #expect(off == SiteWorktrees(listed: ["/w/new"]))
        #expect(on.workspaces.isEmpty)
    }

    @Test func aWorktreeWithoutTheFolderOfTheSiteWaitsForThatFolder() {
        let worktree = Worktree(path: "/w/old-branch")

        let waiting = WorkspacePlanner.update(SiteWorktrees(), listed: [worktree], automatic: true, subfolder: "/backend", excluded: []) { _ in false }
        let found = WorkspacePlanner.update(waiting, listed: [worktree], automatic: true, subfolder: "/backend", excluded: []) { _ in true }

        #expect(waiting == SiteWorktrees())
        #expect(found.workspaces == [Workspace(name: "old-branch", worktree: "/w/old-branch", folder: "/w/old-branch/backend")])
    }

    @Test func aWorktreeOfANewSiteWithoutTheFolderStaysAnOldWorktree() {
        let result = WorkspacePlanner.update(nil, listed: [Worktree(path: "/w/old")], automatic: true, subfolder: "/backend", excluded: []) { _ in false }

        #expect(result == SiteWorktrees(listed: ["/w/old"]))
    }

    @Test func aWorkspaceFollowsTheProjectFolder() {
        let known = SiteWorktrees(listed: ["/w/new"], workspaces: [workspace("new", at: "/w/new")])

        #expect(update(known, [Worktree(path: "/w/new")], subfolder: "/public").workspaces.map(\.folder) == ["/w/new/public"])
    }

    @Test func aWorktreeWaitsUntilGitFinishesIt() {
        let adding = update(SiteWorktrees(), [Worktree(path: "/w/new", adding: true)])
        let finished = update(adding, [Worktree(path: "/w/new")])

        #expect(adding == SiteWorktrees())
        #expect(finished.workspaces == [workspace("new", at: "/w/new")])
    }

    @Test func aWorkspaceStaysWhileGitListsItsWorktree() {
        let known = SiteWorktrees(listed: ["/w/new"], workspaces: [workspace("new", at: "/w/new")])

        #expect(update(known, [Worktree(path: "/w/new", adding: true)]) == known)
    }

    @Test func aWorkspaceGoesWhenGitNoLongerListsItsWorktree() {
        let known = SiteWorktrees(listed: ["/w/new"], workspaces: [workspace("new", at: "/w/new")])

        #expect(update(known, []) == SiteWorktrees())
    }

    @Test func theSettingOffStillRemovesAWorkspace() {
        let known = SiteWorktrees(listed: ["/w/new"], workspaces: [workspace("new", at: "/w/new")])

        #expect(update(known, [], automatic: false) == SiteWorktrees())
    }

    @Test func aWorktreeThatIsASiteItselfGetsNoWorkspace() {
        #expect(update(SiteWorktrees(), [Worktree(path: "/w/new")], excluded: ["/w/new"]).workspaces.isEmpty)
    }

    @Test func aSecondWorktreeWithTheSameNameGetsANumber() {
        let result = update(SiteWorktrees(), [Worktree(path: "/a/fix"), Worktree(path: "/b/FIX"), Worktree(path: "/c/fix")])

        #expect(result.workspaces.map(\.name) == ["fix", "fix-2", "fix-3"])
    }

    @Test func aMovedWorktreeKeepsItsWorkspace() {
        let known = SiteWorktrees(listed: ["/a/fix"], workspaces: [workspace("fix", at: "/a/fix")])

        let result = update(known, [Worktree(path: "/b/fix")])

        #expect(result == SiteWorktrees(listed: ["/b/fix"], workspaces: [workspace("fix", at: "/b/fix")]))
    }

    @Test func aMovedWorktreeWithTheSettingOffKeepsItsWorkspace() {
        let known = SiteWorktrees(listed: ["/a/fix"], workspaces: [workspace("fix", at: "/a/fix")])

        #expect(update(known, [Worktree(path: "/b/fix")], automatic: false).workspaces == [workspace("fix", at: "/b/fix")])
    }

    @Test func aMovedWorktreeWithANumberKeepsItsWorkspace() {
        let known = SiteWorktrees(listed: ["/a/fix", "/b/fix"], workspaces: [workspace("fix", at: "/a/fix"), workspace("fix-2", at: "/b/fix")])

        let result = update(known, [Worktree(path: "/a/fix"), Worktree(path: "/c/fix")])

        #expect(result.workspaces == [workspace("fix", at: "/a/fix"), workspace("fix-2", at: "/c/fix")])
    }

    @Test func aMovedWorktreeWithoutAWorkspaceGetsNoWorkspace() {
        let result = update(SiteWorktrees(listed: ["/a/old"]), [Worktree(path: "/b/old")])

        #expect(result == SiteWorktrees(listed: ["/b/old"]))
    }

    @Test func aWorktreeThatWasASiteGetsNoWorkspaceAfterThatSiteGoesAway() {
        let site = update(SiteWorktrees(), [Worktree(path: "/w/new")], excluded: ["/w/new"])
        let noSite = update(site, [Worktree(path: "/w/new")])

        #expect(noSite.workspaces.isEmpty)
    }

    @Test func aWorkspaceFollowsTheBranchOfItsWorktree() {
        let known = SiteWorktrees(listed: ["/w/new"], workspaces: [workspace("new", at: "/w/new", branch: "one")])

        #expect(update(known, [Worktree(path: "/w/new", branch: "two")]).workspaces == [workspace("new", at: "/w/new", branch: "two")])
    }
}
