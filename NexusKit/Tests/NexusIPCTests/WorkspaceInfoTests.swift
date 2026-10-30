import Testing
@testable import NexusIPC

struct WorkspaceInfoTests {
    @Test(arguments: [
        (finished: 0, planned: 3, running: nil, percent: nil),
        (finished: 0, planned: 3, running: 50, percent: 16),
        (finished: 1, planned: 3, running: nil, percent: 33),
        (finished: 1, planned: 3, running: 50, percent: 50),
        (finished: 2, planned: 3, running: 100, percent: 100),
        (finished: 3, planned: 3, running: nil, percent: nil),
        (finished: 0, planned: 0, running: 40, percent: 40),
        (finished: 0, planned: 0, running: nil, percent: nil),
    ] as [(finished: Int, planned: Int, running: Int?, percent: Int?)])
    func theCopiesGiveOnePercentage(finished: Int, planned: Int, running: Int?, percent: Int?) {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", finishedCopies: finished, plannedCopies: planned)

        #expect(workspace.copyPercent(runningPercent: running) == percent)
    }
}
