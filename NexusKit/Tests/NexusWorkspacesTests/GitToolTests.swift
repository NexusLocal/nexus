import Foundation
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
}
