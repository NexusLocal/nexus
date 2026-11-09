import Testing
@testable import NexusIPC

struct WorkspaceInfoTests {
    @Test(arguments: [
        (reason: "The connection cms has a fixed port in config/database.php.", cause: "the connection cms has a fixed port in config/database.php."),
        (reason: "git does not ignore .env, so Nexus does not write that file.", cause: "git does not ignore .env, so Nexus does not write that file."),
        (reason: "The configuration of the application does not load: Class Foo not found", cause: "the configuration of the application does not load: Class Foo not found."),
        (reason: "The configuration of the application does not load: Maintenance\n", cause: "the configuration of the application does not load: Maintenance."),
        (reason: "A copy into shop_fix on mysql-8.4 runs already.", cause: "a copy into shop_fix on mysql-8.4 runs already."),
    ])
    func aWorkspaceThatIsNotIsolatedNamesTheCauseAndTheProcesses(reason: String, cause: String) {
        let workspace = WorkspaceInfo(name: "ticket-151", worktree: "/w/fix", folder: "/w/fix", state: .notIsolated(reason))

        #expect(workspace.isolationMessage == "ticket-151 is not isolated: \(cause) Nexus starts no background process for it.")
    }

    @Test func aDumpThatDidNotLoadSaysWhatHappened() {
        let reason = "The dump did not load. mysql stopped: ERROR 1146. Retry makes the database of this workspace empty and loads the dump again."
        let workspace = WorkspaceInfo(name: "ticket-150", worktree: "/w/fix", folder: "/w/fix", state: .notIsolated(reason))

        #expect(workspace.hasDumpProblem)
        #expect(workspace.isolationMessage == "ticket-150: \(reason)")
    }

    @Test func aReadyWorkspaceHasNoIsolationMessage() {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready)

        #expect(workspace.isolationMessage == nil)
    }
}
