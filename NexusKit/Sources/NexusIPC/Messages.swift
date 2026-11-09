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
// only for a site without a chosen line. runsAs is nil for a nexusd from before D67. command is
// the command that the user chose for a Node.js app, or nil for the script of package.json.
// projectCommand and framework come from package.json and the lock file, only for a Node.js app.
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
    public let workspaceCommands: [String]?
    public let backgroundCommands: [String]?
    public let workspaceProcesses: Bool?
    public let mainProcesses: Bool?
    public let processProblems: [String]?
    public let runsAs: SiteKind?
    public let command: String?
    public let address: String?
    public let projectCommand: String?
    public let framework: NodeFramework?
    public let app: AppProcessInfo?
    // The type of a PHP site (Phase 4, 3a). nexusd of 0.1.1 sends none.
    public let projectType: PHPProjectType?
    // The choice of the databases of new workspaces. nil follows Settings > Workspaces.
    public let workspaceDatabases: WorkspaceDatabaseKind?
    public let workspaceSeeders: Bool?
    // The command of the migrations of a Node.js app, for an empty database of a workspace.
    public let migrationCommand: String?
    // The document root that the user chose, as a folder in the site folder. nil is automatic.
    public let documentRootSetting: String?
    // The commands that run in a workspace before Nexus removes it.
    public let removalCommands: [String]?

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
        workspaceKeys: [WorkspaceEnvKey]? = nil,
        workspaceCommands: [String]? = nil,
        backgroundCommands: [String]? = nil,
        workspaceProcesses: Bool? = nil,
        mainProcesses: Bool? = nil,
        processProblems: [String]? = nil,
        runsAs: SiteKind? = nil,
        command: String? = nil,
        address: String? = nil,
        projectCommand: String? = nil,
        framework: NodeFramework? = nil,
        app: AppProcessInfo? = nil,
        projectType: PHPProjectType? = nil,
        workspaceDatabases: WorkspaceDatabaseKind? = nil,
        workspaceSeeders: Bool? = nil,
        migrationCommand: String? = nil,
        documentRootSetting: String? = nil,
        removalCommands: [String]? = nil
    ) {
        self.documentRootSetting = documentRootSetting
        self.removalCommands = removalCommands
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
        self.workspaceCommands = workspaceCommands
        self.backgroundCommands = backgroundCommands
        self.workspaceProcesses = workspaceProcesses
        self.mainProcesses = mainProcesses
        self.processProblems = processProblems
        self.runsAs = runsAs
        self.command = command
        self.address = address
        self.projectCommand = projectCommand
        self.framework = framework
        self.app = app
        self.projectType = projectType
        self.workspaceDatabases = workspaceDatabases
        self.workspaceSeeders = workspaceSeeders
        self.migrationCommand = migrationCommand
    }

    // A WordPress site always gets a copy, because WordPress has no migrations. A proxy site and a
    // PHP site that is no Laravel application get no databases in a workspace (D54).
    public var offersEmptyDatabases: Bool {
        switch kind {
        case .node: true
        case .php: projectType == .laravel
        case .proxy: false
        }
    }

    public var node: String? {
        nodeSetting ?? projectNode?.line
    }

    public var kind: SiteKind {
        runsAs ?? .php
    }
}

// A database of a workspace, for `nexus workspace info` (D38).
public struct WorkspaceDatabaseInfo: Codable, Sendable, Hashable {
    public let name: String
    public let instance: String
    public let port: Int?

    public init(name: String, instance: String, port: Int?) {
        self.name = name
        self.instance = instance
        self.port = port
    }

    // A script reads this key in the JSON of nexus workspace info. So a port without a value is null.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(instance, forKey: .instance)
        try container.encode(port, forKey: .port)
    }
}

// The Node.js app of a main checkout or of a workspace (D67). state is nil while nexusd does not
// run the app, for example while a workspace is in Preparing. log is the path of its log file.
public struct AppProcessInfo: Codable, Sendable, Hashable {
    public let port: Int?
    public let command: String?
    public let state: ServiceState?
    public let log: String

    public init(port: Int?, command: String?, state: ServiceState?, log: String) {
        self.port = port
        self.command = command
        self.state = state
        self.log = log
    }

    public var stateText: String {
        switch state {
        case .running(_, let since): "Running since \(since.formatted(date: .omitted, time: .shortened))"
        case .restarting(let attempt): "Starts again, attempt \(attempt)"
        case .failed: "Does not run"
        case .stopped, nil: "Not started"
        }
    }

    public var summary: String {
        "\(port.map { "port \($0)" } ?? "no port yet"), \(stateText.prefix(1).lowercased())\(stateText.dropFirst())"
    }
}

// The change of the links in the posts of a WordPress workspace that did not end yet (Phase 4, 3e).
// progress goes from 0 to 1.
public struct WorkspaceLinkInfo: Codable, Sendable, Hashable {
    public let from: [String]
    public let to: String
    public let progress: Double

    public init(from: [String], to: String, progress: Double) {
        self.from = from
        self.to = to
        self.progress = progress
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
    public let warnings: [String]?
    public let databases: [WorkspaceDatabaseInfo]?
    public let redisIndexes: [String: Int]?
    public let ports: [String: Int]?
    public let app: AppProcessInfo?
    public let links: WorkspaceLinkInfo?

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
        warnings: [String]? = nil,
        databases: [WorkspaceDatabaseInfo]? = nil,
        redisIndexes: [String: Int]? = nil,
        ports: [String: Int]? = nil,
        app: AppProcessInfo? = nil,
        links: WorkspaceLinkInfo? = nil
    ) {
        self.name = name
        self.worktree = worktree
        self.folder = folder
        self.branch = branch
        self.hosts = hosts
        self.url = url
        self.problem = problem
        self.state = state
        self.warnings = warnings
        self.databases = databases
        self.redisIndexes = redisIndexes
        self.ports = ports
        self.app = app
        self.links = links
    }

    public var isolationProblem: String? {
        if case .notIsolated(let reason) = state {
            return reason
        }

        return nil
    }

    public var isolationMessage: String? {
        guard let isolationProblem else {
            return nil
        }

        let reason = isolationProblem.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsWithArticle = reason.hasPrefix("The ") || reason.hasPrefix("A ")
        let cause = startsWithArticle ? "\(reason.prefix(1).lowercased())\(reason.dropFirst())" : reason
        let sentence = cause.hasSuffix(".") ? cause : "\(cause)."

        return "\(name) is not isolated: \(sentence) Nexus starts no background process for it."
    }
}

// What nexus php, composer, node or npm runs (D38). The arguments come before the arguments of
// the user. The environment replaces these keys. The folders of path go first on the PATH. So a
// program that the tool starts gets the same version. An example is php in a Composer script.
public struct ToolCommand: Codable, Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public var environment: [String: String]
    public let path: [String]
    // The core folder of WordPress for nexus wp. The nexus command adds it as --path, because only
    // the nexus command sees the arguments of the user (Phase 4, 3c).
    public var wordPressCore: String?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], path: [String] = [], wordPressCore: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.path = path
        self.wordPressCore = wordPressCore
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
    // What a new workspace of a site on Default gets. nexusd from before this choice sends none.
    public let newWorkspaceDatabases: WorkspaceDatabaseKind?

    public init(sites: [SiteInfo], layout: [SiteLayoutEntry], parkedFolders: [String], defaults: SiteDefaults, tld: String, newWorkspaceDatabases: WorkspaceDatabaseKind? = nil) {
        self.sites = sites
        self.layout = layout
        self.parkedFolders = parkedFolders
        self.defaults = defaults
        self.tld = tld
        self.newWorkspaceDatabases = newWorkspaceDatabases
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

// A Node line of NodeLines.fromProject gives the site the line of its project again. A command of
// Site.commandFromProject gives the site the script of package.json again.
public struct SiteChange: Codable, Sendable, Equatable {
    public var php: String?
    public var server: WebServer?
    public var aliases: [String]?
    public var node: String?
    public var automaticWorkspaces: Bool?
    public var workspaceKeys: [WorkspaceEnvKey]?
    public var workspaceCommands: [String]?
    public var backgroundCommands: [String]?
    public var workspaceProcesses: Bool?
    public var mainProcesses: Bool?
    public var runsAs: SiteKind?
    public var command: String?
    public var address: String?
    public var workspaceDatabases: WorkspaceDatabaseChoice?
    public var workspaceSeeders: Bool?
    // A folder in the site folder. An empty value gives the automatic document root again.
    public var documentRoot: String?
    public var removalCommands: [String]?

    public init(
        php: String? = nil,
        server: WebServer? = nil,
        aliases: [String]? = nil,
        node: String? = nil,
        automaticWorkspaces: Bool? = nil,
        workspaceKeys: [WorkspaceEnvKey]? = nil,
        workspaceCommands: [String]? = nil,
        backgroundCommands: [String]? = nil,
        workspaceProcesses: Bool? = nil,
        mainProcesses: Bool? = nil,
        runsAs: SiteKind? = nil,
        command: String? = nil,
        address: String? = nil,
        workspaceDatabases: WorkspaceDatabaseChoice? = nil,
        workspaceSeeders: Bool? = nil,
        documentRoot: String? = nil,
        removalCommands: [String]? = nil
    ) {
        self.documentRoot = documentRoot
        self.removalCommands = removalCommands
        self.php = php
        self.server = server
        self.aliases = aliases
        self.node = node
        self.automaticWorkspaces = automaticWorkspaces
        self.workspaceKeys = workspaceKeys
        self.workspaceCommands = workspaceCommands
        self.backgroundCommands = backgroundCommands
        self.workspaceProcesses = workspaceProcesses
        self.mainProcesses = mainProcesses
        self.runsAs = runsAs
        self.command = command
        self.address = address
        self.workspaceDatabases = workspaceDatabases
        self.workspaceSeeders = workspaceSeeders
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

// A database that a site or a workspace uses (owner, 2026-11-09, Herd item 19). A database on a
// server of Nexus has its instance, its kind and the account of that server. A workspace uses the
// server of the workspace (D66), so its port is not the port of the instance. connection is the
// Laravel connection. WordPress and a workspace have none.
public struct DatabaseConnectionInfo: Codable, Sendable, Equatable {
    public let connection: String?
    public let database: String
    public let host: String
    public let port: Int?
    public let instance: String?
    public let kind: DatabaseKind?
    public let account: DatabaseAccount?

    public init(connection: String?, database: String, host: String, port: Int?, instance: String?, kind: DatabaseKind?, account: DatabaseAccount?) {
        self.connection = connection
        self.database = database
        self.host = host
        self.port = port
        self.instance = instance
        self.kind = kind
        self.account = account
    }

    public var url: URL? {
        guard let kind, let port, let account else {
            return nil
        }

        return kind.url(port: port, account: account, database: database.isEmpty ? nil : database)
    }
}

// A database server of Nexus: an instance, or the server of a workspace on a clone of an instance
// (D66). site is a host of the site of the workspace.
public enum DatabaseTarget: Codable, Sendable, Equatable {
    case instance(String)
    case workspace(site: String, name: String, instance: String)
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
// owner is nil when the program belongs to another user, because lsof cannot see it then. A
// service with more ports, such as nginx or the mail service, names the port with portKey. An
// older nexusd sends no portKey.
public struct PortConflict: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let service: String
    public let port: Int
    public let owner: PortOwner?
    public let suggestedPort: Int
    public let portKey: String?

    public init(service: String, port: Int, owner: PortOwner?, suggestedPort: Int, portKey: String? = nil) {
        self.service = service
        self.port = port
        self.owner = owner
        self.suggestedPort = suggestedPort
        self.portKey = portKey
    }

    public var description: String {
        let holder = owner.map { "\($0.description)" } ?? "a process that Nexus cannot see, probably one of another user"
        return "Port \(port) is in use by \(holder). Stop that app, or give \(service) another port, for example: nexus port \(portKey ?? service) \(suggestedPort)"
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
    // The build of the running nexusd. An older nexusd does not send it.
    public let build: String?
    // The new build of the app on disk, which nexusd starts by itself after its work. When it is
    // the build of the app, the app does not restart nexusd. A nexusd of 0.1.1 and older does not
    // send it.
    public let updateBuild: String?
    // The name, line and version of each installed package. Node, Composer and WP-CLI have no
    // service. So without this list the app did not see a remove of them from the command line.
    // An older nexusd does not send it.
    public let installed: [String]?

    public init(services: [ServiceInfo], stoppedByStopAll: [String], lanAccess: Bool? = nil, newInstanceAccount: DatabaseAccount? = nil, build: String? = nil, updateBuild: String? = nil, installed: [String]? = nil) {
        self.services = services
        self.stoppedByStopAll = stoppedByStopAll
        self.lanAccess = lanAccess
        self.newInstanceAccount = newInstanceAccount
        self.build = build
        self.updateBuild = updateBuild
        self.installed = installed
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
    case dumpDatabase(name: String, instance: String)
    case createSite(name: String, template: SiteTemplate)
    case importSite(name: String)
}

public enum TaskStepState: String, Codable, Sendable {
    case waiting
    case running
    case done
    case failed
}

// One step of a task with steps, such as a new site (3i). detail is the label of the spinner of
// the tool that runs now. seconds is the time of a step that ended.
public struct TaskStep: Codable, Sendable, Equatable {
    public var title: String
    public var state: TaskStepState
    public var detail: String?
    public var seconds: Int?

    public init(title: String, state: TaskStepState = .waiting, detail: String? = nil, seconds: Int? = nil) {
        self.title = title
        self.state = state
        self.detail = detail
        self.seconds = seconds
    }
}

// One file in the Nexus trash (D53).
public struct DatabaseDump: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let bytes: Int64
    public let date: Date

    public var id: String { path }

    public init(name: String, path: String, bytes: Int64, date: Date) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.date = date
    }
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
    public let steps: [TaskStep]?
    public let log: [String]?
    public let logFile: String?

    public init(id: String, work: TaskWork, started: Date, completed: Int64 = 0, total: Int64? = nil, table: String? = nil, tableNumber: Int? = nil, tableCount: Int? = nil, steps: [TaskStep]? = nil, log: [String]? = nil, logFile: String? = nil) {
        self.id = id
        self.work = work
        self.started = started
        self.completed = completed
        self.total = total
        self.table = table
        self.tableNumber = tableNumber
        self.tableCount = tableCount
        self.steps = steps
        self.log = log
        self.logFile = logFile
    }
}

// The answer to a new site. The password of the admin user of WordPress comes only here. Nexus
// does not store it (3l).
public struct CreatedSite: Codable, Sendable, Equatable {
    public let host: String
    public let url: String
    public let folder: String
    public let message: String
    public let adminUser: String?
    public let adminPassword: String?

    public init(host: String, url: String, folder: String, message: String, adminUser: String? = nil, adminPassword: String? = nil) {
        self.host = host
        self.url = url
        self.folder = folder
        self.message = message
        self.adminUser = adminUser
        self.adminPassword = adminPassword
    }
}

// A new site that failed keeps its folder, its database and its log, so the user can look at
// them. id names them for "Move to trash".
public struct SiteCreationFailure: Codable, Sendable, Equatable {
    public let id: String
    public let message: String
    public let steps: [TaskStep]
    public let log: [String]
    public let logFile: String
    public let folder: String
    public let database: String?
    // The host of a site that is in Nexus already. "Move to trash" removes it too.
    public let site: String?

    public init(id: String, message: String, steps: [TaskStep], log: [String], logFile: String, folder: String, database: String?, site: String? = nil) {
        self.id = id
        self.message = message
        self.steps = steps
        self.log = log
        self.logFile = logFile
        self.folder = folder
        self.database = database
        self.site = site
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
    // The switch "Send crash reports to Nexus" of Settings > Advanced. nexusd reads the setting at
    // its start, and this request applies a change at once.
    case crashReports(enabled: Bool)
    case sites
    case addSite(folder: String, host: String?, aliases: [String], php: String?, server: WebServer?, group: String? = nil, runsAs: SiteKind? = nil, command: String? = nil, address: String? = nil, node: String? = nil, workspaceDatabases: WorkspaceDatabaseKind? = nil)
    // A new site from a template (3i). The answer is siteCreated or siteNotCreated.
    case createSite(NewSite)
    // Moves the folder of a new site that failed to the Trash and drops its database. Only what
    // that task made goes.
    case removeSiteLeftovers(id: String)
    // A backup of WordPress (3f). The answer to inspect is backup, and an import answers as
    // createSite does.
    case inspectBackup(path: String)
    case importSite(SiteImport)
    case removeSite(host: String)
    case editSite(host: String, change: SiteChange)
    // Starts the Node.js app of the main checkout again, or of the workspace with this name (D67).
    case restartApp(host: String, workspace: String?)
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
    // The command that a tool runs in this folder, with the versions of its site (D38). The
    // arguments can name the folder of another site, for example php /Sites/shop/artisan. That
    // site wins then. An older nexus command sends no argumentFolder.
    case tool(ProjectTool, folder: String, argumentFolder: String? = nil)
    // The configuration of the Laravel application that holds this folder (D43). php is a version
    // line. Without it the PHP of the site applies.
    case probe(folder: String, php: String?)
    // What the .env of each workspace of this site gets, with {workspace} in the values.
    case workspaceEnv(host: String)
    // The database connections of a Laravel site, for its Site screen.
    case siteDatabases(host: String)
    // The databases of a site or of one of its workspaces, with the account of the server, for
    // nexus db connection.
    case databaseConnections(host: String, workspace: String?)
    // The databases on a server of Nexus, and a new empty database there. No request drops a
    // database, so an agent cannot remove one by mistake.
    case serverDatabases(DatabaseTarget)
    case createDatabase(DatabaseTarget, name: String)
    // The configuration and the database of a WordPress site (Phase 4, 3b), and the three actions of
    // its Site screen.
    case wordPressSite(host: String)
    // The values that the user confirmed. nexusd refuses when they are not true any more.
    case setUpWordPress(host: String, database: String, instance: String)
    case createWordPressDatabase(host: String)
    // A user also sets DB_USER and DB_PASSWORD to the account of the instance.
    case setWordPressDBHost(host: String, value: String, user: String?)
    // The site URL and HTTPS (Phase 4, 3d). The plan is what the user confirmed.
    case changeWordPressURLs(host: String, plan: WordPressURLPlan)
    case undoWordPressURLChange(host: String, plan: WordPressURLPlan)
    // The server, the account and the database of wp-config.php, for "Copy to Nexus…". The
    // password is in it, so the Site screen asks for it only after the click.
    case wordPressCopySource(host: String)
    // The plugins that the user confirmed (Phase 4, 3h).
    case turnOffMailPlugins(host: String, folders: [String])
    // The lines for workspaces in a tracked wp-config.php that the user confirmed (Phase 4, 3e).
    case addWordPressWorkspaceLines(host: String, lines: WordPressWorkspaceLines)
    // The background processes of a site that the user did not change (D52).
    case backgroundPreset(host: String)
    case retryWorkspace(host: String, name: String)
    // Makes a workspace for the worktree that holds this folder (D40).
    case createWorkspace(folder: String, databases: WorkspaceDatabaseKind? = nil)
    // Makes a git worktree for a branch of the site that holds this folder, and its workspace.
    case createWorktree(folder: String, branch: String, databases: WorkspaceDatabaseKind? = nil)
    // Removes the worktree with git. The workspace then goes as for each removal (D53).
    case removeWorkspace(host: String, name: String, force: Bool)
    case workspaceSettings
    case setWorkspaceSettings(WorkspaceSettings)
    case dumps
    case emptyTrash
    // file is a path, or a name in the Nexus trash.
    case restoreDump(file: String, instance: String, name: String)
    // The mail service (Phase 3): its ports, the outbox and the settings.
    case mailStatus
    case clearOutbox
    case setMailSettings(MailSettings)
    // The user saw the number of mails that the limits removed. The count starts again at 0.
    case acknowledgeRemovedMails
    // Where the main checkout of a site sends its mail, "Send mail to Nexus" for a Laravel site
    // and the way back (Phase 3, 3c). Nexus changes the .env of a main checkout only after a
    // click (D44).
    case siteMail(host: String)
    case sendMailToNexus(host: String)
    case restoreMailSettings(host: String)
}

// Where a site sends its mail, for the Site screen. warning names a provider that can reach a real
// person, or TLS that the mail service does not offer. canSendToNexus shows "Send mail to Nexus…"
// and changes holds the keys that it writes. canRestore shows "Use the old mail settings…",
// because the .env has the comment lines of Nexus. problem holds the reason when the probe of the
// site failed.
public struct SiteMail: Codable, Sendable, Equatable {
    public let sendsToNexus: Bool
    public let warning: String?
    public let canSendToNexus: Bool
    public let problem: String?
    // The server or the provider that gets the mail when it is not the inbox of Nexus, for
    // example smtp.postmarkapp.com or the sendmail of macOS.
    public let destination: String?
    public let changes: [EnvKeyChange]
    public let canRestore: Bool
    // The active plugins of a WordPress site that send the mail themselves (Phase 4, 3h).
    public let mailPlugins: [WordPressMailPlugin]

    public init(sendsToNexus: Bool, warning: String? = nil, canSendToNexus: Bool = false, problem: String? = nil, destination: String? = nil, changes: [EnvKeyChange] = [], canRestore: Bool = false, mailPlugins: [WordPressMailPlugin] = []) {
        self.sendsToNexus = sendsToNexus
        self.warning = warning
        self.canSendToNexus = canSendToNexus
        self.problem = problem
        self.destination = destination
        self.changes = changes
        self.canRestore = canRestore
        self.mailPlugins = mailPlugins
    }

    // A nexusd of an older build sends no changes and no canRestore until it restarts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sendsToNexus = try container.decode(Bool.self, forKey: .sendsToNexus)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        canSendToNexus = try container.decode(Bool.self, forKey: .canSendToNexus)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        changes = try container.decodeIfPresent([EnvKeyChange].self, forKey: .changes) ?? []
        canRestore = try container.decodeIfPresent(Bool.self, forKey: .canRestore) ?? false
        mailPlugins = try container.decodeIfPresent([WordPressMailPlugin].self, forKey: .mailPlugins) ?? []
    }
}

// A plugin, a mu-plugin, a theme or another file that can send the mail of WordPress itself. certain
// is false for code that only answers pre_wp_mail. Such code can also block each mail, as a plugin
// for a staging site does. WP-CLI can turn off only a plugin. A network plugin of a multisite needs
// --network.
public struct WordPressMailPlugin: Codable, Sendable, Hashable {
    public let folder: String
    public let name: String
    public let kind: WordPressMailPlugins.SourceKind
    public let certain: Bool

    public init(folder: String, name: String, kind: WordPressMailPlugins.SourceKind, certain: Bool = true) {
        self.folder = folder
        self.name = name
        self.kind = kind
        self.certain = certain
    }

    public var canTurnOff: Bool {
        certain && (kind == .plugin || kind == .networkPlugin)
    }

    // "the plugin WP Mail SMTP", "the theme shop", "the file mailer in mu-plugins" or "the file
    // vendor/mailer.php".
    public var description: String {
        switch kind {
        case .plugin, .networkPlugin: "the plugin \(name)"
        case .mustUse: "the file \(name) in mu-plugins"
        case .theme: "the theme \(name)"
        case .other: "the file \(name)"
        }
    }
}

// A key that "Send mail to Nexus" writes into a .env, with its new value. isNew means that the
// .env has no line for this key yet.
public struct EnvKeyChange: Codable, Sendable, Hashable {
    public let key: String
    public let value: String
    public let isNew: Bool

    public init(key: String, value: String, isNew: Bool) {
        self.key = key
        self.value = value
        self.isNew = isNew
    }
}

// What the Mail screen and nexus mail show. The inbox port is nil while the mail package is not
// installed. waiting counts the mails in the outbox, removed the mails that its limits removed
// since the last clear, and refused the mails that Mailpit refused for good.
public struct MailStatus: Codable, Sendable, Equatable {
    public let installed: Bool
    public let running: Bool
    public let receiving: Bool
    public let smtpPort: Int?
    public let inboxPort: Int?
    public let waiting: Int
    public let waitingBytes: Int
    public let removed: Int
    public let refused: Int
    public let outboxFolder: String
    public let settings: MailSettings

    public init(installed: Bool, running: Bool, receiving: Bool, smtpPort: Int?, inboxPort: Int?, waiting: Int, waitingBytes: Int, removed: Int, refused: Int, outboxFolder: String, settings: MailSettings) {
        self.installed = installed
        self.running = running
        self.receiving = receiving
        self.smtpPort = smtpPort
        self.inboxPort = inboxPort
        self.waiting = waiting
        self.waitingBytes = waitingBytes
        self.removed = removed
        self.refused = refused
        self.outboxFolder = outboxFolder
        self.settings = settings
    }
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
    // Nexus has no package of the tool. A link in bin/ then runs the next program on the PATH.
    case toolNotInstalled(message: String)
    case configuration(LaravelConfiguration)
    case siteDatabases([SiteDatabase])
    case databaseConnections([DatabaseConnectionInfo])
    case wordPressSite(WordPressSiteInfo)
    case wordPressCopySource(WordPressCopySource)
    case workspaceEnv([WorkspaceEnvKey])
    case workspaceSettings(WorkspaceSettings)
    case dumps([DatabaseDump])
    case backgroundPreset([String])
    case mailStatus(MailStatus)
    case siteMail(SiteMail)
    case siteCreated(CreatedSite)
    case siteNotCreated(SiteCreationFailure)
    case backup(BackupInfo)
}

// What the Site screen of a WordPress site shows (Phase 4, 3b). configFile is nil without a
// wp-config.php, and for Bedrock it names the .env. instance is the Nexus instance that DB_HOST
// names. databaseExists is nil when Nexus cannot check it, for example on a stopped instance. home
// and siteURL come from the options table of the database. The password is not in it. Without a
// wp-config.php, setUpDatabase and setUpInstance say what "Set up WordPress" makes.
// suggestedDBHost is the value that "Set DB_HOST" writes. url is the URL of Nexus for the site.
// configHome is WP_HOME of the configuration, from configHomeFile. urlPlan is what "Change the
// URLs" changes, and urlChange is the last change that "Undo…" can put back (3d). copyInstance is the Nexus instance
// that "Copy to Nexus…" copies the database to, when it is on a server that Nexus did not make.
// workspaceLines is set when git tracks wp-config.php and that file does not load
// wp-config-nexus.php, or when the lines are there but not committed (3e).
public struct WordPressSiteInfo: Codable, Sendable, Equatable {
    public let type: PHPProjectType
    public let version: String?
    public let configFile: String?
    public let database: String?
    public let dbHost: String?
    public let instance: String?
    public let databaseExists: Bool?
    public let home: String?
    public let siteURL: String?
    public let problem: String?
    public let setUpDatabase: String?
    public let setUpInstance: String?
    public let suggestedDBHost: String?
    // The user that "Set DB_HOST" writes with the password of the instance. Nil keeps the account.
    public let suggestedUser: String?
    public let url: String?
    public let configHome: String?
    public let configHomeFile: String?
    public let urlPlan: WordPressURLPlan?
    public let urlChange: WordPressURLChange?
    public let copyInstance: String?
    public let workspaceLines: WordPressWorkspaceLines?
    public let network: WordPressNetwork?

    public init(type: PHPProjectType, version: String? = nil, configFile: String? = nil, database: String? = nil, dbHost: String? = nil, instance: String? = nil, databaseExists: Bool? = nil, home: String? = nil, siteURL: String? = nil, problem: String? = nil, setUpDatabase: String? = nil, setUpInstance: String? = nil, suggestedDBHost: String? = nil, suggestedUser: String? = nil, url: String? = nil, configHome: String? = nil, configHomeFile: String? = nil, urlPlan: WordPressURLPlan? = nil, urlChange: WordPressURLChange? = nil, copyInstance: String? = nil, workspaceLines: WordPressWorkspaceLines? = nil, network: WordPressNetwork? = nil) {
        self.workspaceLines = workspaceLines
        self.network = network
        self.setUpDatabase = setUpDatabase
        self.setUpInstance = setUpInstance
        self.suggestedDBHost = suggestedDBHost
        self.suggestedUser = suggestedUser
        self.url = url
        self.configHome = configHome
        self.configHomeFile = configHomeFile
        self.urlPlan = urlPlan
        self.urlChange = urlChange
        self.copyInstance = copyInstance
        self.type = type
        self.version = version
        self.configFile = configFile
        self.database = database
        self.dbHost = dbHost
        self.instance = instance
        self.databaseExists = databaseExists
        self.home = home
        self.siteURL = siteURL
        self.problem = problem
    }
}

// The lines for workspaces in a wp-config.php that git tracks (Phase 4, 3e). missing: the file
// does not load wp-config-nexus.php. changes holds the change for the sheet. It is empty when only
// the line in .gitignore is missing. ignoreFile is the file that gets the line
// wp-config-nexus.php, or nil when git ignores that name already. uncommitted: the lines are there,
// but the last commit does not have them.
public struct WordPressWorkspaceLines: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case missing
        case uncommitted
    }

    public let state: State
    public let configFile: String
    public let changes: [TextChangeLine]
    public let ignoreFile: String?

    public init(state: State, configFile: String, changes: [TextChangeLine] = [], ignoreFile: String? = nil) {
        self.state = state
        self.configFile = configFile
        self.changes = changes
        self.ignoreFile = ignoreFile
    }
}

// A WordPress network (Phase 4, 3g). host is the host of the site in Nexus. sites is the number of
// its sites. example is the name of its second site, as in blog.shop.test or shop.test/blog.
// problem says why Nexus does not serve the names below the host of a network on subdomains.
public struct WordPressNetwork: Codable, Sendable, Equatable {
    public let host: String
    public let subdomains: Bool
    public let sites: Int
    public let example: String?
    public let problem: String?

    public init(host: String, subdomains: Bool, sites: Int, example: String? = nil, problem: String? = nil) {
        self.host = host
        self.subdomains = subdomains
        self.sites = sites
        self.example = example
        self.problem = problem
    }

    // The value of the row "Network" in the app and in nexus site wordpress.
    public var summary: String {
        let count = sites == 1 ? "1 site" : "\(sites) sites"
        let kind = subdomains ? "on subdomains" : "in subfolders"

        return example.map { "\(count) \(kind), for example \($0)" } ?? "\(count) \(kind)"
    }

    // The label of the example below the host, as blog in blog.shop.test.
    public var exampleLabel: String {
        example.flatMap { $0.hasSuffix(".\(host)") ? String($0.dropLast(host.count + 1)) : nil } ?? "blog"
    }

    public var servedText: String? {
        guard subdomains, problem == nil else {
            return nil
        }

        return "Nexus serves each name below \(host) with HTTPS, for example \(exampleLabel).\(host)."
    }
}

// The other server of a WordPress site and the Nexus instance that gets the copy (3d).
public struct WordPressCopySource: Codable, Sendable, Equatable {
    public let server: DatabaseServer
    public let database: String
    public let instance: String

    public init(server: DatabaseServer, database: String, instance: String) {
        self.server = server
        self.database = database
        self.instance = instance
    }
}

extension NexusResponse {
    // nexusd sends this when it cannot read a request. An example is nexus wp to the nexusd of
    // 0.1.1 after an update, until the app starts the new nexusd. Keep the text the same.
    public static let unreadableRequest = NexusResponse.failure(message: "nexusd could not read the request.")
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
