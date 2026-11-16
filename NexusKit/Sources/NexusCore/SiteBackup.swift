import Foundation

// A backup of a WordPress site that Nexus imports as a new site (Phase 4, 3f).
public enum BackupFormat: String, Codable, Sendable {
    case localExport = "local_export"
    case localSiteFolder = "local_site_folder"
    case jetpack
    case studio
    case wpress
    case folder

    public var displayName: String {
        switch self {
        case .localExport: "Export of Local"
        case .localSiteFolder: "Local site folder"
        case .jetpack: "Jetpack backup"
        case .studio: "Export of Studio"
        case .wpress: "All-in-One WP Migration"
        case .folder: "Folder with a dump"
        }
    }
}

// The compression of a .wpress file. An extension of All-in-One WP Migration adds it.
public enum BackupCompression: String, Codable, Sendable {
    case gzip
    case bzip2
}

// What nexusd found in a backup before the import. problem says why Nexus cannot import it.
// dump is the path of the dump in the backup, or of the folder with one dump for each table.
public struct BackupInfo: Codable, Sendable, Equatable {
    public let path: String
    public let format: BackupFormat?
    public let wordPressVersion: String?
    // Without the files of WordPress, Nexus downloads them, in wordPressVersion when it is known.
    public let hasCore: Bool
    public let dump: String?
    public let dumpBytes: Int64?
    public let dumpDate: Date?
    public let tablePrefix: String?
    public let siteURL: String?
    // The EncryptedSignature of package.json of a .wpress file with a password. The app and nexus
    // import check a password with it. It is in plain text in the backup, so it is not a secret.
    public let passwordSignature: String?
    public let compression: BackupCompression?
    public let suggestedName: String
    public let problem: String?

    public init(path: String, format: BackupFormat?, wordPressVersion: String? = nil, hasCore: Bool = false, dump: String? = nil, dumpBytes: Int64? = nil, dumpDate: Date? = nil, tablePrefix: String? = nil, siteURL: String? = nil, passwordSignature: String? = nil, compression: BackupCompression? = nil, suggestedName: String, problem: String? = nil) {
        self.path = path
        self.format = format
        self.wordPressVersion = wordPressVersion
        self.hasCore = hasCore
        self.dump = dump
        self.dumpBytes = dumpBytes
        self.dumpDate = dumpDate
        self.tablePrefix = tablePrefix
        self.siteURL = siteURL
        self.passwordSignature = passwordSignature
        self.compression = compression
        self.suggestedName = suggestedName
        self.problem = problem
    }
}

public struct SiteImport: Codable, Sendable, Equatable {
    public var backup: String
    public var name: String
    public var parent: String
    public var database: String?
    public var git: Bool
    // The password of a .wpress file. Only the request has it. nexusd never writes it.
    public var password: String?

    public init(backup: String, name: String, parent: String, database: String? = nil, git: Bool = true, password: String? = nil) {
        self.backup = backup
        self.name = name
        self.parent = parent
        self.database = database
        self.git = git
        self.password = password
    }
}

// Reads the table prefix and the URLs of a site from the text of a dump, part by part, so a large
// dump does not go into memory. A part can end in the middle of a statement. So the scanner keeps
// the end of the part before.
public struct DumpScanner: Sendable {
    public private(set) var home: String?
    public private(set) var siteURL: String?

    private var mainPrefix: String?
    private var networkSitePrefix: String?
    private var carry = ""

    public init() {}

    // In the dump of a network, wp_2_options comes before wp_options. A prefix such as wp_2_ is the
    // prefix of the site only when the dump has no other options table.
    public var prefix: String? {
        mainPrefix ?? networkSitePrefix
    }

    public var isComplete: Bool {
        mainPrefix != nil && home != nil && siteURL != nil
    }

    // The address of the site. WordPress keeps it in home, and siteurl is the folder of WordPress.
    public var url: String? {
        home ?? siteURL
    }

    public static func isNetworkSitePrefix(_ prefix: String) -> Bool {
        prefix.wholeMatch(of: /.*_[0-9]+_/) != nil
    }

    // The URLs count only in the rows of the options table. A post or a meta row can hold the
    // text 'home' too.
    public mutating func scan(_ text: String) {
        var window = carry + text

        if mainPrefix == nil {
            for match in window.matches(of: Self.optionsTable) {
                let found = String(match.output.1)

                guard Self.isNetworkSitePrefix(found) else {
                    mainPrefix = found
                    break
                }

                networkSitePrefix = networkSitePrefix ?? found
            }
        }

        // The text before the rows of the options table does not go to the next part.
        if !inOptions, let prefix = mainPrefix, let start = ["INSERT INTO `\(prefix)options`", "INSERT INTO \(prefix)options "].firstNonNil({ window.range(of: $0) }) {
            inOptions = true
            window = String(window[start.lowerBound...])
        }

        carry = String(window.suffix(4096))

        guard inOptions else {
            return
        }

        if home == nil, let match = window.firstMatch(of: Self.homeOption) {
            home = Self.unescaped(String(match.output.1))
        }

        if siteURL == nil, let match = window.firstMatch(of: Self.siteURLOption) {
            siteURL = Self.unescaped(String(match.output.1))
        }
    }

    private var inOptions = false

    // A dump of mysqldump escapes a quote and a backslash with a backslash.
    static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }

    nonisolated(unsafe) private static let optionsTable = /CREATE TABLE (?:IF NOT EXISTS )?`?([A-Za-z0-9_]*)options`?\s*\(/
    nonisolated(unsafe) private static let homeOption = /'home'\s*,\s*'((?:[^'\\]|\\.)*)'/
    nonisolated(unsafe) private static let siteURLOption = /'siteurl'\s*,\s*'((?:[^'\\]|\\.)*)'/
}

// The texts of what nexusd found in a backup, for the sheet and for nexus import.
public enum BackupText {
    public static func wordPress(_ info: BackupInfo) -> String {
        if info.hasCore {
            return info.wordPressVersion ?? "In the backup"
        }

        return info.wordPressVersion.map { "Not in the backup. Nexus downloads \($0)." } ?? "Not in the backup. Nexus downloads the newest version."
    }

    public static func format(_ info: BackupInfo) -> String {
        guard let format = info.format else {
            return "Unknown"
        }

        let details = [
            info.passwordSignature.map { _ in "with a password" },
            info.compression.map { "compressed with \($0.rawValue)" },
        ].compactMap { $0 }

        return details.isEmpty ? format.displayName : "\(format.displayName), \(details.joined(separator: " and "))"
    }

    public static let wrongPassword = "This is not the password of the backup."
    public static let needsPassword = "This backup has a password. Type the password of the backup."
}

// The name of a new site from the name of a backup file, for example foo for
// foo-2026-11-07.zip. A name that does not fit gives site.
public enum BackupName {
    public static func suggested(for path: String) -> String {
        var name = URL(filePath: path).lastPathComponent.lowercased()

        for suffix in [".sql.gz", ".tar.gz", ".wpress", ".zip", ".sql", ".tar"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }

        let words = name.split(whereSeparator: { !$0.isASCII || !($0.isLetter || $0.isNumber) })
        let kept = words.prefix { word in !word.allSatisfy(\.isNumber) && !["backup", "export", "local", "jetpack", "studio"].contains(String(word)) }
        let joined = kept.joined(separator: "-")

        guard !joined.isEmpty, (try? NewSiteName.validated(String(joined.prefix(50)))) != nil else {
            return "site"
        }

        return String(joined.prefix(50))
    }
}
