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

// The settings of the dump viewer. The limits of the dump store have no setting. So the store keeps
// them. All four kinds are off by default since 0.6.1 (owner, 2026-11-16). commands applies to all
// four kinds.
public struct DumpSettings: Codable, Sendable, Equatable {
    public var catchDumps = false
    public var catchQueries = false
    public var catchLogs = false
    public var catchJobs = false
    public var pageMode = DumpPageMode.automatic
    public var commands = true

    public init(catchDumps: Bool = false, catchQueries: Bool = false, catchLogs: Bool = false, catchJobs: Bool = false, pageMode: DumpPageMode = .automatic, commands: Bool = true) {
        self.catchDumps = catchDumps
        self.catchQueries = catchQueries
        self.catchLogs = catchLogs
        self.catchJobs = catchJobs
        self.pageMode = pageMode
        self.commands = commands
    }

    // A key that an older nexusd did not write gets its default. Catch log lines is the exception.
    // A user who turned Catch dumps off before the update wanted no prepend file and no error
    // handler of Nexus. So without its key, Catch log lines follows Catch dumps.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DumpSettings()

        catchDumps = try container.decodeIfPresent(Bool.self, forKey: .catchDumps) ?? defaults.catchDumps
        catchQueries = try container.decodeIfPresent(Bool.self, forKey: .catchQueries) ?? defaults.catchQueries
        catchLogs = try container.decodeIfPresent(Bool.self, forKey: .catchLogs) ?? catchDumps
        catchJobs = try container.decodeIfPresent(Bool.self, forKey: .catchJobs) ?? defaults.catchJobs
        pageMode = (try? container.decodeIfPresent(DumpPageMode.self, forKey: .pageMode)) ?? defaults.pageMode
        commands = try container.decodeIfPresent(Bool.self, forKey: .commands) ?? defaults.commands
    }

    // PHP needs the prepend file of Nexus while one of the four kinds is on.
    public var catchesAnything: Bool {
        catchDumps || catchQueries || catchLogs || catchJobs
    }

    // The switch of a kind of entry. dump() and dd() share Catch dumps.
    public func catches(_ kind: CaughtDump.Kind) -> Bool {
        switch kind {
        case .dump, .dd: catchDumps
        case .query: catchQueries
        case .log: catchLogs
        case .job: catchJobs
        }
    }
}
