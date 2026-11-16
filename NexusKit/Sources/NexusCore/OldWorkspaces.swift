import Foundation

// The last notification about the old workspaces of one site (owner, 2026-11-15). names holds the
// workspaces of that notification that are still old.
public struct OldWorkspacesNoticeRecord: Codable, Sendable, Equatable {
    public let names: [String]
    public let sent: Date

    public init(names: [String], sent: Date) {
        self.names = names
        self.sent = sent
    }
}

// Old workspaces (owner, 2026-11-15). A workspace is old when it has no activity for the days of
// "Old after". Nexus never removes it by itself (D50, D53).
public enum OldWorkspaces {
    public static let dayChoices = [1, 3, 5, 7, 14, 30]
    public static let reminderChoices = [1, 3, 7]
    public static let minimumDays = 1
    public static let tooFewDaysText = "A workspace is old after at least \(Count.text(minimumDays, "day"))."

    // The app asks each hour. Without this margin the notification comes one hour later each day.
    public static let checkMargin: TimeInterval = 3600

    public static let note = "git does not remove a worktree with changes that are not committed or a worktree that a program locked. Commit or discard the changes first. The last activity is the newest of the last page, command and commit."

    // A workspace without a known time is not old.
    public static func isOld(_ lastActivity: Date?, days: Int, now: Date) -> Bool {
        guard let lastActivity else {
            return false
        }

        return now.timeIntervalSince(lastActivity) >= Double(days) * 86_400
    }

    // One notification for each site (owner, 2026-11-15). It comes again after "Notify again". A
    // workspace that is not in the last notification gives one sooner. A site gets at most one each
    // day, because a project with 24 workspaces could else give 24 notifications in one day.
    public static func noticeIsDue(old names: [String], last: OldWorkspacesNoticeRecord?, everyDays: Int, now: Date) -> Bool {
        guard !names.isEmpty else {
            return false
        }

        guard let last else {
            return true
        }

        let age = now.timeIntervalSince(last.sent) + checkMargin

        if age >= Double(everyDays) * 86_400 {
            return true
        }

        return age >= 86_400 && !Set(names).isSubset(of: last.names)
    }

    // "5 workspaces have no activity for 5 days."
    public static func lineText(count: Int, days: Int) -> String {
        "\(Count.text(count, "workspace")) \(count == 1 ? "has" : "have") no activity for \(Count.text(days, "day"))."
    }

    public static func title(host: String) -> String {
        "Old workspaces of \(host)"
    }

    // "2 workspaces have no activity for 5 days: ticket-101 and ticket-104."
    public static func notificationBody(names: [String], days: Int) -> String {
        "\(lineText(count: names.count, days: days).dropLast()): \(EnglishList.joined(names))."
    }

    public static func reminderText(days: Int) -> String {
        switch days {
        case 1: "Each day"
        case 7: "Each week"
        default: "Each \(days) days"
        }
    }

    public static func introText(days: Int, dumpDays: Int) -> String {
        "These workspaces have no activity for \(Count.text(days, "day")) or more. git removes the folder of each workspace that you choose, with all its files. The branches stay. Nexus keeps a dump of the databases in the trash for \(Count.text(dumpDays, "day"))."
    }

    // Without a host the text is about each site, as nexus workspace list --old outside a site.
    public static func emptyText(host: String?, days: Int) -> String {
        "Each workspace\(host.map { " of \($0)" } ?? "") had activity in the last \(Count.text(days, "day"))."
    }

    // "Remove 2 Workspaces…". Without a choice the button is off.
    public static func removeButtonTitle(count: Int) -> String {
        count == 0 ? "Remove Workspaces…" : "Remove \(Count.text(count, "Workspace"))…"
    }

    public static func confirmationTitle(count: Int) -> String {
        "Remove \(Count.text(count, "workspace"))?"
    }

    public static func confirmationButton(count: Int) -> String {
        "Remove \(Count.text(count, "Workspace"))"
    }

    // A workspace without databases gets no dump. So that sentence goes when no chosen workspace
    // has a database.
    public static func confirmationMessage(names: [String], dumpDays: Int, hasDatabases: Bool) -> String {
        let one = names.count == 1
        let folders = one ? "the folder of \(names[0]) with all its files" : "the folders of \(EnglishList.joined(names)) with all their files"
        let branches = one ? "The branch stays." : "The branches stay."
        let dump = hasDatabases ? " Nexus keeps a dump of \(one ? "its" : "their") databases in the trash for \(Count.text(dumpDays, "day"))." : ""

        return "git removes \(folders). \(branches)\(dump)"
    }
}
