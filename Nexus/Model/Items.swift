import Foundation

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

struct DatabaseAccount {
    var user: String
    var password: String
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

struct SiteItem: Identifiable, Hashable {
    let host: String
    var aliases: [String] = []
    var group: String?
    let folder: String
    let documentRoot: String
    var server = "nginx"
    var php = "8.4"
    var health: Health = .running

    var id: String { host }

    var url: String {
        "https://\(host):8443"
    }
}

struct SiteGroup: Identifiable {
    let name: String
    var sites: [SiteItem]

    var id: String { "group:\(name)" }
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

struct PackageItem: Identifiable {
    let section: String
    let name: String
    let version: String
    var state: PackageState
    var lts = false
    var securityEnd: String?
    var securityEnded = false
    var required = false

    var id: String { name }

    var isInstalled: Bool {
        switch state {
        case .installed, .update: true
        case .available, .downloading: false
        }
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let title: String
    let shortTitle: String
    var progress: Double
}

struct CommandItem: Identifiable {
    let command: String
    let help: String

    var id: String { command }
}

struct CommandSection: Identifiable {
    let title: String
    let commands: [CommandItem]

    var id: String { title }
}

struct AppChoice: Identifiable, Hashable {
    let name: String
    var opens: String = ""

    var id: String { name }

    // MariaDB uses the mysql:// link. So an app that opens MySQL also opens MariaDB.
    func canOpen(_ kind: ServiceKind) -> Bool {
        opens.contains(kind == .postgresql ? "PostgreSQL" : "MySQL")
    }
}
