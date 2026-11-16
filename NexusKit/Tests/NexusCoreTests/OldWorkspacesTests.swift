import Foundation
import Testing
@testable import NexusCore

struct OldWorkspacesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    @Test func aWorkspaceIsOldAfterTheDaysOfTheLimit() {
        #expect(!OldWorkspaces.isOld(nil, days: 5, now: Self.now))
        #expect(OldWorkspaces.isOld(Self.now.addingTimeInterval(-5 * Self.day), days: 5, now: Self.now))
        #expect(!OldWorkspaces.isOld(Self.now.addingTimeInterval(-4.9 * Self.day), days: 5, now: Self.now))
    }

    struct NoticeCase: Sendable, CustomTestStringConvertible {
        let old: [String]
        let last: [String]?
        let hoursAgo: Double
        let everyDays: Int
        let isDue: Bool

        var testDescription: String {
            "\(old) after \(last.map { "\($0)" } ?? "no notice") \(hoursAgo) hours ago, each \(everyDays) days"
        }
    }

    @Test(arguments: [
        NoticeCase(old: [], last: nil, hoursAgo: 0, everyDays: 1, isDue: false),
        NoticeCase(old: ["a"], last: nil, hoursAgo: 0, everyDays: 1, isDue: true),
        NoticeCase(old: ["a"], last: ["a"], hoursAgo: 2, everyDays: 1, isDue: false),
        NoticeCase(old: ["a"], last: ["a"], hoursAgo: 23.5, everyDays: 1, isDue: true),
        NoticeCase(old: ["a"], last: ["a"], hoursAgo: 72, everyDays: 7, isDue: false),
        NoticeCase(old: ["a"], last: ["a"], hoursAgo: 6 * 24 + 23.5, everyDays: 7, isDue: true),
        NoticeCase(old: ["a", "b"], last: ["a"], hoursAgo: 2, everyDays: 1, isDue: false),
        NoticeCase(old: ["a", "b"], last: ["a"], hoursAgo: 23.5, everyDays: 7, isDue: true),
        NoticeCase(old: ["a"], last: ["a", "b"], hoursAgo: 48, everyDays: 7, isDue: false),
    ])
    func aNoticeIsDueAtItsTime(notice: NoticeCase) {
        let last = notice.last.map { OldWorkspacesNoticeRecord(names: $0, sent: Self.now.addingTimeInterval(-notice.hoursAgo * Self.hour)) }

        #expect(OldWorkspaces.noticeIsDue(old: notice.old, last: last, everyDays: notice.everyDays, now: Self.now) == notice.isDue)
    }

    @Test func theTextsAreTheTextsOfTheDesign() {
        let names = ["ticket-101", "ticket-104"]

        #expect(OldWorkspaces.lineText(count: 5, days: 5) == "5 workspaces have no activity for 5 days.")
        #expect(OldWorkspaces.title(host: "shop.test") == "Old workspaces of shop.test")
        #expect(OldWorkspaces.notificationBody(names: names, days: 5) == "2 workspaces have no activity for 5 days: ticket-101 and ticket-104.")
        #expect(OldWorkspaces.introText(days: 5, dumpDays: 7) == "These workspaces have no activity for 5 days or more. git removes the folder of each workspace that you choose, with all its files. The branches stay. Nexus keeps a dump of the databases in the trash for 7 days.")
        #expect(OldWorkspaces.confirmationTitle(count: 2) == "Remove 2 workspaces?")
        #expect(OldWorkspaces.confirmationButton(count: 2) == "Remove 2 Workspaces")
        #expect(OldWorkspaces.removeButtonTitle(count: 2) == "Remove 2 Workspaces…")
        #expect(OldWorkspaces.confirmationMessage(names: names, dumpDays: 7, hasDatabases: true) == "git removes the folders of ticket-101 and ticket-104 with all their files. The branches stay. Nexus keeps a dump of their databases in the trash for 7 days.")
    }

    @Test func oneWorkspaceAndOneDayGetTheSingular() {
        #expect(OldWorkspaces.lineText(count: 1, days: 1) == "1 workspace has no activity for 1 day.")
        #expect(OldWorkspaces.notificationBody(names: ["ticket-101"], days: 1) == "1 workspace has no activity for 1 day: ticket-101.")
        #expect(OldWorkspaces.confirmationTitle(count: 1) == "Remove 1 workspace?")
        #expect(OldWorkspaces.removeButtonTitle(count: 1) == "Remove 1 Workspace…")
        #expect(OldWorkspaces.confirmationMessage(names: ["ticket-101"], dumpDays: 1, hasDatabases: true) == "git removes the folder of ticket-101 with all its files. The branch stays. Nexus keeps a dump of its databases in the trash for 1 day.")
    }

    @Test func withoutDatabasesTheConfirmationNamesNoDump() {
        #expect(OldWorkspaces.confirmationMessage(names: ["ticket-101", "ticket-104"], dumpDays: 7, hasDatabases: false) == "git removes the folders of ticket-101 and ticket-104 with all their files. The branches stay.")
    }

    @Test func withoutAChoiceTheButtonHasNoNumber() {
        #expect(OldWorkspaces.removeButtonTitle(count: 0) == "Remove Workspaces…")
    }

    @Test func withoutOldWorkspacesTheSheetSaysSo() {
        #expect(OldWorkspaces.emptyText(host: "shop.test", days: 5) == "Each workspace of shop.test had activity in the last 5 days.")
    }

    @Test func withoutOldWorkspacesOfAnySiteTheListNamesNoHost() {
        #expect(OldWorkspaces.emptyText(host: nil, days: 1) == "Each workspace had activity in the last 1 day.")
    }

    @Test func theTextOfTooFewDaysNamesTheMinimum() {
        #expect(OldWorkspaces.tooFewDaysText == "A workspace is old after at least 1 day.")
    }

    @Test(arguments: [(1, "Each day"), (3, "Each 3 days"), (7, "Each week")])
    func theReminderNamesItsDays(days: Int, text: String) {
        #expect(OldWorkspaces.reminderText(days: days) == text)
    }
}
