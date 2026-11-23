import Foundation

// A site or a workspace on the Logs screen (group 7). The app, nexusd and the nexus command make it
// from their own list of sites.
public struct LogPlace: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case laravel
        case wordpress
        case php
        case node
        case proxy
    }

    // The first host of the site or of the workspace.
    public let id: String
    public let siteHost: String
    public let workspace: String?
    public let kind: Kind
    // The document root of the site. WordPress has wp-content there.
    public let folder: String
    public let projectFolder: String
    public let php: String?
    public let hosts: [String]
    // The worktrees of the workspaces of a site. Their PHP errors belong to the workspace.
    public let otherFolders: [String]
    public let appLog: String?

    public init(id: String, siteHost: String, workspace: String?, kind: Kind, folder: String, projectFolder: String, php: String?, hosts: [String], otherFolders: [String], appLog: String?) {
        self.id = id
        self.siteHost = siteHost
        self.workspace = workspace
        self.kind = kind
        self.folder = folder
        self.projectFolder = projectFolder
        self.php = php
        self.hosts = hosts
        self.otherFolders = otherFolders
        self.appLog = appLog
    }

    public var label: String {
        workspace == nil ? id : "\(id) (workspace of \(siteHost))"
    }
}

// One log of a place. A Laravel log can have entries of other formats too, so the parser looks at
// each line. "PHP errors" are the lines of the PHP-FPM log with a folder of the place.
public struct LogFile: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case app
        case phpErrors
        case requests
        case output
    }

    public let id: String
    public let name: String
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    public let modified: Date?
    // Only for phpErrors: an entry belongs to the place when it has one of these folders and none
    // of the excluded folders.
    public let folders: [String]
    public let excludedFolders: [String]

    public init(name: String, path: String, kind: Kind, bytes: Int64, modified: Date?, folders: [String] = [], excludedFolders: [String] = []) {
        self.id = kind == .phpErrors ? "php:\(path)" : path
        self.name = name
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.modified = modified
        self.folders = folders
        self.excludedFolders = excludedFolders
    }

    public var canClear: Bool {
        kind == .app || kind == .output
    }
}

public enum AppLogFiles {
    public static func files(of place: LogPlace, paths: NexusPaths) -> [LogFile] {
        var files: [LogFile] = []
        let project = URL(filePath: place.projectFolder, directoryHint: .isDirectory)

        switch place.kind {
        case .laravel:
            files += laravelLogs(in: project.appending(path: "storage/logs", directoryHint: .isDirectory))
        case .wordpress:
            files += wordPressLogs(folder: URL(filePath: place.folder, directoryHint: .isDirectory), project: project)
        case .php, .node, .proxy:
            break
        }

        if let php = place.php, place.kind != .node, place.kind != .proxy {
            let log = paths.log(ServiceID.php(line: php))

            if let info = info(of: log) {
                let own = LogFolders.prefixes(of: place.projectFolder)
                let others = place.otherFolders.flatMap(LogFolders.prefixes)
                files.append(LogFile(name: "PHP errors", path: log.path(percentEncoded: false), kind: .phpErrors, bytes: info.bytes, modified: info.modified, folders: own, excludedFolders: others))
            }
        }

        if let appLog = place.appLog, let info = info(of: URL(filePath: appLog)) {
            files.append(LogFile(name: "App output", path: appLog, kind: .output, bytes: info.bytes, modified: info.modified))
        }

        for host in place.hosts {
            let log = paths.siteLog(host)

            if let info = info(of: log) {
                let name = place.hosts.count > 1 ? "Requests (\(host))" : "Requests"
                files.append(LogFile(name: name, path: log.path(percentEncoded: false), kind: .requests, bytes: info.bytes, modified: info.modified))
            }
        }

        return files
    }

    // laravel.log first, then the other files by their last change. A subfolder such as cronjobs/
    // counts too, one level deep.
    static func laravelLogs(in folder: URL) -> [LogFile] {
        var found: [(name: String, url: URL)] = []
        let manager = FileManager.default

        for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isFolder {
                for file in (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "log" {
                    found.append(("\(item.lastPathComponent)/\(file.lastPathComponent)", file))
                }
            } else if item.pathExtension == "log" {
                found.append((item.lastPathComponent, item))
            }
        }

        let files = found.compactMap { name, url -> LogFile? in
            info(of: url).map { LogFile(name: name, path: url.path(percentEncoded: false), kind: .app, bytes: $0.bytes, modified: $0.modified) }
        }

        return files.sorted { left, right in
            if (left.name == "laravel.log") != (right.name == "laravel.log") {
                return left.name == "laravel.log"
            }

            if left.name.contains("/") != right.name.contains("/") {
                return !left.name.contains("/")
            }

            return (left.modified ?? .distantPast) > (right.modified ?? .distantPast)
        }
    }

    static func wordPressLogs(folder: URL, project: URL) -> [LogFile] {
        var candidates: [URL] = []

        if let config = WordPressFiles.configFile(core: folder), let text = try? String(contentsOf: config, encoding: .utf8), let path = debugLogPath(in: text, configFolder: config.deletingLastPathComponent()) {
            candidates.append(path)
        }

        candidates += [folder.appending(path: "wp-content/debug.log"), project.appending(path: "wp-content/debug.log"), project.appending(path: "web/app/debug.log")]
        var seen: Set<String> = []

        return candidates.compactMap { url -> LogFile? in
            let path = url.standardizedFileURL.path(percentEncoded: false)

            guard seen.insert(path).inserted, let info = info(of: url) else {
                return nil
            }

            return LogFile(name: url.lastPathComponent, path: path, kind: .app, bytes: info.bytes, modified: info.modified)
        }
    }

    // define( 'WP_DEBUG_LOG', '/path/debug.log' ) or a path with __DIR__ or dirname( __FILE__ ) in
    // front (WordPress 5.1 and later). true gives the default file, which the caller adds anyway.
    public static func debugLogPath(in config: String, configFolder: URL) -> URL? {
        let define = #/define\(\s*['"]WP_DEBUG_LOG['"]\s*,\s*(.+?)\s*\)\s*;/#

        guard let match = config.firstMatch(of: define) else {
            return nil
        }

        let value = String(match.output.1)
        let quoted = #/^(?:(__DIR__|dirname\(\s*__FILE__\s*\))\s*\.\s*)?['"]([^'"]+)['"]$/#

        guard let path = value.firstMatch(of: quoted) else {
            return nil
        }

        let text = String(path.output.2)

        if path.output.1 != nil {
            return configFolder.appending(path: text.hasPrefix("/") ? String(text.dropFirst()) : text).standardizedFileURL
        }

        return text.hasPrefix("/") ? URL(filePath: text) : nil
    }

    private static func info(of file: URL) -> (bytes: Int64, modified: Date?)? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else {
            return nil
        }

        return (Int64(values.fileSize ?? 0), values.contentModificationDate)
    }
}

public enum LogFolders {
    // A folder in each form that a log can use: with /private in front, without it, and as its
    // real path. Each form ends with a slash. So /w/shop does not match /w/shop-admin. The longest
    // form comes first. So a replacement does not leave /private behind.
    public static func prefixes(of folder: String) -> [String] {
        let other = folder.hasPrefix("/private/") ? String(folder.dropFirst(8)) : "/private\(folder)"

        return Set([folder, other, RealPath.of(URL(filePath: folder, directoryHint: .isDirectory))])
            .map { $0.hasSuffix("/") ? $0 : "\($0)/" }
            .sorted { $0.count > $1.count }
    }
}

// The time zone of the times in a Laravel log: APP_TIMEZONE of .env, else the value in
// config/app.php, else UTC as in Laravel.
public enum LaravelTimeZone {
    public static func of(project: URL) -> TimeZone {
        let utc = TimeZone(identifier: "UTC")!

        if let name = EnvFile.values(of: project.appending(path: ".env"))["APP_TIMEZONE"], let zone = TimeZone(identifier: name) {
            return zone
        }

        guard let config = try? String(contentsOf: project.appending(path: "config/app.php"), encoding: .utf8) else {
            return utc
        }

        let setting = #/'timezone'\s*=>\s*(?:env\(\s*'APP_TIMEZONE'\s*,\s*)?'([^']+)'/#

        return config.firstMatch(of: setting).flatMap { TimeZone(identifier: String($0.output.1)) } ?? utc
    }
}
