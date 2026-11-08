import Foundation

// One file or folder in a backup. A folder ends with /.
public struct BackupEntry: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let date: Date?

    public init(path: String, size: Int64 = 0, date: Date? = nil) {
        self.path = path
        self.size = size
        self.date = date
    }

    public var isFolder: Bool {
        path.hasSuffix("/")
    }
}

// Where the site and the dump are in a backup (3f). The layouts come from the source of Studio and
// All-in-One WP Migration (docs/plan.md, 3f):
// - Local: local-site.json, app/public with the site and app/sql/*.sql. Without local-site.json it
//   is a copy of a Local site folder, and its dump can be older than the site.
// - Studio and Jetpack: wp-content/, sql/ and wp-config.php, without WordPress. Studio adds
//   meta.json. sql/ has one dump or one file for each table.
// - A folder with wp-content and a .sql or .sql.gz dump next to it or one folder above it.
// - .wpress: the entries are the content of wp-content, with database.sql and package.json.
public struct BackupLayout: Sendable, Equatable {
    public let format: BackupFormat
    // The folder of the site in the backup, without a / at the end. Empty is the root.
    public let siteRoot: String
    public let dumps: [String]
    public let hasCore: Bool
    public let hasConfig: Bool
    public let metaFile: String?

    public static let problem = "Nexus found no WordPress in this backup. A backup needs a wp-content folder and a .sql dump."

    public init(format: BackupFormat, siteRoot: String, dumps: [String], hasCore: Bool, hasConfig: Bool, metaFile: String?) {
        self.format = format
        self.siteRoot = siteRoot
        self.dumps = dumps
        self.hasCore = hasCore
        self.hasConfig = hasConfig
        self.metaFile = metaFile
    }

    public static func detect(_ entries: [BackupEntry]) -> BackupLayout? {
        let paths = Set(entries.map { normalized($0.path) })

        func has(_ path: String) -> Bool {
            paths.contains(path) || paths.contains(path + "/") || paths.contains { $0.hasPrefix(path + "/") }
        }

        func dumps(in folder: String) -> [String] {
            let prefix = folder.isEmpty ? "" : folder + "/"
            return ordered(paths.filter { path in
                guard path.hasPrefix(prefix), isDump(path) else {
                    return false
                }

                return !path.dropFirst(prefix.count).contains("/")
            })
        }

        if has("app/public/wp-content") {
            let found = dumps(in: "app/sql")

            if !found.isEmpty {
                return BackupLayout(format: paths.contains("local-site.json") ? .localExport : .localSiteFolder, siteRoot: "app/public", dumps: found, hasCore: has("app/public/wp-load.php"), hasConfig: has("app/public/wp-config.php"), metaFile: paths.contains("local-site.json") ? "local-site.json" : nil)
            }
        }

        for root in roots(holding: "wp-content", in: paths) {
            let prefix = root.isEmpty ? "" : root + "/"
            let tableDumps = dumps(in: prefix + "sql")

            if !tableDumps.isEmpty {
                let meta = paths.contains(prefix + "meta.json") ? prefix + "meta.json" : nil
                return BackupLayout(format: meta == nil ? .jetpack : .studio, siteRoot: root, dumps: tableDumps, hasCore: has(prefix + "wp-load.php"), hasConfig: has(prefix + "wp-config.php"), metaFile: meta)
            }

            let parent = root.split(separator: "/").dropLast().joined(separator: "/")
            let nearby = dumps(in: root) + (root.isEmpty ? [] : dumps(in: parent))

            if let largest = nearby.max(by: { size(of: $0, in: entries) < size(of: $1, in: entries) }) {
                return BackupLayout(format: .folder, siteRoot: root, dumps: [largest], hasCore: has(prefix + "wp-load.php"), hasConfig: has(prefix + "wp-config.php"), metaFile: nil)
            }
        }

        return nil
    }

    // The table file of Jetpack goes before its -updates file. Studio sorts them the other way
    // around, but the docs of Jetpack say that the main file comes first.
    static func ordered(_ dumps: Set<String>) -> [String] {
        dumps.sorted { first, second in
            let a = sortKey(first)
            let b = sortKey(second)
            return a == b ? first < second : a < b
        }
    }

    private static func sortKey(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = name.replacingOccurrences(of: #"(\.sql(\.gz)?)$"#, with: "", options: .regularExpression)
        return base.hasSuffix("-updates") ? String(base.dropLast("-updates".count)) + "\u{1}" : base
    }

    // The table of the options holds the URLs. A backup with one file for each table names it. In a
    // network wp_2_options.sql comes before wp_options.sql, and a plugin table can end in options
    // too. So the shortest name of the main site wins.
    public var optionsDump: String {
        let tables = dumps.compactMap { dump -> (dump: String, prefix: String)? in
            let base = (dump as NSString).lastPathComponent.lowercased().replacingOccurrences(of: #"\.sql(\.gz)?$"#, with: "", options: .regularExpression)
            return base.hasSuffix("options") ? (dump, String(base.dropLast("options".count))) : nil
        }
        let mainSite = tables.filter { !DumpScanner.isNetworkSitePrefix($0.prefix) }

        return (mainSite.isEmpty ? tables : mainSite).min { $0.dump.count < $1.dump.count }?.dump ?? dumps[0]
    }

    public static func isDump(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".sql") || lower.hasSuffix(".sql.gz")
    }

    // The folders that hold the folder name, at the root or one folder below it.
    private static func roots(holding name: String, in paths: Set<String>) -> [String] {
        var roots: Set<String> = []

        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

            if parts.first == name {
                roots.insert("")
            } else if parts.count > 1, parts[1] == name, !parts[0].isEmpty {
                roots.insert(parts[0])
            }
        }

        return roots.sorted { $0.count < $1.count }
    }

    private static func size(of path: String, in entries: [BackupEntry]) -> Int64 {
        entries.first { normalized($0.path) == path }?.size ?? 0
    }

    public static func normalized(_ path: String) -> String {
        var path = path

        while path.hasPrefix("./") {
            path.removeFirst(2)
        }

        return path
    }

    // A name from a backup must stay inside the folder that gets it.
    public static func isSafe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

// The header of each file in a .wpress archive of All-in-One WP Migration: 255 bytes name, 14 bytes
// size, 12 bytes time and 4096 bytes folder. Since 7.104 the last 8 bytes of the folder are a CRC32.
// Each value is ASCII and ends at the first NUL. An end block has an empty name.
public struct WpressHeader: Sendable, Equatable {
    public static let length = 4377

    public let name: String
    public let size: Int64
    public let date: Date?
    public let folder: String

    public var path: String {
        folder.isEmpty || folder == "." ? name : "\(folder)/\(name)"
    }

    public static func parse(_ data: Data) -> WpressHeader? {
        guard data.count >= length else {
            return nil
        }

        let bytes = [UInt8](data.prefix(length))

        func text(_ range: Range<Int>) -> String {
            let slice = bytes[range].prefix { $0 != 0 }
            return String(decoding: slice, as: UTF8.self)
        }

        let name = text(0..<255)

        guard !name.isEmpty, let size = Int64(text(255..<269)) else {
            return nil
        }

        let time = TimeInterval(text(269..<281)).map { Date(timeIntervalSince1970: $0) }
        return WpressHeader(name: name, size: size, date: time, folder: text(281..<4369))
    }
}
