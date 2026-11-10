import Foundation
import NexusCore

// What coding agents can do in Nexus (owner, 2026-11-10). One setting for all agents.
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

    // The error of a tool that this level does not offer.
    public var refusal: String {
        switch self {
        case .read: "Nexus lets agents only look. The user can change this in Nexus > Settings > Agents."
        case .change: "Nexus lets agents look and set up, but not remove. The user can change this in Nexus > Settings > Agents."
        case .remove: ""
        }
    }
}

// The settings of the coding agents are in agents.json in the data folder of Nexus. The app
// writes them. The MCP server reads them at each call. So a change works at once, also in an
// agent session that runs. listed holds the agents in the list of Settings > Agents, also the
// agents that are off. A file that is missing or broken gives the defaults.
public struct AgentSettings: Codable, Sendable, Equatable {
    public var level: AgentLevel
    public var askBeforeLooking: Bool
    public var listed: [String]
    public var noticeShown: Bool

    public init(level: AgentLevel = .change, askBeforeLooking: Bool = false, listed: [String] = [], noticeShown: Bool = false) {
        self.level = level
        self.askBeforeLooking = askBeforeLooking
        self.listed = listed
        self.noticeShown = noticeShown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? container.decodeIfPresent(AgentLevel.self, forKey: .level)) ?? .change
        askBeforeLooking = (try? container.decodeIfPresent(Bool.self, forKey: .askBeforeLooking)) ?? false
        listed = (try? container.decodeIfPresent([String].self, forKey: .listed)) ?? []
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
