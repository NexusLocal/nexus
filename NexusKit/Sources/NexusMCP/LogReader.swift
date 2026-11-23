import Foundation
import NexusCore
import NexusIPC

public struct LogInfo: Codable, Sendable, Equatable {
    public let name: String
    public let about: String
    public let file: String
    public let bytes: Int64
    public let modified: Date?
}

public struct LogLines: Codable, Sendable, Equatable {
    public let log: String
    public let file: String
    public let lines: [String]
    public let note: String?
}

public enum LogReader {
    public static let defaultLines = 50
    public static let mostLines = 500
    static let lineLength = 1000
    static let resultLength = 36_000

    public static func logs(paths: NexusPaths, sites: [SiteInfo]) -> [LogInfo] {
        var logs: [LogInfo] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)) ?? []

        for file in files.filter({ $0.pathExtension == "log" && !$0.lastPathComponent.hasSuffix(".1.log") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let base = file.deletingPathExtension().lastPathComponent
            let name = base == "activity" ? "nexus" : base
            logs.append(info(name, about: about(base), file: file))
        }

        let siteFiles = (try? FileManager.default.contentsOfDirectory(at: paths.siteLogs, includingPropertiesForKeys: nil)) ?? []

        for file in siteFiles.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let host = file.deletingPathExtension().lastPathComponent
            logs.append(info("access:\(host)", about: "The requests of \(host)", file: file))
        }

        for (host, log) in appLogs(sites) {
            logs.append(info("app:\(host)", about: "The output of the Node.js app of \(host)", file: URL(filePath: log)))
        }

        // The log files of the apps, as on the Logs screen (group 7).
        for place in sites.flatMap(\.logPlaces) {
            for file in AppLogFiles.files(of: place, paths: paths) where file.kind == .app {
                logs.append(info("\(place.id)/\(file.name)", about: "A log of the app of \(place.id), one entry for each line of the result", file: URL(filePath: file.path)))
            }
        }

        return logs
    }

    public static func read(_ name: String, lines count: Int, containing filter: String?, level: LogLevelGroup? = nil, paths: NexusPaths, sites: [SiteInfo]) throws -> LogLines? {
        if let appLog = try appLog(name, lines: count, containing: filter, level: level, paths: paths, sites: sites) {
            return appLog
        }

        guard let log = logs(paths: paths, sites: sites).first(where: { $0.name == name }) else {
            return nil
        }

        // The last 64 KB hold the default 50 lines. A filter or many long lines need more of the file.
        let wantedLines = min(max(count, 1), mostLines)
        let file = URL(filePath: log.file)
        var all = ErrorReader.tail(of: file, bytes: filter == nil ? 64 * 1024 : 2 * 1024 * 1024).split(separator: "\n")

        if filter == nil, all.count < wantedLines, log.bytes > 64 * 1024 {
            all = ErrorReader.tail(of: file, bytes: 2 * 1024 * 1024).split(separator: "\n")
        }

        let matching = filter.map { text in all.filter { $0.localizedCaseInsensitiveContains(text) } } ?? all
        var lines: [String] = []
        var length = 0

        for line in matching.suffix(wantedLines).reversed() {
            let shortened = String(line.prefix(lineLength))

            guard length + shortened.count < resultLength else {
                break
            }

            length += shortened.count
            lines.insert(shortened, at: 0)
        }

        let note = lines.count < min(wantedLines, matching.count) ? "Only the last \(Count.text(lines.count, "line")) fit in one result. Use contains to find a line." : nil
        return LogLines(log: name, file: log.file, lines: lines, note: note)
    }

    // shop.test gives the entries of all log files of the app of shop.test, newest last.
    // shop.test/laravel.log gives one file. The level keeps that level and the more serious ones.
    static func appLog(_ name: String, lines count: Int, containing filter: String?, level: LogLevelGroup?, paths: NexusPaths, sites: [SiteInfo]) throws -> LogLines? {
        let places = sites.flatMap(\.logPlaces)
        let place = places.first { name == $0.id || name.hasPrefix("\($0.id)/") }

        guard let place else {
            return nil
        }

        let file = name == place.id ? nil : String(name.dropFirst(place.id.count + 1))
        let reader = try AppLogReader(place: place, paths: paths, file: file)
        let wanted = min(max(count, 1), mostLines)
        let entries = reader.entries(count: wanted, level: level, containing: filter)
        var lines: [String] = []
        var length = 0

        for entry in entries.reversed() {
            let text = String(entry.text.prefix(lineLength))

            guard length + text.count < resultLength else {
                break
            }

            length += text.count
            lines.insert(text, at: 0)
        }

        let note: String? = if lines.isEmpty {
            "No entries match."
        } else if lines.count < entries.count {
            "Only the newest \(Count.text(lines.count, "entry", plural: "entries")) fit in one result. Use contains or level to find an entry."
        } else {
            nil
        }

        return LogLines(log: name, file: reader.files.map(\.path).joined(separator: ", "), lines: lines, note: note)
    }

    static func appLogs(_ sites: [SiteInfo]) -> [(String, String)] {
        sites.flatMap { site -> [(String, String)] in
            let main = site.app.map { [(site.hosts.first ?? "", $0.log)] } ?? []
            let workspaces = (site.workspaces ?? []).compactMap { workspace in
                workspace.app.map { (workspace.hosts?.first ?? workspace.name, $0.log) }
            }

            return main + workspaces
        }
    }

    private static func about(_ base: String) -> String {
        switch base {
        case "activity": "What Nexus did, with each change that an agent asked for"
        case "errors": "The full output of each program that failed"
        case "nginx": "The errors of nginx"
        case "apache": "The errors of Apache"
        default:
            if base.hasSuffix("-errors"), let line = ServiceID.phpLine(of: String(base.dropLast(7))) {
                "PHP \(line): the PHP errors of all sites with this version, with their time"
            } else if let line = ServiceID.phpLine(of: base) {
                "PHP-FPM \(line): the start and the stop of PHP-FPM, and the PHP errors from before the file php-\(line)-errors"
            } else if base.hasPrefix("new-site-") {
                "The steps of the new site \(base.dropFirst(9))"
            } else {
                "The output of the service \(base)"
            }
        }
    }

    private static func info(_ name: String, about: String, file: URL) -> LogInfo {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LogInfo(name: name, about: about, file: file.path(percentEncoded: false), bytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
    }
}
