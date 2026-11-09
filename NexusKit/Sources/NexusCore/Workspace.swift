import Foundation

// The setup state of a workspace. notIsolated holds the reason (D48).
public enum WorkspaceState: Codable, Sendable, Hashable {
    case preparing
    case ready
    case notIsolated(String)

    public var isNotIsolated: Bool {
        if case .notIsolated = self {
            return true
        }

        return false
    }
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

// A database that the application of a workspace uses, on the server of that workspace.
public struct WorkspaceDatabaseCopy: Codable, Sendable, Hashable {
    public let instance: String
    public let name: String

    public init(instance: String, name: String) {
        self.instance = instance
        self.name = name
    }
}

// The server of a workspace (D66). It runs on an APFS clone of the data folder of an instance, so
// the database names stay the same. folder is that clone. account is the account of the instance at
// the moment of the clone. A later change of that account does not reach the clone. isComplete is
// false until the clone ends. A clone that did not end holds no work of the user.
public struct WorkspaceDatabaseServer: Codable, Sendable, Hashable {
    public let instance: String
    public let folder: String
    public let port: Int
    public let account: DatabaseAccount
    public var isComplete: Bool

    public init(instance: String, folder: String, port: Int, account: DatabaseAccount, isComplete: Bool = false) {
        self.instance = instance
        self.folder = folder
        self.port = port
        self.account = account
        self.isComplete = isComplete
    }
}

// A server of a removed workspace that Nexus must still remove. The record of the workspace is
// gone, so this entry is the only thing that names the clone. site is the key of that record. A
// dump can take minutes, and nexusd can stop in that time.
public struct DatabaseRemoval: Codable, Sendable, Hashable {
    public let server: WorkspaceDatabaseServer
    public let databases: [String]
    public let workspace: String
    public let site: String

    public var keepsDump: Bool { server.isComplete }

    public init(server: WorkspaceDatabaseServer, databases: [String], workspace: String, site: String) {
        self.server = server
        self.databases = databases
        self.workspace = workspace
        self.site = site
    }
}

// The settings of the Workspaces tab (D53, D49).
public struct WorkspaceSettings: Codable, Sendable, Equatable {
    public var dumpDays: Int
    public var runsComposerInstall: Bool
    public var runsNpmInstall: Bool
    // What a new workspace of a site on Default gets (step 3 of the order of the work).
    public var newWorkspaceDatabases: WorkspaceDatabaseKind
    // Where nexus workspace create <branch> and the "New workspace" button put a new worktree.
    // worktreeFolder is the folder of the place folder.
    public var worktreePlace: WorktreePlace
    public var worktreeFolder: String?

    public init(
        dumpDays: Int = 7,
        runsComposerInstall: Bool = true,
        runsNpmInstall: Bool = true,
        newWorkspaceDatabases: WorkspaceDatabaseKind = .copy,
        worktreePlace: WorktreePlace = .inProject,
        worktreeFolder: String? = nil
    ) {
        self.dumpDays = dumpDays
        self.runsComposerInstall = runsComposerInstall
        self.runsNpmInstall = runsNpmInstall
        self.newWorkspaceDatabases = newWorkspaceDatabases
        self.worktreePlace = worktreePlace
        self.worktreeFolder = worktreeFolder
    }

    private enum CodingKeys: String, CodingKey {
        case dumpDays, runsComposerInstall, runsNpmInstall, newWorkspaceDatabases, worktreePlace, worktreeFolder
    }

    // The settings of an older nexusd have no choice of the databases. Their workspaces got a copy.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dumpDays = try container.decodeIfPresent(Int.self, forKey: .dumpDays) ?? 7
        runsComposerInstall = try container.decodeIfPresent(Bool.self, forKey: .runsComposerInstall) ?? true
        runsNpmInstall = try container.decodeIfPresent(Bool.self, forKey: .runsNpmInstall) ?? true
        newWorkspaceDatabases = try container.decodeIfPresent(WorkspaceDatabaseKind.self, forKey: .newWorkspaceDatabases) ?? .copy
        worktreePlace = try container.decodeIfPresent(WorktreePlace.self, forKey: .worktreePlace) ?? .inProject
        worktreeFolder = try container.decodeIfPresent(String.self, forKey: .worktreeFolder)
    }
}

// The place of a new worktree (owner, 2026-11-09). inProject is the folder that Claude Code uses
// too, so both find the same worktrees.
public enum WorktreePlace: String, Codable, Sendable, CaseIterable {
    case inProject = "in_project"
    case besideProject = "beside_project"
    case folder

    public var displayName: String {
        switch self {
        case .inProject: "In the project, in \(NewWorktree.projectFolder)"
        case .besideProject: "Next to the project"
        case .folder: "In a folder of your choice"
        }
    }
}

public enum NewWorktree {
    public static let projectFolder = ".claude/worktrees"

    // A branch such as feature/login gets the folder feature-login.
    public static func folderName(ofBranch branch: String) -> String {
        branch.split(separator: "/").joined(separator: "-")
    }

    // A place folder without a folder uses the project, as the default does.
    public static func path(branch: String, repository: String, place: WorktreePlace, folder: String?) -> String {
        let name = folderName(ofBranch: branch)
        let project = (repository as NSString).lastPathComponent

        switch (place, folder) {
        case (.besideProject, _):
            return ((repository as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(project)-\(name)")
        case (.folder, let folder?) where !folder.isEmpty:
            return (((folder as NSString).expandingTildeInPath as NSString).appendingPathComponent(project) as NSString).appendingPathComponent(name)
        default:
            return ((repository as NSString).appendingPathComponent(projectFolder) as NSString).appendingPathComponent(name)
        }
    }
}

// What the databases of a new workspace hold. copy is the clone of the instance (D66). empty has
// each database of the application again without tables, on the server of the workspace. So the
// migrations run from zero, and the workspace of an agent holds no data of customers.
// dump loads the dump file of the site into the main database of an empty workspace (owner,
// 2026-11-09). Only a site has a dump file, so Settings > Workspaces offers only copy and empty.
public enum WorkspaceDatabaseKind: String, Codable, Sendable, CaseIterable {
    case copy
    case empty
    case dump

    public var displayName: String {
        switch self {
        case .copy: "Copy of main database"
        case .empty: "Empty database"
        case .dump: "Dump file"
        }
    }

    public static let defaultChoices: [WorkspaceDatabaseKind] = [.copy, .empty]

    // The databases of the workspace start without tables.
    public var startsEmpty: Bool {
        self != .copy
    }
}

// The texts of a workspace whose dump did not load. The Site screen shows the first sentence as the
// state of the workspace.
public enum WorkspaceDumpText {
    public static let failed = "The dump did not load."
    public static let gone = "The dump file is gone."
}

// The choice of a site. default follows Settings > Workspaces, also after a change of that setting.
public enum WorkspaceDatabaseChoice: String, Codable, Sendable, CaseIterable {
    case `default`
    case copy
    case empty
    case dump

    public init(_ kind: WorkspaceDatabaseKind?) {
        switch kind {
        case .copy: self = .copy
        case .empty: self = .empty
        case .dump: self = .dump
        case nil: self = .default
        }
    }

    public var kind: WorkspaceDatabaseKind? {
        switch self {
        case .default: nil
        case .copy: .copy
        case .empty: .empty
        case .dump: .dump
        }
    }
}

// The links in the posts of the database clone of a WordPress workspace (Phase 4, 3e). from holds
// the URLs of the main site. to holds the URL of the workspace. A network waits for the change in
// its setup, because WordPress finds its sites by their domain. Another site is Ready first. Its
// change runs after that (open decision 2). done is true after the last pass. A stop of nexusd
// before that pass gives the change again at the next start.
public struct WorkspaceLinks: Codable, Sendable, Hashable {
    // The URL of one subsite of a subdomain network, before and after the move to the workspace.
    public struct Move: Codable, Sendable, Hashable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public let from: [String]
    public let to: String
    public let network: Bool
    public var done: Bool
    public let subsites: [Move]
    // The tables that WP-CLI changes. nil is each table with the prefix. A dump file gives the
    // tables that its filter did not change (owner, 2026-11-09).
    public let tables: [String]?

    public init(from: [String], to: String, network: Bool, done: Bool = false, subsites: [Move] = [], tables: [String]? = nil) {
        self.from = from
        self.to = to
        self.network = network
        self.done = done
        self.subsites = subsites
        self.tables = tables
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, network, done, subsites, tables
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        from = try container.decode([String].self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        network = try container.decode(Bool.self, forKey: .network)
        done = try container.decode(Bool.self, forKey: .done)
        subsites = try container.decodeIfPresent([Move].self, forKey: .subsites) ?? []
        tables = try container.decodeIfPresent([String].self, forKey: .tables)
    }
}

// One Redis index on one instance.
public struct WorkspaceRedisIndex: Sendable, Hashable {
    public let instance: String
    public let index: Int

    public init(instance: String, index: Int) {
        self.instance = instance
        self.index = index
    }
}

// One git worktree of a site (D40). worktree is the root of the worktree. folder is the project
// folder of the site in that worktree. For a site in a subfolder of the repository, these differ.
// redisIndexes has the index of each env key (D47), and redisInstances the instances that hold
// them. ports has the port of each {port:<name>} and of each database server. servers holds the
// database servers of the workspace (D66), and databases the databases on these servers that the
// application uses. installedLockFiles has the digest of each lock file that an install followed.
// warnings holds what the last setup could not do, when the isolation does not depend on it.
// finishedCommands holds each command of the site that ended well. commandsEnded is true after the
// last command, so a command that the site gets later does not run in this workspace.
// backgroundPreset holds the preset of the last setup (D52). database is the value of {database}.
// configurationDigest shows what the last setup checked (D48). A change of these files gives a new
// setup. A record without a digest comes from before this check. mainConfigurationDigest shows the
// same files of the main checkout. A change there gives a new setup when the workspace is not isolated.
// databaseKind is what the first setup chose, and the workspace keeps it. A record without it comes
// from before the choice and has a copy. emptiedServers holds the folder of each server whose
// databases Nexus made again without tables. So a retry keeps the tables that the commands made.
public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public var worktree: String
    public var folder: String
    public var branch: String?
    public var state: WorkspaceState
    public var redisIndexes: [String: Int]
    public var redisInstances: [String]
    public var ports: [String: Int]
    public var servers: [WorkspaceDatabaseServer]
    public var databases: [WorkspaceDatabaseCopy]
    public var installedLockFiles: [String: String]
    public var warnings: [String]
    public var finishedCommands: [String]
    public var commandsEnded: Bool
    public var backgroundPreset: [String]?
    public var database: String?
    public var configurationDigest: String?
    public var mainConfigurationDigest: String?
    // The change of the links in the posts of a WordPress workspace (Phase 4, 3e).
    public var links: WorkspaceLinks?
    public var databaseKind: WorkspaceDatabaseKind?
    public var emptiedServers: [String]

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
        redisInstances: [String] = [],
        ports: [String: Int] = [:],
        servers: [WorkspaceDatabaseServer] = [],
        databases: [WorkspaceDatabaseCopy] = [],
        installedLockFiles: [String: String] = [:],
        warnings: [String] = [],
        finishedCommands: [String] = [],
        commandsEnded: Bool = false,
        backgroundPreset: [String]? = nil,
        database: String? = nil,
        configurationDigest: String? = nil,
        mainConfigurationDigest: String? = nil,
        links: WorkspaceLinks? = nil,
        databaseKind: WorkspaceDatabaseKind? = nil,
        emptiedServers: [String] = []
    ) {
        self.name = name
        self.worktree = worktree
        self.folder = folder
        self.branch = branch
        self.state = state
        self.redisIndexes = redisIndexes
        self.redisInstances = redisInstances
        self.ports = ports
        self.servers = servers
        self.databases = databases
        self.installedLockFiles = installedLockFiles
        self.warnings = warnings
        self.finishedCommands = finishedCommands
        self.commandsEnded = commandsEnded
        self.backgroundPreset = backgroundPreset
        self.database = database
        self.configurationDigest = configurationDigest
        self.mainConfigurationDigest = mainConfigurationDigest
        self.links = links
        self.databaseKind = databaseKind
        self.emptiedServers = emptiedServers
    }

    private enum CodingKeys: String, CodingKey {
        case name, worktree, folder, branch, state, redisIndexes, redisInstances, ports, servers, databases, installedLockFiles, warnings, finishedCommands, commandsEnded, backgroundPreset, database, configurationDigest, mainConfigurationDigest, links, databaseKind, emptiedServers
    }

    // A record of part 8b has no state. A record from before part 8f has Redis indexes without their
    // instances, and only a setup can add these. Such a workspace needs its setup. A Ready record
    // without commands comes from before part 8h, so that workspace exists and gets no commands. A
    // record without a preset comes from before part 8i. That workspace starts no process until its
    // next setup, because the scheduler of an old workspace must not start without a request.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        worktree = try container.decode(String.self, forKey: .worktree)
        folder = try container.decode(String.self, forKey: .folder)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        redisIndexes = try container.decodeIfPresent([String: Int].self, forKey: .redisIndexes) ?? [:]
        redisInstances = try container.decodeIfPresent([String].self, forKey: .redisInstances) ?? []
        let storedState = try container.decodeIfPresent(WorkspaceState.self, forKey: .state) ?? .preparing
        state = !redisIndexes.isEmpty && redisInstances.isEmpty ? .preparing : storedState
        ports = try container.decodeIfPresent([String: Int].self, forKey: .ports) ?? [:]
        servers = try container.decodeIfPresent([WorkspaceDatabaseServer].self, forKey: .servers) ?? []
        databases = try container.decodeIfPresent([WorkspaceDatabaseCopy].self, forKey: .databases) ?? []
        installedLockFiles = try container.decodeIfPresent([String: String].self, forKey: .installedLockFiles) ?? [:]
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        finishedCommands = try container.decodeIfPresent([String].self, forKey: .finishedCommands) ?? []
        commandsEnded = try container.decodeIfPresent(Bool.self, forKey: .commandsEnded) ?? (storedState == .ready)
        backgroundPreset = try container.decodeIfPresent([String].self, forKey: .backgroundPreset)
        database = try container.decodeIfPresent(String.self, forKey: .database)
        configurationDigest = try container.decodeIfPresent(String.self, forKey: .configurationDigest)
        mainConfigurationDigest = try container.decodeIfPresent(String.self, forKey: .mainConfigurationDigest)
        links = try container.decodeIfPresent(WorkspaceLinks.self, forKey: .links)
        databaseKind = try container.decodeIfPresent(WorkspaceDatabaseKind.self, forKey: .databaseKind)
        emptiedServers = try container.decodeIfPresent([String].self, forKey: .emptiedServers) ?? []
    }

    public func databaseRemovals(site: String) -> [DatabaseRemoval] {
        servers.map { server in
            DatabaseRemoval(server: server, databases: databases.filter { $0.instance == server.instance }.map(\.name), workspace: name, site: site)
        }
    }

    // The name of a database of this workspace in the trash: <database>_<workspace>. A database of a
    // workspace has the name of the original, and two dumps must not have the same name. A - needs
    // quotes in each query after a restore, so it becomes _. A long name gives way to the workspace
    // name. It keeps a number from the whole name, because two long names can start with the same
    // text.
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
    // Each index of this workspace on each of its instances.
    public var redisIndexesOnInstances: Set<WorkspaceRedisIndex> {
        Set(redisInstances.flatMap { instance in
            redisIndexes.values.map { WorkspaceRedisIndex(instance: instance, index: $0) }
        })
    }

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

    // A workspace runs as a site of its own, with the kind, the PHP and the webserver of its project.
    public func site(of sites: [Site], tld: String) -> Site? {
        guard let main = sites.first else {
            return nil
        }

        let hosts = hosts(of: sites, tld: tld)
        return Site(host: hosts[0], folder: URL(filePath: folder, directoryHint: .isDirectory), aliases: Array(hosts.dropFirst()), php: main.php, server: main.server, node: main.node, runsAs: main.runsAs, command: main.command, address: main.address, documentRootFolder: main.documentRootFolder)
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
