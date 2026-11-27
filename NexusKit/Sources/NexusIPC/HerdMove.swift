import Foundation
import NexusCore

// The app that the sites move from. Laravel Valet keeps the same files as Herd in another folder,
// so the types of the move from Herd also serve the move from Valet. Local by WP Engine (group 11,
// docs/group11-local.md) has only WordPress sites, each with its own database server.
public enum MoveSource: String, Codable, Sendable, CaseIterable {
    case herd
    case valet
    case local

    public var name: String {
        switch self {
        case .herd: "Herd"
        case .valet: "Valet"
        case .local: "Local"
        }
    }

    // The step that waits until the app gives back ports 80 and 443.
    public var stopStep: String {
        switch self {
        case .herd: "Quit Herd"
        case .valet: "Stop Valet"
        case .local: "Quit Local"
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
        // Local: the web server of the site, and the kind of a WordPress network.
        public var server: WebServer?
        public var network: WordPressNetworkKind?

        public var id: String { "site:\(hosts.first ?? folder)" }

        public init(hosts: [String], folder: String, kind: SiteKind, herdPHP: String?, php: String?, phpChoices: [String], address: String? = nil, parkedIn: String? = nil, projectType: PHPProjectType = .other, ownLines: [String] = [], server: WebServer? = nil, network: WordPressNetworkKind? = nil) {
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
            self.server = server
            self.network = network
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
        // Local: each site has a database local on its own server. target is its name in Nexus.
        // A stopped server has no socket. Then Nexus reads a copy of dataFolder with its own
        // server of readerLine. dump is local.sql of the last stop, the last fallback.
        public var target: String?
        public var runs: Bool?
        public var dataFolder: String?
        public var readerLine: String?
        public var dump: String?
        public var dumpDate: Date?

        public var id: String { "database:\(kind):\(port.map(String.init) ?? socket ?? ""):\(name)" }

        public var targetName: String {
            target ?? name
        }

        public init(name: String, kind: String, version: String?, port: Int?, socket: String? = nil, account: DatabaseAccount, line: String?, lineChoices: [String], bytes: Int64? = nil, sites: [String], target: String? = nil, runs: Bool? = nil, dataFolder: String? = nil, readerLine: String? = nil, dump: String? = nil, dumpDate: Date? = nil) {
            self.runs = runs
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
            self.target = target
            self.dataFolder = dataFolder
            self.readerLine = readerLine
            self.dump = dump
            self.dumpDate = dumpDate
        }

        public func choosing(_ line: String) -> DatabaseItem {
            DatabaseItem(name: name, kind: kind, version: version, port: port, socket: socket, account: account, line: line, lineChoices: lineChoices, bytes: bytes, sites: sites, target: target, runs: runs, dataFolder: dataFolder, readerLine: readerLine, dump: dump, dumpDate: dumpDate)
        }

        // Local: how Nexus reads the database.
        public var way: String? {
            guard target != nil else {
                return nil
            }

            if runs == true {
                return "runs in Local"
            }

            return dataFolder != nil ? "from a copy of the data folder" : dump != nil ? "from local.sql" : "no data found"
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
        // The .envrc of a Local site for direnv. It moves into the report folder.
        case envrc
    }

    // The dev TLD of Nexus decides the name of each new site. The Local sites keep their .local
    // names in each case. nexusSites is the number of sites that a change would rename.
    public struct DevTLDItem: Codable, Sendable, Equatable {
        public let tld: String
        public let nexusSites: Int

        public var isOnByDefault: Bool {
            nexusSites == 0
        }

        public init(tld: String, nexusSites: Int) {
            self.tld = tld
            self.nexusSites = nexusSites
        }
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
    // Local: one switch for the change of the URLs to https:// in each database.
    public static let httpsID = "https-urls"

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
    // Local: the wp-config.php of each site, the sites whose URLs change to https://, the switch
    // for the dev TLD .local, and the Local certificates that macOS trusts.
    public var wpConfigs: [EnvItem] = []
    public var httpsSites: [String] = []
    public var devTLD: DevTLDItem?
    public var certificates: [String] = []

    public init(source: MoveSource = .herd, herdRuns: Bool, tld: String, packages: [Package] = [], parked: [ParkedFolder] = [], sites: [SiteItem] = [], databases: [DatabaseItem] = [], redis: [RedisItem] = [], ini: [IniItem] = [], envFiles: [EnvItem] = [], files: [FileItem] = [], notes: [String] = [], inNexus: [String] = [], wpConfigs: [EnvItem] = [], httpsSites: [String] = [], devTLD: DevTLDItem? = nil, certificates: [String] = []) {
        self.wpConfigs = wpConfigs
        self.httpsSites = httpsSites
        self.devTLD = devTLD
        self.certificates = certificates
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
    // Local: the switch "New sites get .local". Nil keeps the default of the plan.
    public var useDevTLD: Bool?

    public init(skipped: [String] = [], php: [String: String] = [:], databaseLines: [String: String] = [:], useDevTLD: Bool? = nil) {
        self.skipped = skipped
        self.php = php
        self.databaseLines = databaseLines
        self.useDevTLD = useDevTLD
    }
}

public enum HerdMoveText {
    public static let stopSteps = Set(MoveSource.allCases.map(\.stopStep))

    // The reason of a plan without sites, for the sheet and for nexus import herd.
    public static func nothingToMove(_ plan: HerdMovePlan?) -> String {
        guard let plan else {
            return "Nexus found no sites of Herd, Valet or Local on this Mac."
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
        case .local:
            "Nexus copies while Local runs. Then quit Local: choose Local > Quit Local. When sites run, Local asks if you are sure. Click Yes. The move goes on when Local quits."
        }
    }

    public static func packageTitle(_ name: String, _ line: String) -> String {
        let names = ["php": "PHP", "mysql": "MySQL", "mariadb": "MariaDB", "postgresql": "PostgreSQL", "mongodb": "MongoDB", "redis": "Redis", "httpd": "Apache", "wp-cli": "WP-CLI"]
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
            let extra = [site.server == .apache ? "Apache" : nil, site.network.map { "network on \($0.rawValue)" }].compactMap { $0 }
            return ([site.hosts.joined(separator: ", "), place] + (site.kind == .proxy ? [] : [php].compactMap { $0 }) + extra).joined(separator: " · ")
        })
        section("Databases:", plan.databases.map { database in
            let source = [packageTitle(database.kind, database.version ?? "").trimmingCharacters(in: .whitespaces), database.port.map { "port \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let target = database.line.map { packageTitle(database.kind, $0) } ?? "no server of Nexus"
            let label = database.target.map { "\(database.sites.first ?? database.name): \(database.name) as \($0)" } ?? database.name
            return "\(label) · \(source) → \(target)\(database.way.map { " · \($0)" } ?? "")"
        })
        section("Redis:", plan.redis.map { "\($0.keys.map { "\($0) keys" } ?? "The keys") of \($0.valkey ? "Valkey" : "Redis") on port \($0.port) → Redis \($0.line)" })

        for item in plan.ini {
            section("php.ini lines of PHP \(item.herdPHP)\(item.herdPHP == item.line ? "" : " for PHP \(item.line)"):", item.lines)
        }

        for site in plan.sites where !site.ownLines.isEmpty {
            section("nginx lines of \(site.hosts[0]):", site.ownLines)
        }

        section(".env files that change:", plan.envFiles.map { shortPath($0.file, home: home) })
        section("wp-config.php files that get the database of Nexus:", plan.wpConfigs.map { shortPath($0.file, home: home) })
        section("Sites whose URLs change to https://:", plan.httpsSites)

        if let devTLD = plan.devTLD {
            section("The dev TLD of Nexus:", ["New sites get .\(devTLD.tld)" + (devTLD.nexusSites == 0 ? "" : ". This also renames the \(devTLD.nexusSites) sites of Nexus.")])
        }

        for file in plan.files where file.kind != .envrc {
            section("\(shortPath(file.path, home: home)) \(file.kind == .shell ? "loses these lines of \(plan.source.name)" : "gets the PHP of Nexus"):", file.lines)
        }

        section(".envrc files that move into the report folder:", plan.files.filter { $0.kind == .envrc }.map { shortPath($0.path, home: home) })
        section("Local certificates that macOS trusts:", plan.certificates.map { shortPath($0, home: home) })
        section("Notes:", plan.notes)
        return lines
    }
}
