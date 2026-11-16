import Foundation

// The last activity of a workspace and its source (owner, 2026-11-15). The sheet of the old
// workspaces shows both, for example "9 days ago, last page". Item 3c of group 3 gives the source
// command.
public struct WorkspaceActivity: Codable, Sendable, Hashable {
    // The order decides between two sources with the same time.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case page
        case command
        case commit
        case created

        public var text: String {
            switch self {
            case .page: "last page"
            case .command: "last command"
            case .commit: "last commit"
            case .created: "created"
            }
        }
    }

    // git worktree add writes logs/HEAD and the index some moments after commondir. A git change in
    // this time is part of the creation.
    public static let creationTime: TimeInterval = 60

    public let date: Date
    public let source: Source

    public init(date: Date, source: Source) {
        self.date = date
        self.source = source
    }

    public static func newest(_ candidates: [WorkspaceActivity]) -> WorkspaceActivity? {
        candidates.max { first, second in
            first.date == second.date ? first.rank > second.rank : first.date < second.date
        }
    }

    // change is the newest time of logs/HEAD and the index. created is the birth of commondir.
    public static func git(change: Date?, created: Date?) -> [WorkspaceActivity] {
        var times = created.map { [WorkspaceActivity(date: $0, source: .created)] } ?? []

        if let change, created.map({ change.timeIntervalSince($0) > creationTime }) ?? true {
            times.append(WorkspaceActivity(date: change, source: .commit))
        }

        return times
    }

    // "9 days ago, last page".
    public func text(now: Date) -> String {
        "\(Self.age(of: date, now: now)), \(source.text)"
    }

    public static func age(of date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))

        if seconds >= 86_400 {
            return "\(Count.text(seconds / 86_400, "day")) ago"
        }

        if seconds >= 3600 {
            return "\(Count.text(seconds / 3600, "hour")) ago"
        }

        if seconds >= 60 {
            return "\(Count.text(seconds / 60, "minute")) ago"
        }

        return "less than a minute ago"
    }

    private var rank: Int {
        Source.allCases.firstIndex(of: source) ?? 0
    }
}
