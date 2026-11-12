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

        return logs
    }

    public static func read(_ name: String, lines count: Int, containing filter: String?, paths: NexusPaths, sites: [SiteInfo]) -> LogLines? {
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
            if base.hasPrefix("php-") {
                "PHP-FPM \(base.dropFirst(4)): the PHP errors of all sites with this version"
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
