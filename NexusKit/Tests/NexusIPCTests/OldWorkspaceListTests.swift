import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct OldWorkspaceListTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func workspace(_ name: String, daysAgo: Double = 6, source: WorkspaceActivity.Source = .commit, merged: Bool = false, branchGone: Bool = false, commitsNotPushed: Int = 0, changesNotCommitted: Int = 0, locked: String? = nil, hasSubmodules: Bool = false, folderGone: Bool = false, gitProblem: String? = nil) -> OldWorkspace {
        OldWorkspace(
            name: name,
            branch: name,
            worktree: "/w/shop/.claude/worktrees/\(name)",
            activity: WorkspaceActivity(date: Self.now.addingTimeInterval(-daysAgo * 86_400), source: source),
            hasDatabases: true,
            merged: merged,
            branchGone: branchGone,
            commitsNotPushed: commitsNotPushed,
            changesNotCommitted: changesNotCommitted,
            locked: locked,
            hasSubmodules: hasSubmodules,
            folderGone: folderGone,
            gitProblem: gitProblem
        )
    }

    @Test func theSignsOfTheDesignRows() {
        let rows = [
            workspace("ticket-101", daysAgo: 9, source: .page, merged: true, branchGone: true),
            workspace("ticket-104", daysAgo: 8, merged: true),
            workspace("ticket-109", commitsNotPushed: 2),
            workspace("ticket-112", source: .created, changesNotCommitted: 3),
            workspace("ticket-115", daysAgo: 5, locked: "claude agent-a1b2"),
        ]

        #expect(rows.map { $0.signs(mainBranch: "development") } == [
            [OldWorkspaceSign(text: "Merged into development", isWarning: false), OldWorkspaceSign(text: "Branch gone on the remote", isWarning: false)],
            [OldWorkspaceSign(text: "Merged into development", isWarning: false)],
            [OldWorkspaceSign(text: "2 commits are not pushed", isWarning: true)],
            [OldWorkspaceSign(text: "3 changes are not committed", isWarning: true)],
            [OldWorkspaceSign(text: "In use: claude agent-a1b2", isWarning: true)],
        ])
        #expect(rows.map(\.canGo) == [true, true, true, false, false])
        #expect(rows[0].activity.text(now: Self.now) == "9 days ago, last page")
    }

    @Test func aRowThatGitRefusesCannotGo() {
        let refused = [
            workspace("changes", changesNotCommitted: 1),
            workspace("locked", locked: "claude agent-a1b2"),
            workspace("submodules", hasSubmodules: true),
            workspace("unreadable", gitProblem: "fatal: not a git repository"),
        ]

        #expect(refused.allSatisfy { !$0.canGo })
        #expect(refused.map(\.refusal) == [
            WorkspaceRemovalText.changes("changes"),
            WorkspaceRemovalText.locked("locked", reason: "claude agent-a1b2"),
            WorkspaceRemovalText.submodules("submodules"),
            "fatal: not a git repository",
        ])
        #expect(workspace("gone", folderGone: true).canGo)
        #expect(workspace("ahead", commitsNotPushed: 4).canGo)
    }

    @Test func aGoneFolderAndAnUnreadableWorktreeGetTheirSigns() {
        #expect(workspace("gone", folderGone: true).signs(mainBranch: "main") == [OldWorkspaceSign(text: "The folder is gone", isWarning: false)])
        #expect(workspace("modules", hasSubmodules: true).signs(mainBranch: "main") == [OldWorkspaceSign(text: "Has submodules", isWarning: true)])
        #expect(workspace("unreadable", gitProblem: "fatal").signs(mainBranch: "main") == [OldWorkspaceSign(text: "git cannot read the worktree", isWarning: true)])
    }

    @Test func aLockWithoutAReasonIsInUse() {
        #expect(workspace("locked", locked: "").signs(mainBranch: "main") == [OldWorkspaceSign(text: "In use", isWarning: true)])
    }

    @Test func withoutAMainBranchThereIsNoMergedSign() {
        #expect(workspace("merged", merged: true).signs(mainBranch: nil).isEmpty)
    }

    @Test func oneCommitAndOneChangeGetTheSingular() {
        let signs = workspace("one", commitsNotPushed: 1, changesNotCommitted: 1).signs(mainBranch: "main").map(\.text)

        #expect(signs == ["1 commit is not pushed", "1 change is not committed"])
    }

    @Test func theListSurvivesTheWire() throws {
        let list = OldWorkspaceList(host: "shop.test", days: 5, settings: WorkspaceSettings(), mainBranch: "development", workspaces: [
            workspace("ticket-101", daysAgo: 9, source: .page, merged: true, branchGone: true),
            workspace("ticket-115", daysAgo: 5, locked: "claude agent-a1b2"),
        ])
        let notices = [OldWorkspacesNotice(host: "shop.test", names: ["ticket-101", "ticket-115"], days: 5)]

        for response in [NexusResponse.oldWorkspaces(list), .oldWorkspaceNotices(notices)] {
            #expect(try NexusMessageCoding.decode(NexusResponse.self, from: NexusMessageCoding.encode(response)) == response)
        }
    }

    @Test func aListFromAnOlderNexusdKeepsTheDumps() throws {
        let list = try NexusMessageCoding.decode(OldWorkspaceList.self, from: Data(#"{"host":"shop.test","days":5,"dumpDays":7,"workspaces":[]}"#.utf8))

        #expect(list.keptDumpDays == 7)
    }

    @Test func aListWithoutTheDumpsKeepsNoDays() {
        let list = OldWorkspaceList(host: "shop.test", days: 5, settings: WorkspaceSettings(dumpsBeforeRemoval: false), mainBranch: nil, workspaces: [])

        #expect(list.keptDumpDays == nil)
    }

    @Test func theRequestsSurviveTheWire() throws {
        for request in [NexusRequest.oldWorkspaces(host: "shop.test", days: 3), .oldWorkspaces(host: "shop.test"), .oldWorkspaceNotices] {
            #expect(try NexusMessageCoding.decode(NexusRequest.self, from: NexusMessageCoding.encode(request)) == request)
        }
    }

    @Test func aWorkspaceInfoKeepsItsLastActivity() throws {
        let info = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, lastActivity: Self.now)
        let decoded = try NexusMessageCoding.decode(WorkspaceInfo.self, from: NexusMessageCoding.encode(info))

        #expect(decoded.lastActivity == Self.now)
        #expect(decoded == info)
    }

    @Test func aSiteListFromAnOlderNexusdHasNoLimit() throws {
        let list = SiteList(sites: [], layout: [], parkedFolders: [], defaults: SiteDefaults(), tld: "test")
        let decoded = try NexusMessageCoding.decode(SiteList.self, from: NexusMessageCoding.encode(list))

        #expect(decoded.oldAfterDays == nil)
    }
}
