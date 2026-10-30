import Foundation

// The setup state of a workspace. notIsolated holds the reason (D48).
public enum WorkspaceState: Codable, Sendable, Hashable {
    case preparing
    case ready
    case notIsolated(String)
}

// A key that a site adds to the .env of each workspace (D45). The value can use {workspace}, {host},
// {database} and {port:<name>}.
public struct WorkspaceEnvKey: Codable, Sendable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    // Laravel reads no line of a .env file when one line has a wrong name.
    public var hasValidName: Bool {
        key.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_.]*/#) != nil
    }
}

// A database that Nexus copied for a workspace. Only these databases go away with the workspace.
public struct WorkspaceDatabaseCopy: Codable, Sendable, Hashable {
    public let instance: String
    public let name: String

    public init(instance: String, name: String) {
        self.instance = instance
        self.name = name
    }
}

// One git worktree of a site (D40). worktree is the root of the worktree. folder is the project
// folder of the site in that worktree. For a site in a subfolder of the repository, these differ.
// redisIndexes has the index of each env key (D47). ports has the port of each {port:<name>}.
// databases holds the finished copies, and startedCopies the copies that run or that did not end.
public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public var worktree: String
    public var folder: String
    public var branch: String?
    public var state: WorkspaceState
    public var redisIndexes: [String: Int]
    public var ports: [String: Int]
    public var databases: [WorkspaceDatabaseCopy]
    public var startedCopies: [WorkspaceDatabaseCopy]

    public var id: String { name }

    // The name goes into a host (D42), and a DNS label has a limit of 63 characters.
    static let longestName = 40

    // PostgreSQL has a limit of 63 bytes for a name. MySQL has a limit of 64.
    private static let longestDatabaseName = 63

    public init(
        name: String,
        worktree: String,
        folder: String,
        branch: String? = nil,
        state: WorkspaceState = .preparing,
        redisIndexes: [String: Int] = [:],
        ports: [String: Int] = [:],
        databases: [WorkspaceDatabaseCopy] = [],
        startedCopies: [WorkspaceDatabaseCopy] = []
    ) {
        self.name = name
        self.worktree = worktree
        self.folder = folder
        self.branch = branch
        self.state = state
        self.redisIndexes = redisIndexes
        self.ports = ports
        self.databases = databases
        self.startedCopies = startedCopies
    }

    private enum CodingKeys: String, CodingKey {
        case name, worktree, folder, branch, state, redisIndexes, ports, databases, startedCopies
    }

    // A record of part 8b has no state. Such a workspace needs its setup.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        worktree = try container.decode(String.self, forKey: .worktree)
        folder = try container.decode(String.self, forKey: .folder)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        state = try container.decodeIfPresent(WorkspaceState.self, forKey: .state) ?? .preparing
        redisIndexes = try container.decodeIfPresent([String: Int].self, forKey: .redisIndexes) ?? [:]
        ports = try container.decodeIfPresent([String: Int].self, forKey: .ports) ?? [:]
        databases = try container.decodeIfPresent([WorkspaceDatabaseCopy].self, forKey: .databases) ?? []
        startedCopies = try container.decodeIfPresent([WorkspaceDatabaseCopy].self, forKey: .startedCopies) ?? []
    }

    // D46: <database>_<workspace>. A - in a database name needs quotes in each query of an
    // application, so it becomes _. A long name gives way to the workspace name. It keeps a number
    // from the whole name, because two long names can start with the same text.
    public static func databaseName(_ database: String, workspace: String) -> String {
        let suffix = "_\(workspace.replacing("-", with: "_"))"

        guard database.utf8.count + suffix.utf8.count > longestDatabaseName else {
            return database + suffix
        }

        let number = "_" + String(database.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }, radix: 16)
        var kept = database

        while kept.utf8.count + number.utf8.count + suffix.utf8.count > longestDatabaseName {
            kept.removeLast()
        }

        return kept + number + suffix
    }

    // D41: TICKET-123 becomes ticket-123. A second worktree with the same name gets a number,
    // because a name must be unique in a site.
    public static func name(forFolder folder: String, taken: Set<String>) -> String {
        let allowed = String(folder.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
        let trimmed = allowed.prefix(longestName).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = trimmed.isEmpty ? "workspace" : trimmed
        var candidate = name
        var number = 2

        while taken.contains(candidate) {
            candidate = "\(name)-\(number)"
            number += 1
        }

        return candidate
    }
}

extension Workspace {
    // sites holds the sites that share the project of this workspace.
    public func hosts(of sites: [Site], tld: String) -> [String] {
        var seen: Set<String> = []

        return sites.flatMap(\.hosts)
            .map { HostName.workspaceHost($0, workspace: name, tld: tld) }
            .filter { seen.insert($0).inserted }
    }

    // Each host of the sites, and its parent domain with a leading dot (D44). A parent such as
    // test or home.arpa is no domain of the site.
    public static func hostPairs(of sites: [Site], workspace: String, tld: String) -> [(from: String, to: String)] {
        sites.flatMap(\.hosts).flatMap { host -> [(from: String, to: String)] in
            let pair = (from: host, to: HostName.workspaceHost(host, workspace: workspace, tld: tld))
            let parent = String(host.drop { $0 != "." }.dropFirst())

            guard parent.contains("."), !HostName.privateSuffixes.contains(parent) else {
                return [pair]
            }

            return [pair, (from: ".\(parent)", to: ".\(HostName.workspaceHost(parent, workspace: workspace, tld: tld))")]
        }
    }

    // After a change of the dev TLD, the .env of a workspace still has the hosts in the old TLD.
    public static func pairsFromOtherTLDs(_ pairs: [(from: String, to: String)], tld: String) -> [(from: String, to: String)] {
        pairs.flatMap { pair in
            HostName.devTLDs.subtracting([tld]).sorted().map { other in
                (from: "\(pair.to.dropLast(tld.count))\(other)", to: pair.to)
            }
        }
    }

    // A workspace runs as a site of its own, with the PHP and the webserver of its project.
    public func site(of sites: [Site], tld: String) -> Site? {
        guard let main = sites.first else {
            return nil
        }

        let hosts = hosts(of: sites, tld: tld)
        return Site(host: hosts[0], folder: URL(filePath: folder, directoryHint: .isDirectory), aliases: Array(hosts.dropFirst()), php: main.php, server: main.server, node: main.node)
    }
}

// What Nexus knows about the worktrees of a site. listed holds the worktrees that were there at
// the last check, also those without a workspace. So only a new worktree gets a workspace.
public struct SiteWorktrees: Codable, Sendable, Equatable {
    public var listed: Set<String>
    public var workspaces: [Workspace]

    public init(listed: Set<String> = [], workspaces: [Workspace] = []) {
        self.listed = listed
        self.workspaces = workspaces
    }
}
