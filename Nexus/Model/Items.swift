import Foundation
import NexusCore
import NexusIPC

enum Health {
    case running
    case stopped
    case attention
    case failed
}

enum ServiceKind: String, CaseIterable, Identifiable {
    case webservers
    case php
    case mysql
    case mariadb
    case postgresql
    case redis
    case dns

    var id: Self { self }

    var title: String {
        switch self {
        case .webservers: "Webservers"
        case .php: "PHP"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .redis: "Redis"
        case .dns: "DNS"
        }
    }

    var systemImage: String {
        switch self {
        case .webservers: "server.rack"
        case .php: "chevron.left.forwardslash.chevron.right"
        case .mysql, .mariadb, .postgresql: "cylinder.split.1x2"
        case .redis: "square.3.layers.3d"
        case .dns: "network"
        }
    }

    var isDatabase: Bool {
        [.mysql, .mariadb, .postgresql].contains(self)
    }
}

// The key is the name of the port in nexusd, for example http, https or mysql-8.4.
struct ServicePort: Identifiable {
    let name: String
    var number: Int
    var key = ""

    var id: String { name }
}

struct DatabaseItem: Identifiable {
    let name: String
    let usedBy: String?
    let size: String?

    var id: String { name }
}

struct ToggleItem: Identifiable {
    let name: String
    var enabled: Bool
    var required = false
    let help: String

    var id: String { name }
}

// The line is nil when PHP refused the lines together but not one line alone.
struct SettingsError {
    let line: Int?
    let message: String
}

// The summary is short, for a row. The detail is the full text of nexusd.
struct ServiceProblem {
    let summary: String
    let detail: String
    var portHolder: PortHolder?
}

struct ServiceVersion: Identifiable {
    let id: String
    let kind: ServiceKind
    let name: String
    let version: String
    var health: Health
    var since: String?
    var activeWithProblem = false
    // The process ended without a request: nexusd starts it again, or it failed.
    var stoppedUnexpectedly = false
    var ports: [ServicePort] = []
    var internalPort = false
    var problem: ServiceProblem?
    var update: String?
    var securityNote: String?
    var dataFolder: String?
    var account: DatabaseAccount?
    var databases: [DatabaseItem] = []
    var toggles: [ToggleItem] = []
    var customSettings: [String] = []
    var usedBy: [String] = []
    var note: String?
    var log: [String] = []
    var logFile: String?
    // The version line in nexusd, for example 8.4. DNS has none.
    var line = ""

    var isRunning: Bool {
        health == .running
    }

    // nexusd keeps some services active while they have a problem: a service that it starts
    // again after an exit that nobody asked for, and a DNS server that macOS does not use yet.
    // Their switch stays on, so the user can stop them.
    var isActive: Bool {
        isRunning || activeWithProblem
    }

    var portSummary: String {
        if kind == .php {
            return "php-fpm"
        }

        if internalPort, let port = ports.first {
            return "internal \(port.number)"
        }

        if ports.count > 1 {
            return ports.map { "\($0.name) \($0.number)" }.joined(separator: " · ")
        }

        return ports.first.map { "\($0.number)" } ?? ""
    }

    var shortPortSummary: String {
        kind == .php ? "fpm" : ports.first.map { "\($0.number)" } ?? ""
    }
}

// The folders show with ~ for the home folder. A site of a parked folder without settings of
// its own cannot be removed. A site of a parked folder with its own settings goes back to the
// settings of the folder.
struct SiteItem: Identifiable, Hashable {
    let host: String
    var aliases: [String] = []
    var group: String?
    let folder: String
    let documentRoot: String
    var server = "nginx"
    var php = "8.4"
    var health: Health = .running
    var url = ""
    var parkedFolder: String?
    var problem: String?
    var hasOwnSettings = true
    // The Node line that the user chose, and the line that the files of the project give (D21).
    var nodeSetting: String?
    var projectNode: NodeChoice?
    var automaticWorkspaces = true
    var workspaces: [WorkspaceInfo] = []
    var workspaceProblem: String?
    var workspaceKeys: [WorkspaceEnvKey] = []

    var id: String { host }

    var node: String? {
        nodeSetting ?? projectNode?.line
    }

    var folderURL: URL {
        URL(filePath: (folder as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    var protectedFolder: String? {
        ProtectedFolder.name(of: folder)
    }
}

// macOS asks the user one time before an app reads Documents, Desktop or Downloads. nexusd,
// nginx and PHP read the files of a site. So macOS asks for Nexus.
enum ProtectedFolder {
    static func name(of path: String) -> String? {
        let path = (path as NSString).abbreviatingWithTildeInPath
        return ["Documents", "Desktop", "Downloads"].first { path == "~/\($0)" || path.hasPrefix("~/\($0)/") }
    }

    static func explanation(_ name: String) -> String {
        "This folder is in \(name). macOS asks one time if Nexus may read \(name), because the webserver and PHP read the files of the site. Click Allow."
    }
}

struct SiteGroup: Identifiable {
    let name: String
    var sites: [SiteItem]

    var id: String { Self.id(named: name) }

    static func id(named name: String) -> String {
        "group:\(name)"
    }
}

// A folder of projects. It looks like a group, and its gear shows that Nexus fills it.
struct ParkedFolder: Identifiable {
    static let systemImage = "folder.badge.gearshape"

    let path: String
    var sites: [SiteItem]

    var id: String { "parked:\(path)" }

    var name: String {
        (path as NSString).lastPathComponent
    }
}

enum SiteEntry: Identifiable {
    case group(SiteGroup)
    case site(SiteItem)
    case parked(ParkedFolder)

    var id: String {
        switch self {
        case .group(let group): group.id
        case .site(let site): site.id
        case .parked(let folder): folder.id
        }
    }

    var sites: [SiteItem] {
        switch self {
        case .group(let group): group.sites
        case .site(let site): [site]
        case .parked(let folder): folder.sites
        }
    }

    var sortRank: Int {
        switch self {
        case .group: 0
        case .site: 1
        case .parked: 2
        }
    }

    var sortName: String {
        switch self {
        case .group(let group): group.name
        case .site(let site): site.host
        case .parked(let folder): folder.name
        }
    }
}

enum PackageState: Equatable {
    case available
    case installed
    case update(String)
    case downloading(Double)
}

// The package is the name in the manifest, for example httpd or mysql. The name is the name
// that the screens show, for example Apache 2.4. A download that runs has the id of its task.
struct PackageItem: Identifiable {
    let section: String
    let package: String
    let line: String
    let name: String
    let version: String
    var state: PackageState
    var lts = false
    var securityEnd: String?
    var securityEnded = false
    var required = false
    var taskID: String?
    var downloadSize: Int?

    var id: String { "\(package)-\(line)" }

    var isInstalled: Bool {
        switch state {
        case .installed, .update: true
        case .available, .downloading: false
        }
    }

    var isDownloading: Bool {
        if case .downloading = state {
            return true
        }

        return false
    }
}

// A task of nexusd that the Overview and the menu bar panel show. An activity of the sample data
// has no task.
struct ActivityItem: Identifiable {
    let id: String
    let title: String
    let shortTitle: String
    var progress: Double
    var taskID: String?

    init(id: String = UUID().uuidString, title: String, shortTitle: String, progress: Double, taskID: String? = nil) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.progress = progress
        self.taskID = taskID
    }
}

// The location is nil for an app of the sample data. An added app is one that the user added,
// because Nexus did not find it.
struct AppChoice: Identifiable, Hashable {
    let name: String
    var opens: String = ""
    var location: URL?
    var added = false

    var id: String { name }

    // MariaDB uses the mysql:// link. So an app that opens MySQL also opens MariaDB.
    func canOpen(_ kind: ServiceKind) -> Bool {
        opens.contains(kind == .postgresql ? "PostgreSQL" : "MySQL")
    }
}
