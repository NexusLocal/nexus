import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

public enum NexusServiceID {
    public static let dns = "dns"
}

// The messages between the app, the CLI and nexusd. A nexusd that did not start again after an
// update of the app sends the old keys only. So each key that comes after step 6c is optional:
// Codable then reads a message without it. NexusEventFeedTests reads a message of step 6c.

// A site as the app and nexus site list show it. parked is true for a site that has no settings
// of its own. parkedFolder is the parked folder that holds the folder of the site, also when the
// site has its own settings. The problem says why the site does not run. projectNode is the Node
// line that the files of the project give (D21). nodeSetting is the line that the user chose for
// the site, or nil when the line of the project applies. nexusd reads the files of the project
// only for a site without a chosen line.
public struct SiteInfo: Codable, Sendable, Equatable {
    public let hosts: [String]
    public let folder: String
    public let documentRoot: String
    public let php: String
    public let server: WebServer
    public let parked: Bool
    public let url: String
    public let group: String?
    public let parkedFolder: String?
    public let problem: String?
    public let projectNode: NodeChoice?
    public let nodeSetting: String?
    public let automaticWorkspaces: Bool?
    public let workspaces: [WorkspaceInfo]?
    public let workspaceProblem: String?
    public let workspaceKeys: [WorkspaceEnvKey]?

    public init(
        hosts: [String],
        folder: String,
        documentRoot: String,
        php: String,
        server: WebServer,
        parked: Bool,
        url: String,
        group: String? = nil,
        parkedFolder: String? = nil,
        problem: String? = nil,
        projectNode: NodeChoice? = nil,
        nodeSetting: String? = nil,
        automaticWorkspaces: Bool? = nil,
        workspaces: [WorkspaceInfo]? = nil,
        workspaceProblem: String? = nil,
        workspaceKeys: [WorkspaceEnvKey]? = nil
    ) {
        self.hosts = hosts
        self.folder = folder
        self.documentRoot = documentRoot
        self.php = php
        self.server = server
        self.parked = parked
        self.url = url
        self.group = group
        self.parkedFolder = parkedFolder
        self.problem = problem
        self.projectNode = projectNode
        self.nodeSetting = nodeSetting
        self.automaticWorkspaces = automaticWorkspaces
        self.workspaces = workspaces
        self.workspaceProblem = workspaceProblem
        self.workspaceKeys = workspaceKeys
    }

    public var node: String? {
        nodeSetting ?? projectNode?.line
    }
}

// A workspace as the app and nexus workspace list show it. url is nil for a workspace that does
// not run. The problem then says why. A nexusd of part 8b sends only name, worktree, folder and
// branch. An app of part 8b cannot read the sites without worktree, so nexusd always sends it.
public struct WorkspaceInfo: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let worktree: String
    public let folder: String
    public let branch: String?
    public let hosts: [String]?
    public let url: String?
    public let problem: String?
    public let state: WorkspaceState?
    public let startedCopies: [WorkspaceDatabaseCopy]?
    public let finishedCopies: Int?
    public let plannedCopies: Int?
    public let warnings: [String]?

    public var id: String { name }

    public init(
        name: String,
        worktree: String,
        folder: String,
        branch: String? = nil,
        hosts: [String]? = nil,
        url: String? = nil,
        problem: String? = nil,
        state: WorkspaceState? = nil,
        startedCopies: [WorkspaceDatabaseCopy]? = nil,
        finishedCopies: Int? = nil,
        plannedCopies: Int? = nil,
        warnings: [String]? = nil
    ) {
        self.name = name
        self.worktree = worktree
        self.folder = folder
        self.branch = branch
        self.hosts = hosts
        self.url = url
        self.problem = problem
        self.state = state
        self.startedCopies = startedCopies
        self.finishedCopies = finishedCopies
        self.plannedCopies = plannedCopies
        self.warnings = warnings
    }

    // The percentage over all copies. Each database counts the same, because Nexus knows the size
    // of a database only when its copy starts. Between two copies, no task runs and the percentage
    // stays. runningPercent is the percentage of the copy that runs now.
    public func copyPercent(runningPercent: Int?) -> Int? {
        let planned = plannedCopies ?? 0
        let finished = finishedCopies ?? 0

        guard runningPercent != nil || (finished > 0 && finished < planned) else {
            return nil
        }

        guard planned > 0 else {
            return runningPercent
        }

        return min((finished * 100 + (runningPercent ?? 0)) / planned, 100)
    }

    public var isolationProblem: String? {
        if case .notIsolated(let reason) = state {
            return reason
        }

        return nil
    }
}

// What nexus php, composer, node or npm runs (D38). The arguments come before the arguments of
// the user. The environment replaces these keys. The folders of path go first on the PATH. So a
// program that the tool starts gets the same version. An example is php in a Composer script.
public struct ToolCommand: Codable, Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let path: [String]

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], path: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.path = path
    }
}

// The sites in the order of the sidebar. The layout holds every group and every site outside a
// group and outside a parked folder.
public struct SiteList: Codable, Sendable, Equatable {
    public let sites: [SiteInfo]
    public let layout: [SiteLayoutEntry]
    public let parkedFolders: [String]
    public let defaults: SiteDefaults
    public let tld: String

    public init(sites: [SiteInfo], layout: [SiteLayoutEntry], parkedFolders: [String], defaults: SiteDefaults, tld: String) {
        self.sites = sites
        self.layout = layout
        self.parkedFolders = parkedFolders
        self.defaults = defaults
        self.tld = tld
    }
}

// An extension or a module with a switch. The help says what it does.
public struct Toggle: Codable, Sendable, Equatable {
    public let name: String
    public let enabled: Bool
    public let required: Bool
    public let help: String?

    public init(name: String, enabled: Bool, required: Bool, help: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.required = required
        self.help = help
    }
}

// A custom php.ini line that PHP refused (D60). The line counts from 1. It is nil when PHP
// refused the lines together but not one line alone.
public struct PHPSettingsError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let php: String
    public let line: Int?
    public let message: String

    public init(php: String, line: Int?, message: String) {
        self.php = php
        self.line = line
        self.message = message
    }

    public var description: String {
        let place = line.map { "Line \($0): " } ?? ""
        return "\(place)\(message). PHP \(php) keeps its old custom settings."
    }
}

// A Node line of NodeLines.fromProject gives the site the line of its project again.
public struct SiteChange: Codable, Sendable, Equatable {
    public var php: String?
    public var server: WebServer?
    public var aliases: [String]?
    public var node: String?
    public var automaticWorkspaces: Bool?
    public var workspaceKeys: [WorkspaceEnvKey]?

    public init(php: String? = nil, server: WebServer? = nil, aliases: [String]? = nil, node: String? = nil, automaticWorkspaces: Bool? = nil, workspaceKeys: [WorkspaceEnvKey]? = nil) {
        self.php = php
        self.server = server
        self.aliases = aliases
        self.node = node
        self.automaticWorkspaces = automaticWorkspaces
        self.workspaceKeys = workspaceKeys
    }
}

public struct DatabaseInstance: Codable, Sendable, Equatable {
    public let id: String
    public let kind: DatabaseKind
    public let version: String
    public let port: Int
    public let account: DatabaseAccount
    public let running: Bool
    public let dataFolder: String

    public init(id: String, kind: DatabaseKind, version: String, port: Int, account: DatabaseAccount, running: Bool, dataFolder: String) {
        self.id = id
        self.kind = kind
        self.version = version
        self.port = port
        self.account = account
        self.running = running
        self.dataFolder = dataFolder
    }

    public func url(database: String? = nil) -> URL? {
        kind.url(port: port, account: account, database: database)
    }
}

extension DatabaseKind {
    // Without a database, a PostgreSQL client opens the database with the name of the user,
    // and initdb makes no database root. So PostgreSQL opens the database postgres. An empty
    // password gives no password in the link.
    public func url(port: Int, account: DatabaseAccount, database: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.user = account.user
        components.password = account.password.isEmpty ? nil : account.password
        components.host = "127.0.0.1"
        components.port = port
        components.path = (database ?? (self == .postgresql ? "postgres" : nil)).map { "/\($0)" } ?? ""
        return components.url
    }
}

// usedBy names the sites whose .env points to this database.
public struct DatabaseSize: Codable, Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let usedBy: [String]?

    public init(name: String, bytes: Int64, usedBy: [String]? = nil) {
        self.name = name
        self.bytes = bytes
        self.usedBy = usedBy
    }
}

// A start that failed because another program listens on the port of the service (D31). The
// owner is nil when the program belongs to another user, because lsof cannot see it then.
public struct PortConflict: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let service: String
    public let port: Int
    public let owner: PortOwner?
    public let suggestedPort: Int

    public init(service: String, port: Int, owner: PortOwner?, suggestedPort: Int) {
        self.service = service
        self.port = port
        self.owner = owner
        self.suggestedPort = suggestedPort
    }

    public var description: String {
        let holder = owner.map { "\($0.description)" } ?? "a process that Nexus cannot see, probably one of another user"
        return "Port \(port) is in use by \(holder). Stop that app, or give \(service) another port, for example: nexus port \(service) \(suggestedPort)"
    }
}

// The apps that open a database (D36), in the order that Nexus tries them.
public enum DatabaseApp: String, Codable, Sendable, CaseIterable {
    case tablePlus = "table_plus"
    case sequelAce = "sequel_ace"

    public var name: String {
        switch self {
        case .tablePlus: "TablePlus"
        case .sequelAce: "Sequel Ace"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .tablePlus: "com.tinyapp.TablePlus"
        case .sequelAce: "com.sequel-ace.sequel-ace"
        }
    }

    public func opens(_ kind: DatabaseKind) -> Bool {
        self == .tablePlus || kind.usesMySQLProtocol
    }
}

// The server that a copy reads from. A port of nil means the standard port of the instance
// that receives the copy, for example 3306 for MySQL.
public struct DatabaseServer: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var account: DatabaseAccount

    public init(host: String = "127.0.0.1", port: Int? = nil, account: DatabaseAccount = .standard) {
        self.host = host
        self.port = port
        self.account = account
    }
}

// Copies a database from another server into an instance of Nexus (D37). The other server is
// only read.
public struct DatabaseCopy: Codable, Sendable, Equatable {
    public var source: DatabaseServer
    public var database: String
    public var instance: String
    public var name: String?
    public var replace: Bool

    public init(source: DatabaseServer, database: String, instance: String, name: String? = nil, replace: Bool = false) {
        self.source = source
        self.database = database
        self.instance = instance
        self.name = name
        self.replace = replace
    }
}

// One service as the app shows it. The name is the package, for example nginx, httpd, php or
// mysql. DNS has the name dns and no line or version. A problem does not change the state: a DNS
// server that macOS does not use yet still runs and holds its port. Only a database instance has
// an account. Only a service with its own data has a data folder. The toggles are the extensions
// of PHP and the modules of nginx and Apache. Only PHP has custom settings. usedBy names the
// sites of a PHP version. The note explains how the service works.
public struct ServiceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let line: String
    public let version: String
    public let ports: [Int]
    public let state: ServiceState
    public let problem: String?
    public let portConflict: PortConflict?
    public let logFile: String?
    public let dataFolder: String?
    public let account: DatabaseAccount?
    public let toggles: [Toggle]?
    public let customSettings: [String]?
    public let usedBy: [String]?
    public let note: String?

    public init(
        id: String,
        name: String,
        line: String,
        version: String,
        ports: [Int],
        state: ServiceState,
        problem: String? = nil,
        portConflict: PortConflict? = nil,
        logFile: String? = nil,
        dataFolder: String? = nil,
        account: DatabaseAccount? = nil,
        toggles: [Toggle]? = nil,
        customSettings: [String]? = nil,
        usedBy: [String]? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.line = line
        self.version = version
        self.ports = ports
        self.state = state
        self.problem = problem
        self.portConflict = portConflict
        self.logFile = logFile
        self.dataFolder = dataFolder
        self.account = account
        self.toggles = toggles
        self.customSettings = customSettings
        self.usedBy = usedBy
        self.note = note
    }
}

public struct ServiceList: Codable, Sendable, Equatable {
    public let services: [ServiceInfo]
    // The services that "Start stopped services" starts (D63).
    public let stoppedByStopAll: [String]
    // Whether other devices on the network can open the sites. nginx applies it.
    public let lanAccess: Bool?
    // The account that a new database instance gets at its first start (D35).
    public let newInstanceAccount: DatabaseAccount?

    public init(services: [ServiceInfo], stoppedByStopAll: [String], lanAccess: Bool? = nil, newInstanceAccount: DatabaseAccount? = nil) {
        self.services = services
        self.stoppedByStopAll = stoppedByStopAll
        self.lanAccess = lanAccess
        self.newInstanceAccount = newInstanceAccount
    }
}

// The root CA of Nexus. validUntil is nil when Nexus has no root CA yet. Nexus makes it for the
// first site or at the first trust.
public struct RootCertificateInfo: Codable, Sendable, Equatable {
    public let trusted: Bool
    public let validUntil: Date?
    public let file: String

    public init(trusted: Bool, validUntil: Date?, file: String) {
        self.trusted = trusted
        self.validUntil = validUntil
        self.file = file
    }
}

// The work of a task that runs in nexusd. An update is a download of a newer build of a version
// line that is installed already.
public enum TaskWork: Codable, Sendable, Equatable {
    case install(name: String, line: String, version: String, update: Bool)
    case copyDatabase(database: String, instance: String, name: String)
}

// A task that runs for a long time and can stop (part 6f). completed and total count bytes. The
// total of a database copy is an estimate from the size of the tables on the other server, so
// completed can pass it. A database copy of MySQL or MariaDB names the table that it copies.
// PostgreSQL gives no table names in its dump.
public struct TaskInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let work: TaskWork
    public let started: Date
    public let completed: Int64
    public let total: Int64?
    public let table: String?
    public let tableNumber: Int?
    public let tableCount: Int?

    public init(id: String, work: TaskWork, started: Date, completed: Int64 = 0, total: Int64? = nil, table: String? = nil, tableNumber: Int? = nil, tableCount: Int? = nil) {
        self.id = id
        self.work = work
        self.started = started
        self.completed = completed
        self.total = total
        self.table = table
        self.tableNumber = tableNumber
        self.tableCount = tableCount
    }
}

public struct TaskList: Codable, Sendable, Equatable {
    public let tasks: [TaskInfo]

    public init(tasks: [TaskInfo]) {
        self.tasks = tasks
    }
}

// What nexusd sends to the app without a request, after each change.
public enum NexusEvent: Codable, Sendable, Equatable {
    case services(ServiceList)
    case sites(SiteList)
    case tasks(TaskList)
}

public enum NexusRequest: Codable, Sendable, Equatable {
    case status
    case start(service: String)
    case stop(service: String)
    case restart(service: String)
    case stopAll
    case startStopped
    case setPort(service: String, port: Int)
    case available
    case installed
    case install(name: String, line: String)
    case remove(name: String, line: String)
    case trust
    case rootCertificate
    case certificate(hosts: [String])
    case hosts
    case addHost(String)
    case removeHost(String)
    case uninstall
    case sites
    case addSite(folder: String, host: String?, aliases: [String], php: String?, server: WebServer?, group: String? = nil)
    case removeSite(host: String)
    case editSite(host: String, change: SiteChange)
    case park(folder: String, php: String?, server: WebServer?)
    case unpark(folder: String)
    case setSiteLayout([SiteLayoutEntry])
    case siteDefaults
    case setSiteDefaults(SiteDefaults)
    case extensions(php: String)
    case setExtension(php: String, name: String, enabled: Bool)
    case modules(server: WebServer)
    case setModule(server: WebServer, name: String, enabled: Bool)
    case customSettings(php: String)
    case setCustomSettings(php: String, lines: [String])
    case lan(enabled: Bool?)
    // nil shows the dev TLD. Another value changes it.
    case tld(String?)
    case databases
    case databaseSizes(instance: String)
    case setAccount(instance: String, account: DatabaseAccount)
    case setNewInstanceAccount(DatabaseAccount)
    case copyDatabase(DatabaseCopy)
    // The databases on another server, read with the client of the instance.
    case sourceDatabases(source: DatabaseServer, instance: String)
    case stopTask(id: String)
    // The command that a tool runs in this folder, with the versions of its site (D38).
    case tool(ProjectTool, folder: String)
    // The configuration of the Laravel application that holds this folder (D43). php is a version
    // line. Without it the PHP of the site applies.
    case probe(folder: String, php: String?)
    // What the .env of each workspace of this site gets, with {workspace} in the values.
    case workspaceEnv(host: String)
    case retryWorkspace(host: String, name: String)
}

public enum NexusResponse: Codable, Sendable, Equatable {
    case done(message: String)
    case services([ServiceStatus])
    case available([ManifestPackage])
    case installed([InstalledRuntime])
    case hosts([String])
    case sites([SiteInfo])
    case siteDefaults(SiteDefaults)
    case toggles([Toggle])
    case lines([String])
    case databases([DatabaseInstance])
    case databaseSizes([DatabaseSize])
    case rootCertificate(RootCertificateInfo)
    case portInUse(PortConflict)
    case invalidSettings(PHPSettingsError)
    // A task that stopped because the user asked for it. The message says what changed.
    case stopped(message: String)
    case failure(message: String)
    case tool(ToolCommand)
    case configuration(LaravelConfiguration)
    case workspaceEnv([WorkspaceEnvKey])
}

public enum NexusMessageCoding {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
