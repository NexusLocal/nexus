import Foundation
import NexusCore
import NexusRuntime

public enum PortProfile: String, Codable, Sendable {
    case standard
    case development

    // While MAMP PRO still runs on the standard ports, the development profile keeps Nexus on
    // ports next to them.
    func defaultPort(_ standard: Int) -> Int {
        switch self {
        case .standard: standard
        case .development: standard < 1024 ? standard + 8000 : standard + 10000
        }
    }
}

public struct EngineState: Codable, Sendable, Equatable {
    public var portProfile: PortProfile = .standard
    public var ports: [String: Int] = [:]
    public var enabledServices: Set<String> = []
    // The services that "Stop all services" stopped. "Start stopped services" starts only these
    // (D63). Until then, nexusd does not start them. A start or a stop of one service removes it.
    public var stoppedByStopAll: Set<String> = []
    public var manifestURL = Manifest.defaultURL
    public var tld = "test"
    public var hosts: Set<String> = []
    public var sites: [Site] = []
    public var parked: [ParkedFolder] = []
    public var siteDefaults = SiteDefaults()
    public var siteLayout: [SiteLayoutEntry] = []
    public var lanAccess = false
    // A PHP version without an entry uses PHPConfig.defaultExtensions.
    public var phpExtensions: [String: Set<String>] = [:]
    // The custom php.ini lines of each PHP version (D60). PHP accepted them at the last change.
    public var phpCustomSettings: [String: [String]] = [:]
    public var apacheModules: Set<String>?
    public var nginxModules: Set<String> = []
    // The account of each database instance. An instance without an entry that already has its
    // data has root/root, because Nexus made it before the accounts could change (D35).
    public var databaseAccounts: [String: DatabaseAccount] = [:]
    public var newInstanceAccount = DatabaseAccount.newInstance
    // The worktrees and workspaces of each site, with the project folder of the site as the key.
    // A host can change. A site of a parked folder has no entry in sites.
    public var worktrees: [String: SiteWorktrees] = [:]
    public var databaseRemovals: [DatabaseRemoval] = []
    public var workspaceSettings = WorkspaceSettings()
    // The port of the Node.js app in the main checkout of each site, with the key of its worktree
    // record (D67). nginx and the app read the same port, also after a restart of nexusd. A
    // workspace keeps its port in its record.
    public var appPorts: [String: Int] = [:]

    public init() {}

    // A key that an older nexusd did not write gets its default. Without this, one new key
    // would make the whole file unreadable, and nexusd would start again with empty state.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EngineState()

        portProfile = try container.decodeIfPresent(PortProfile.self, forKey: .portProfile) ?? defaults.portProfile
        ports = try container.decodeIfPresent([String: Int].self, forKey: .ports) ?? defaults.ports
        enabledServices = try container.decodeIfPresent(Set<String>.self, forKey: .enabledServices) ?? defaults.enabledServices
        stoppedByStopAll = try container.decodeIfPresent(Set<String>.self, forKey: .stoppedByStopAll) ?? defaults.stoppedByStopAll
        // A test build saved the address of the old manifest, which no longer changes.
        let storedManifestURL = try container.decodeIfPresent(URL.self, forKey: .manifestURL) ?? defaults.manifestURL
        manifestURL = storedManifestURL == Manifest.fixedReleaseURL ? defaults.manifestURL : storedManifestURL
        tld = try container.decodeIfPresent(String.self, forKey: .tld) ?? defaults.tld
        hosts = try container.decodeIfPresent(Set<String>.self, forKey: .hosts) ?? defaults.hosts
        sites = try container.decodeIfPresent([Site].self, forKey: .sites) ?? defaults.sites
        parked = try container.decodeIfPresent([ParkedFolder].self, forKey: .parked) ?? defaults.parked
        siteDefaults = try container.decodeIfPresent(SiteDefaults.self, forKey: .siteDefaults) ?? defaults.siteDefaults
        siteLayout = try container.decodeIfPresent([SiteLayoutEntry].self, forKey: .siteLayout) ?? defaults.siteLayout
        lanAccess = try container.decodeIfPresent(Bool.self, forKey: .lanAccess) ?? defaults.lanAccess
        phpExtensions = try container.decodeIfPresent([String: Set<String>].self, forKey: .phpExtensions) ?? defaults.phpExtensions
        phpCustomSettings = try container.decodeIfPresent([String: [String]].self, forKey: .phpCustomSettings) ?? defaults.phpCustomSettings
        apacheModules = try container.decodeIfPresent(Set<String>.self, forKey: .apacheModules)
        nginxModules = try container.decodeIfPresent(Set<String>.self, forKey: .nginxModules) ?? defaults.nginxModules
        databaseAccounts = try container.decodeIfPresent([String: DatabaseAccount].self, forKey: .databaseAccounts) ?? defaults.databaseAccounts
        newInstanceAccount = try container.decodeIfPresent(DatabaseAccount.self, forKey: .newInstanceAccount) ?? defaults.newInstanceAccount
        worktrees = try container.decodeIfPresent([String: SiteWorktrees].self, forKey: .worktrees) ?? defaults.worktrees
        // An entry from before part 8m names a database copy and no server, so Nexus cannot do it.
        // Such an entry must not make the whole file unreadable.
        databaseRemovals = (try? container.decodeIfPresent([DatabaseRemoval].self, forKey: .databaseRemovals)) ?? defaults.databaseRemovals
        workspaceSettings = try container.decodeIfPresent(WorkspaceSettings.self, forKey: .workspaceSettings) ?? defaults.workspaceSettings
        appPorts = try container.decodeIfPresent([String: Int].self, forKey: .appPorts) ?? defaults.appPorts
    }
}

// What a change of the worktrees did. removed holds the workspaces that went away, with the key of
// their record.
public struct WorktreeChange: Sendable, Equatable {
    public var changed = false
    public var removed: [String: [Workspace]] = [:]
}

// Keeps the state of nexusd in config/state.json: the port of each service and the services that
// start again when nexusd starts.
public actor EngineStateStore {
    private let file: URL
    private(set) var state: EngineState

    public init(paths: NexusPaths) {
        file = paths.config.appending(path: "state.json")
        state = Self.load(from: file) ?? EngineState()
    }

    public func current() -> EngineState {
        state
    }

    @discardableResult
    public func update<Result: Sendable>(_ change: (inout EngineState) -> Result) throws -> Result {
        let result = change(&state)
        try save()
        return result
    }

    // The change starts from the current worktrees. A run of git before this call takes time, and
    // a setup can change a record in that time.
    public func updateWorktrees(_ change: ([String: SiteWorktrees]) -> [String: SiteWorktrees]) throws -> WorktreeChange {
        let updated = change(state.worktrees)

        guard updated != state.worktrees else {
            return WorktreeChange()
        }

        var removed: [String: [Workspace]] = [:]

        for (key, record) in state.worktrees {
            let gone = record.workspaces.filter { workspace in
                updated[key]?.workspaces.contains { $0.name == workspace.name } != true
            }

            if !gone.isEmpty {
                removed[key] = gone
            }
        }

        // The records go and the list of removals grows in one save. So a stop of nexusd loses no
        // clone. A removed site also ends its records, and git then still lists its worktrees. A
        // server needs a record to run, so its data goes to the trash as a dump.
        state.worktrees = updated
        state.databaseRemovals += removed.flatMap { site, workspaces in workspaces.flatMap { $0.databaseRemovals(site: site) } }
        try save()
        return WorktreeChange(changed: true, removed: removed)
    }

    // A service keeps its port once it has one. A new service gets the default port of the
    // profile, or the next port that no other Nexus service uses.
    public func port(for service: String, standard: Int) throws -> Int {
        if let port = state.ports[service] {
            return port
        }

        let taken = Set(state.ports.values)
        var port = state.portProfile.defaultPort(standard)
        while taken.contains(port) {
            port += 1
        }

        try update { $0.ports[service] = port }
        return port
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }

    // An unreadable file is kept next to the new one, so the next save does not destroy the
    // ports and the services that it holds.
    private static func load(from file: URL) -> EngineState? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }

        if let state = try? JSONDecoder().decode(EngineState.self, from: data) {
            return state
        }

        let copy = file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: file, to: copy)
        return nil
    }
}
