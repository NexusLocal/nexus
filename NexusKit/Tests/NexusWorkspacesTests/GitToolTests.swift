import Foundation
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

    @Test func aFolderWithoutARepositoryGivesAnError() async {
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false) + "nexus-no-such-folder-\(UUID().uuidString)"

        await #expect(throws: (any Error).self) {
            try await GitTool.ignores(".env", in: folder, git: URL(filePath: "/usr/bin/git"))
        }
    }
}
