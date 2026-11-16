import Foundation
import NexusCore
import NexusSupervisor
import Testing
@testable import NexusWorkspaces

struct GitToolTests {
    @Test func theDeveloperToolsMakeTheProgramOfAppleSafe() {
        #expect(GitTool.executable(hasDeveloperTools: true) { _ in false } == URL(filePath: "/usr/bin/git"))
    }

    @Test func withoutTheDeveloperToolsNexusNeverRunsTheStub() {
        #expect(GitTool.executable(hasDeveloperTools: false) { $0 == "/usr/local/bin/git" } == URL(filePath: "/usr/local/bin/git"))
    }

    @Test func withoutAnyGitThereIsNoProgram() {
        #expect(GitTool.executable(hasDeveloperTools: false) { _ in false } == nil)
    }

    @Test func thisMacHasGit() async {
        #expect(await GitTool.executable() != nil)
    }

    @Test func gitTellsWhichFileItIgnores() async throws {
        let git = URL(filePath: "/usr/bin/git")
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-ignore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(".env\n".utf8).write(to: folder.appending(path: ".gitignore"))
        _ = try await CommandRunner.run(Command(executable: git, arguments: ["-C", folder.path(percentEncoded: false), "init", "-q"]))

        #expect(try await GitTool.ignores(".env", in: folder.path(percentEncoded: false), git: git))
        #expect(try await !GitTool.ignores("composer.json", in: folder.path(percentEncoded: false), git: git))
    }

    private func git(_ arguments: String..., in folder: String) async throws {
        _ = try await CommandRunner.run(Command(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Nexus", "-c", "user.email=nexus@example.test", "-C", folder] + arguments
        ))
    }

    private func repositoryWithWorktree() async throws -> (root: URL, worktree: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "nexus-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        let main = root.appending(path: "main", directoryHint: .isDirectory)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory).path(percentEncoded: false)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: main.appending(path: "readme.txt"))
        try await git("init", "-q", "-b", "main", in: main.path(percentEncoded: false))
        try await git("add", "readme.txt", in: main.path(percentEncoded: false))
        try await git("commit", "-q", "-m", "first", in: main.path(percentEncoded: false))
        try await git("worktree", "add", "-q", "-b", "fix", worktree, in: main.path(percentEncoded: false))
        return (root, worktree)
    }

    private func indexDate(ofWorktree worktree: String) throws -> Date? {
        let admin = try #require(ProjectFolder.adminFolder(ofWorktree: worktree))
        return try FileManager.default.attributesOfItem(atPath: (admin as NSString).appendingPathComponent("index"))[.modificationDate] as? Date
    }

    @Test func aCleanWorktreeHasNoChangesAndANewAndAChangedFileAreTwo() async throws {
        let (root, worktree) = try await repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = URL(filePath: "/usr/bin/git")

        let clean = try await GitTool.changeCount(in: worktree, git: git)
        try Data("two\n".utf8).write(to: URL(filePath: worktree).appending(path: "readme.txt"))
        try Data("new\n".utf8).write(to: URL(filePath: worktree).appending(path: "new.txt"))
        let changed = try await GitTool.changeCount(in: worktree, git: git)

        #expect(clean == 0)
        #expect(changed == 2)
    }

    @Test func theCountOfTheChangesKeepsTheIndexAsItIs() async throws {
        let (root, worktree) = try await repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one\n".utf8).write(to: URL(filePath: worktree).appending(path: "readme.txt"))
        let before = try indexDate(ofWorktree: worktree)

        _ = try await GitTool.changeCount(in: worktree, git: URL(filePath: "/usr/bin/git"))

        #expect(try indexDate(ofWorktree: worktree) == before)
    }

    @Test func theLockReasonComesFromTheAdminFolderOfTheWorktree() async throws {
        let (root, worktree) = try await repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appending(path: "main").path(percentEncoded: false)

        let open = WorktreeList.lockReason(ofWorktree: worktree)
        try await git("worktree", "lock", worktree, in: main)
        let withoutReason = WorktreeList.lockReason(ofWorktree: worktree)
        try await git("worktree", "unlock", worktree, in: main)
        try await git("worktree", "lock", "--reason", "claude agent", worktree, in: main)
        let withReason = WorktreeList.lockReason(ofWorktree: worktree)

        #expect(open == nil)
        #expect(withoutReason == "")
        #expect(withReason == "claude agent")
    }

    @Test func aWorktreeHasSubmodulesWhenItsAdminFolderHasModules() async throws {
        let (root, worktree) = try await repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = URL(filePath: "/usr/bin/git")

        let plain = await GitTool.hasSubmodules(worktree: worktree, git: git)
        let admin = try #require(ProjectFolder.adminFolder(ofWorktree: worktree))
        try FileManager.default.createDirectory(atPath: (admin as NSString).appendingPathComponent("modules"), withIntermediateDirectories: true)
        let withModules = await GitTool.hasSubmodules(worktree: worktree, git: git)

        #expect(!plain)
        #expect(withModules)
    }

    @Test(arguments: [("[ahead 2]", 2), ("[ahead 2, behind 1]", 2), ("[behind 3]", 0), ("[gone]", 0), ("", 0)])
    func theTrackGivesTheCommitsThatAreNotPushed(track: String, ahead: Int) {
        #expect(GitTool.ahead(inTrack: track) == ahead)
    }

    @Test func theStatesOfTheBranches() {
        let states = GitTool.branchStates(refs: "refs/heads/a\t[gone]\nrefs/heads/b\t[ahead 2]\nrefs/heads/c\t\nrefs/heads/feature/d\t[ahead 1, behind 4]\n", merged: "refs/heads/a\nrefs/heads/c\n")

        #expect(states == [
            "a": BranchState(merged: true, gone: true),
            "b": BranchState(ahead: 2),
            "c": BranchState(merged: true),
            "feature/d": BranchState(ahead: 1),
        ])
    }

    @Test func theCurrentBranchOfTheMainCheckout() async throws {
        let (root, _) = try await repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = URL(filePath: "/usr/bin/git")
        let main = root.appending(path: "main").path(percentEncoded: false)

        let branch = await GitTool.currentBranch(repository: main, git: git)
        try await self.git("checkout", "-q", "--detach", in: main)
        let detached = await GitTool.currentBranch(repository: main, git: git)

        #expect(branch == "main")
        #expect(detached == nil)
    }

    @Test func aFolderWithoutARepositoryGivesAnError() async {
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false) + "nexus-no-such-folder-\(UUID().uuidString)"

        await #expect(throws: (any Error).self) {
            try await GitTool.ignores(".env", in: folder, git: URL(filePath: "/usr/bin/git"))
        }
    }
}
