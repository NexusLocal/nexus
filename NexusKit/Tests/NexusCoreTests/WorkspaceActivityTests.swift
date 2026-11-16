import Foundation
import Testing
@testable import NexusCore

struct WorkspaceActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theNewestTimeWins() {
        let page = WorkspaceActivity(date: now.addingTimeInterval(-2 * 86_400), source: .page)
        let commit = WorkspaceActivity(date: now.addingTimeInterval(-86_400), source: .commit)

        #expect(WorkspaceActivity.newest([page, commit]) == commit)
    }

    @Test func aPageWinsOverACommitAtTheSameTime() {
        let page = WorkspaceActivity(date: now, source: .page)
        let commit = WorkspaceActivity(date: now, source: .commit)

        #expect(WorkspaceActivity.newest([commit, page]) == page)
        #expect(WorkspaceActivity.newest([page, commit]) == page)
    }

    @Test func aGitChangeRightAfterTheCreationIsTheCreation() {
        let times = WorkspaceActivity.git(change: now.addingTimeInterval(30), created: now)

        #expect(times == [WorkspaceActivity(date: now, source: .created)])
    }

    @Test func aLaterGitChangeIsACommit() {
        let change = now.addingTimeInterval(2 * 3600)
        let times = WorkspaceActivity.git(change: change, created: now)

        #expect(times == [WorkspaceActivity(date: now, source: .created), WorkspaceActivity(date: change, source: .commit)])
        #expect(WorkspaceActivity.newest(times)?.source == .commit)
    }

    @Test func aGitChangeWithoutACreationIsACommit() {
        #expect(WorkspaceActivity.git(change: now, created: nil) == [WorkspaceActivity(date: now, source: .commit)])
    }

    @Test func withoutTimesThereIsNoActivity() {
        #expect(WorkspaceActivity.newest([]) == nil)
        #expect(WorkspaceActivity.git(change: nil, created: nil).isEmpty)
    }

    @Test(arguments: [
        (seconds: 9.5 * 86_400, source: WorkspaceActivity.Source.page, text: "9 days ago, last page"),
        (seconds: 86_400, source: .created, text: "1 day ago, created"),
        (seconds: 3 * 3600, source: .commit, text: "3 hours ago, last commit"),
        (seconds: 5 * 60, source: .command, text: "5 minutes ago, last command"),
        (seconds: 30, source: .page, text: "less than a minute ago, last page"),
        (seconds: -30, source: .page, text: "less than a minute ago, last page"),
    ])
    func theTextNamesTheAgeAndTheSource(seconds: Double, source: WorkspaceActivity.Source, text: String) {
        let activity = WorkspaceActivity(date: now.addingTimeInterval(-seconds), source: source)

        #expect(activity.text(now: now) == text)
    }
}
