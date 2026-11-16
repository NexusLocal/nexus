import NexusCore
import Testing

struct WorkspaceRemovalTextTests {
    @Test func gitRefusesAWorktreeWithChanges() {
        let output = "fatal: '/work/fix' contains modified or untracked files, use --force to delete it"

        #expect(WorkspaceRemovalText.refusal(ofGit: output, workspace: "fix") == WorkspaceRemovalText.changes("fix"))
    }

    @Test func gitRefusesALockedWorktreeAndNamesTheReason() {
        let output = "fatal: cannot remove a locked working tree, lock reason: claude agent\nuse 'remove -f -f' to override or unlock first"

        #expect(WorkspaceRemovalText.refusal(ofGit: output, workspace: "fix") == WorkspaceRemovalText.locked("fix", reason: "claude agent"))
    }

    @Test func aLockWithoutAReasonGivesAnEmptyReason() {
        let output = "fatal: cannot remove a locked working tree;\nuse 'remove -f -f' to override or unlock first"

        #expect(WorkspaceRemovalText.refusal(ofGit: output, workspace: "fix") == WorkspaceRemovalText.locked("fix", reason: ""))
    }

    @Test func gitRefusesAWorktreeWithSubmodules() {
        let output = "fatal: working trees containing submodules cannot be moved or removed"

        #expect(WorkspaceRemovalText.refusal(ofGit: output, workspace: "fix") == WorkspaceRemovalText.submodules("fix"))
    }

    @Test func anUnknownTextOfGitGivesNoRefusal() {
        #expect(WorkspaceRemovalText.refusal(ofGit: "fatal: '/work/fix' is not a working tree", workspace: "fix") == nil)
    }

    @Test func noTextNamesForce() {
        let texts = [
            WorkspaceRemovalText.changes("fix"),
            WorkspaceRemovalText.locked("fix", reason: ""),
            WorkspaceRemovalText.locked("fix", reason: "claude agent"),
            WorkspaceRemovalText.submodules("fix"),
        ]

        #expect(texts.allSatisfy { !$0.contains("--force") })
    }

    @Test func aLockOfClaudeCodeNamesTheSessionInTheHelpAndTheRefusal() {
        #expect(WorkspaceRemovalText.lockedHelp(reason: "claude agent agent-a1b2") == "git locked this worktree. Claude Code locks its worktree while its session runs.")
        #expect(WorkspaceRemovalText.locked("fix", reason: "claude agent") == "git locked the worktree of fix with the reason \"claude agent\". Claude Code locks its worktree while its session runs. Try again after the end of that session.")
    }

    @Test func anotherLockGetsTheAdviceToUnlock() {
        #expect(WorkspaceRemovalText.lockedHelp(reason: "usb drive") == "git locked this worktree with the reason \"usb drive\". Remove the lock with git worktree unlock.")
        #expect(WorkspaceRemovalText.locked("fix", reason: "") == "git locked the worktree of fix. Remove the lock with git worktree unlock. Then try again.")
    }
}
