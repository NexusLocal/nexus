import Foundation
import Testing
@testable import NexusWorkspaces

struct WorktreeListTests {
    @Test func theMainCheckoutIsNoWorktree() {
        let porcelain = """
        worktree /work/shop
        HEAD aaa
        branch refs/heads/main

        worktree /work/ticket 123
        HEAD bbb
        branch refs/heads/feature/ticket-123

        """

        #expect(WorktreeList.parse(porcelain) { _ in true } == [Worktree(path: "/work/ticket 123", branch: "feature/ticket-123")])
    }

    @Test func aDetachedWorktreeHasNoBranch() {
        let porcelain = "worktree /work/shop\nHEAD aaa\nbranch refs/heads/main\n\nworktree /work/old\nHEAD bbb\ndetached\n\n"

        #expect(WorktreeList.parse(porcelain) { _ in true } == [Worktree(path: "/work/old")])
    }

    @Test(arguments: ["locked", "locked initializing", "locked claude agent"])
    func aLockWithoutACheckoutIsAWorktreeThatGitStillAdds(line: String) {
        let porcelain = "worktree /work/shop\nHEAD aaa\n\nworktree /work/new\nHEAD bbb\nbranch refs/heads/new\n\(line)\n\n"

        #expect(WorktreeList.parse(porcelain) { _ in false } == [Worktree(path: "/work/new", branch: "new", adding: true)])
    }

    @Test func aLockWithACheckoutIsAFinishedWorktree() {
        let porcelain = "worktree /work/shop\nHEAD aaa\n\nworktree /work/new\nHEAD bbb\nlocked claude agent\n\n"

        #expect(WorktreeList.parse(porcelain) { _ in true } == [Worktree(path: "/work/new")])
    }

    @Test func aWorktreeWithoutACheckoutHasNoIndex() {
        #expect(!WorktreeList.hasCheckout("/nexus/no/such/worktree"))
    }

    @Test func aRepositoryWithoutWorktreesGivesNoWorktrees() {
        #expect(WorktreeList.parse("worktree /work/shop\nHEAD aaa\nbranch refs/heads/main\n\n") { _ in true }.isEmpty)
    }

    @Test func aFolderThatIsNoRepositoryGivesAnError() async {
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false)

        await #expect(throws: (any Error).self) {
            try await WorktreeList.read(repository: "\(folder)nexus-no-repository-\(UUID().uuidString)", git: URL(filePath: "/usr/bin/git"))
        }
    }
}
