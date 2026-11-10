import Foundation
import NexusCore

public enum AgentLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case read
    case change
    case remove

    public static func < (lhs: AgentLevel, rhs: AgentLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .read: "Only look"
        case .change: "Look and set up"
        case .remove: "Look, set up and remove"
        }
    }

    public var refusal: String {
        switch self {
        case .read: "Nexus lets agents only look. The user can change this in Nexus > Settings > Agents."
        case .change: "Nexus lets agents look and set up, but not remove. The user can change this in Nexus > Settings > Agents."
        case .remove: ""
        }
    }

    // What the level lets agents do, for Settings > Agents.
    public var summary: String {
        [abilities, limits].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // The first run has no switch "Ask me before agents look". So its text says that agents ask
    // before a change.
    public var firstRunSummary: String {
        self == .read ? abilities : [abilities, "Most agents ask you before each change.", limits].joined(separator: " ")
    }

    private var abilities: String {
        switch self {
        case .read: "Agents see your sites, services, logs and mail. They cannot change anything in Nexus."
        case .change: "Agents see your sites, services, logs and mail. They can also start services, install PHP and make databases, workspaces and sites."
        case .remove: "Agents can do all that \"Look and set up\" allows. They can also remove workspaces and sites, stop services and delete mail."
        }
    }

    private var limits: String {
        switch self {
        case .read: ""
        case .change: "No agent can delete a database or your files."
        case .remove: "No agent can delete a database or your files. A removed workspace keeps a copy of its database for 7 days."
        }
    }
}

// The MCP server reads agents.json at each call. So a change in the app works at once, also in an
// agent session that runs. listed also holds the agents that are off, because a removed agent
// must not come back by itself. Until searched is true, the app fills the list once with the
// agents on this Mac.
public struct AgentSettings: Codable, Sendable, Equatable {
    public var level: AgentLevel
    public var askBeforeLooking: Bool
    public var listed: [String]
    public var searched: Bool
    public var noticeShown: Bool

    public init(level: AgentLevel = .change, askBeforeLooking: Bool = false, listed: [String] = [], searched: Bool = false, noticeShown: Bool = false) {
        self.level = level
        self.askBeforeLooking = askBeforeLooking
        self.listed = listed
        self.searched = searched
        self.noticeShown = noticeShown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? container.decodeIfPresent(AgentLevel.self, forKey: .level)) ?? .change
        askBeforeLooking = (try? container.decodeIfPresent(Bool.self, forKey: .askBeforeLooking)) ?? false
        listed = (try? container.decodeIfPresent([String].self, forKey: .listed)) ?? []
        searched = (try? container.decodeIfPresent(Bool.self, forKey: .searched)) ?? false
        noticeShown = (try? container.decodeIfPresent(Bool.self, forKey: .noticeShown)) ?? false
    }

    // The app and nexus mcp install add an agent to the list in the same way.
    public mutating func list(_ agents: [AgentKind]) {
        listed += agents.map(\.rawValue).filter { !listed.contains($0) }
    }

    public static func file(in paths: NexusPaths) -> URL {
        paths.root.appending(path: "agents.json", directoryHint: .notDirectory)
    }

    public static func load(from paths: NexusPaths = .standard) -> AgentSettings {
        guard let data = try? Data(contentsOf: file(in: paths)), let settings = try? JSONDecoder().decode(AgentSettings.self, from: data) else {
            return AgentSettings()
        }

        return settings
    }

    public func save(to paths: NexusPaths = .standard) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = Self.file(in: paths)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
