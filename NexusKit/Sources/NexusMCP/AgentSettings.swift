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
