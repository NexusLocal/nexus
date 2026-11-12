import Foundation

// Automatic shows a dump() in the page only when the browser asked for a page. So an API, a
// Livewire or an htmx response stays valid (owner, 2026-11-11). dd() always shows in the page,
// because it ends the request.
public enum DumpPageMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case always
    case never

    // The words of the app for each choice. The stored values stay.
    public var title: String {
        switch self {
        case .automatic: "Normal pages only"
        case .always: "All requests"
        case .never: "Never"
        }
    }

    // What the choice does and why a user picks it.
    public var explanation: String {
        switch self {
        case .automatic: "A page in your browser shows each dump. An API answer or an update of Livewire, Inertia, htmx or Turbo stays clean. This is the best choice for most sites."
        case .always: "Each answer shows its dumps, also JSON. This is how PHP works without Nexus. An API answer can break."
        case .never: "The page stays clean. You see dumps only here. dd() still shows in the page, because it stops the request."
        }
    }
}

// The settings of the dump viewer. The limits of the dump store have no setting in version 1. So
// the store keeps them.
public struct DumpSettings: Codable, Sendable, Equatable {
    public var catchDumps = true
    public var pageMode = DumpPageMode.automatic
    public var commands = true

    public init() {}

    public init(catchDumps: Bool, pageMode: DumpPageMode, commands: Bool) {
        self.catchDumps = catchDumps
        self.pageMode = pageMode
        self.commands = commands
    }

    // A key that an older nexusd did not write gets its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DumpSettings()

        catchDumps = try container.decodeIfPresent(Bool.self, forKey: .catchDumps) ?? defaults.catchDumps
        pageMode = (try? container.decodeIfPresent(DumpPageMode.self, forKey: .pageMode)) ?? defaults.pageMode
        commands = try container.decodeIfPresent(Bool.self, forKey: .commands) ?? defaults.commands
    }
}
