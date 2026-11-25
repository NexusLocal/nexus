import Foundation
import NexusCore

// The app that the sites move from. Laravel Valet keeps the same files as Herd in another folder,
// so the types of the move from Herd also serve the move from Valet.
public enum MoveSource: String, Codable, Sendable, CaseIterable {
    case herd
    case valet

    public var name: String {
        switch self {
        case .herd: "Herd"
        case .valet: "Valet"
        }
    }

    // The step that waits until the app gives back ports 80 and 443.
    public var stopStep: String {
        switch self {
        case .herd: "Quit Herd"
        case .valet: "Stop Valet"
        }
    }
}

// The move from Herd or Valet (group 9, docs/group9-herd.md). nexusd reads the files of the app and
// the projects of its sites, and the sheet "Move from Herd" shows the plan. Each item has an id.
// The request names the items that the user turned off and the version lines that the user chose.
public struct HerdMovePlan: Codable, Sendable, Equatable {
    // A package that the move needs and that is not installed. Nexus installs it first.
    public struct Package: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let line: String
        public let reason: String
        public let bytes: Int64?

        public var id: String { "\(name)-\(line)" }

        public init(name: String, line: String, reason: String, bytes: Int64?) {
            self.name = name
            self.line = line
            self.reason = reason
            self.bytes = bytes
        }
    }

    // A parked folder of Herd. Each subfolder is a site.
    public struct ParkedFolder: Codable, Sendable, Equatable, Identifiable {
        public let folder: String
        public let php: String

        public var id: String { "park:\(folder)" }

        public init(folder: String, php: String) {
            self.folder = folder
            self.php = php
        }
    }

    // A site of Herd. herdPHP is the version of Herd. php is the line of Nexus that the move
    // suggests, and phpChoices are the other lines that the user can choose.
    public struct SiteItem: Codable, Sendable, Equatable, Identifiable {
        public let hosts: [String]
        public let folder: String
        public let kind: SiteKind
        public let herdPHP: String?
        public let php: String?
        public let phpChoices: [String]
        public let address: String?
        public let parkedIn: String?
        public let projectType: PHPProjectType
        public let ownLines: [String]

        public var id: String { "site:\(hosts.first ?? folder)" }

        public init(hosts: [String], folder: String, kind: SiteKind, herdPHP: String?, php: String?, phpChoices: [String], address: String? = nil, parkedIn: String? = nil, projectType: PHPProjectType = .other, ownLines: [String] = []) {
            self.hosts = hosts
            self.folder = folder
            self.kind = kind
            self.herdPHP = herdPHP
            self.php = php
            self.phpChoices = phpChoices
            self.address = address
            self.parkedIn = parkedIn
            self.projectType = projectType
            self.ownLines = ownLines
        }
    }

    // A database on a server on this Mac that the .env or wp-config.php of a site names. kind is
    // the package of Nexus that receives it: mysql, mariadb, postgresql or mongodb.
    public struct DatabaseItem: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let kind: String
        public let version: String?
        public let port: Int?
        public let socket: String?
        public let account: DatabaseAccount
        public let line: String?
        public let lineChoices: [String]
        public let bytes: Int64?
        public let sites: [String]

        public var id: String { "database:\(kind):\(port.map(String.init) ?? socket ?? ""):\(name)" }

        public init(name: String, kind: String, version: String?, port: Int?, socket: String? = nil, account: DatabaseAccount, line: String?, lineChoices: [String], bytes: Int64? = nil, sites: [String]) {
            self.name = name
            self.kind = kind
            self.version = version
            self.port = port
            self.socket = socket
            self.account = account
            self.line = line
            self.lineChoices = lineChoices
            self.bytes = bytes
            self.sites = sites
        }
    }

    // A Redis or Valkey server that a site uses. Its keys go to the Redis of Nexus.
    public struct RedisItem: Codable, Sendable, Equatable, Identifiable {
        public let port: Int
        public let password: String?
        public let valkey: Bool
        public let version: String?
        public let keys: Int?
        public let line: String
        public let sites: [String]

        public var id: String { "redis:\(port)" }

        public init(port: Int, password: String?, valkey: Bool, version: String?, keys: Int?, line: String, sites: [String]) {
            self.port = port
            self.password = password
            self.valkey = valkey
            self.version = version
            self.keys = keys
            self.line = line
            self.sites = sites
        }
    }

    // The lines of the user in the php.ini of one version of Herd. line is the line of Nexus.
    public struct IniItem: Codable, Sendable, Equatable, Identifiable {
        public let herdPHP: String
        public let line: String
        public let lines: [String]

        public var id: String { "ini:\(herdPHP)" }

        public init(herdPHP: String, line: String, lines: [String]) {
            self.herdPHP = herdPHP
            self.line = line
            self.lines = lines
        }
    }

    // The .env of a Laravel site. "Use Nexus" changes it after the move.
    public struct EnvItem: Codable, Sendable, Equatable, Identifiable {
        public let host: String
        public let file: String

        public var id: String { "env:\(host)" }

        public init(host: String, file: String) {
            self.host = host
            self.file = file
        }
    }

    public enum FileKind: String, Codable, Sendable {
        case shell
        case project
    }

    // A file that names Herd: the shell file with the lines of Herd, or a file of a project with
    // a path to the PHP of Herd. lines are the lines that change.
    public struct FileItem: Codable, Sendable, Equatable, Identifiable {
        public let path: String
        public let kind: FileKind
        public let lines: [String]

        public var id: String { "file:\(path)" }

        public init(path: String, kind: FileKind, lines: [String]) {
            self.path = path
            self.kind = kind
            self.lines = lines
        }
    }

    // The own nginx lines of the sites have one switch in the sheet. Its id in the skipped items
    // keeps the lines of each site out of the move.
    public static let ownLinesID = "nginx-lines"

    public var source: MoveSource
    // Herd runs, or the nginx of Valet runs.
    public var herdRuns: Bool
    public var tld: String
    public var packages: [Package]
    public var parked: [ParkedFolder]
    public var sites: [SiteItem]
    public var databases: [DatabaseItem]
    public var redis: [RedisItem]
    public var ini: [IniItem]
    public var envFiles: [EnvItem]
    public var files: [FileItem]
    // What Nexus cannot move, in plain words. The sheet shows each one.
    public var notes: [String]
    // The first host of each site of Herd that Nexus has already. The plan leaves these sites out.
    public var inNexus: [String]

    public init(source: MoveSource = .herd, herdRuns: Bool, tld: String, packages: [Package] = [], parked: [ParkedFolder] = [], sites: [SiteItem] = [], databases: [DatabaseItem] = [], redis: [RedisItem] = [], ini: [IniItem] = [], envFiles: [EnvItem] = [], files: [FileItem] = [], notes: [String] = [], inNexus: [String] = []) {
        self.source = source
        self.herdRuns = herdRuns
        self.tld = tld
        self.packages = packages
        self.parked = parked
        self.sites = sites
        self.databases = databases
        self.redis = redis
        self.ini = ini
        self.envFiles = envFiles
        self.files = files
        self.notes = notes
        self.inNexus = inNexus
    }

    public var isEmpty: Bool {
        sites.isEmpty && parked.isEmpty && databases.isEmpty
    }
}

// What the user confirmed. skipped holds the ids of the items that are off. php and databaseLines
// hold the lines that the user chose in a popup, by the id of the item.
public struct HerdMoveRequest: Codable, Sendable, Equatable {
    public var skipped: [String]
    public var php: [String: String]
    public var databaseLines: [String: String]

    public init(skipped: [String] = [], php: [String: String] = [:], databaseLines: [String: String] = [:]) {
        self.skipped = skipped
        self.php = php
        self.databaseLines = databaseLines
    }
}

public enum HerdMoveText {
    public static let stopSteps = Set(MoveSource.allCases.map(\.stopStep))

    // The reason of a plan without sites, for the sheet and for nexus import herd.
    public static func nothingToMove(_ plan: HerdMovePlan?) -> String {
        guard let plan else {
            return "Nexus found no sites of Herd or Valet on this Mac."
        }

        guard !plan.inNexus.isEmpty else {
            return "Nexus found no sites of \(plan.source.name) on this Mac."
        }

        return "Each site of \(plan.source.name) is in Nexus already."
    }

    // What nexus import herd says before it waits. The app shows the same in its banner.
    public static func stopInstruction(_ source: MoveSource) -> String {
        switch source {
        case .herd:
            "Nexus copies while Herd runs. Then quit Herd: click the Herd icon in the menu bar and choose Quit. Also turn off Herd in System Settings > General > Login Items. The move goes on when Herd stops."
        case .valet:
            "Nexus copies while Valet runs. Then run valet stop in another Terminal window. Valet asks for your password. The move goes on when Valet stops."
        }
    }

    public static func packageTitle(_ name: String, _ line: String) -> String {
        let names = ["php": "PHP", "mysql": "MySQL", "mariadb": "MariaDB", "postgresql": "PostgreSQL", "mongodb": "MongoDB", "redis": "Redis"]
        return "\(names[name] ?? name) \(line)"
    }

    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    // The whole plan as text, for nexus import herd and for "Show Details…" in the sheet.
    public static func summary(_ plan: HerdMovePlan, home: String = NSHomeDirectory()) -> [String] {
        var lines: [String] = []

        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else {
                return
            }

            lines += (lines.isEmpty ? [] : [""]) + [title] + items.map { "  \($0)" }
        }

        section("Nexus installs first:", plan.packages.map { "\(packageTitle($0.name, $0.line)) \($0.reason)" })
        section("Sites:", plan.sites.map { site in
            let php = site.php.map { line in site.herdPHP.map { $0 == line ? "PHP \(line)" : "PHP \($0) → \(line)" } ?? "PHP \(line)" }
            let place = site.kind == .proxy ? "proxy to \(site.address ?? "")" : shortPath(site.folder, home: home)
            return ([site.hosts.joined(separator: ", "), place] + (site.kind == .proxy ? [] : [php].compactMap { $0 })).joined(separator: " · ")
        })
        section("Databases:", plan.databases.map { database in
            let source = [packageTitle(database.kind, database.version ?? "").trimmingCharacters(in: .whitespaces), database.port.map { "port \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return "\(database.name) · \(source) → \(database.line.map { packageTitle(database.kind, $0) } ?? "no server of Nexus")"
        })
        section("Redis:", plan.redis.map { "\($0.keys.map { "\($0) keys" } ?? "The keys") of \($0.valkey ? "Valkey" : "Redis") on port \($0.port) → Redis \($0.line)" })

        for item in plan.ini {
            section("php.ini lines of PHP \(item.herdPHP)\(item.herdPHP == item.line ? "" : " for PHP \(item.line)"):", item.lines)
        }

        for site in plan.sites where !site.ownLines.isEmpty {
            section("nginx lines of \(site.hosts[0]):", site.ownLines)
        }

        section(".env files that change:", plan.envFiles.map { shortPath($0.file, home: home) })

        for file in plan.files {
            section("\(shortPath(file.path, home: home)) \(file.kind == .shell ? "loses these lines of \(plan.source.name)" : "gets the PHP of Nexus"):", file.lines)
        }

        section("Notes:", plan.notes)
        return lines
    }
}
