import Foundation
import NexusCore

public struct SiteError: Codable, Sendable, Equatable {
    public let source: String
    public let time: String?
    public let level: String?
    public let message: String
    public let trace: [String]?
    public let file: String

    let date: Date?

    private enum CodingKeys: String, CodingKey {
        case source, time, level, message, trace, file
    }

    init(source: String, time: String?, level: String? = nil, message: String, trace: [String]? = nil, file: URL, date: Date?) {
        self.source = source
        self.time = time
        self.level = level
        self.message = message
        self.trace = trace
        self.file = file.path(percentEncoded: false)
        self.date = date
    }

    // The agent fixes the code of the project. So a frame in vendor/ seldom helps it. Short paths
    // and fewer frames also keep the result small.
    func relative(to project: String) -> SiteError {
        let prefixes = ErrorReader.folderPrefixes(of: project)

        func shortened(_ text: String) -> String {
            prefixes.reduce(text) { $0.replacing($1, with: "") }
        }

        let frames = trace.map { frames in
            let kept = frames.enumerated()
                .filter { $0.offset == 0 || !$0.element.contains("/vendor/") }
                .prefix(ErrorReader.frames)
                .map { String(shortened($0.element).prefix(ErrorReader.frameLength)) }
            let left = frames.count - kept.count
            return left > 0 ? kept + ["\(left) more frames left out, most of them in vendor/"] : kept
        }

        return SiteError(source: source, time: time, level: level, message: shortened(message), trace: frames, file: URL(filePath: file), date: date)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        message = try container.decode(String.self, forKey: .message)
        trace = try container.decodeIfPresent([String].self, forKey: .trace)
        file = try container.decode(String.self, forKey: .file)
        date = nil
    }
}

// Each reader reads only the end of a log, because a log can be large. A message and a frame stop
// at a length that keeps the result below the warning size of Claude Code.
public enum ErrorReader {
    public static let tailBytes = 512 * 1024
    static let messageLength = 1500
    static let frameLength = 300
    static let frames = 12

    public struct Sources: Sendable {
        public let laravelLogs: URL?
        public let wordPressLog: URL?
        public let phpLog: URL?
        public let siteFolder: String
        // The worktrees of the workspaces in the project folder, such as .claude/worktrees/fix.
        // Their PHP errors belong to the workspace and not to the site.
        public let otherFolders: [String]
        public let accessLogs: [URL]
        public let appLog: URL?
        public let timeZone: TimeZone

        public init(laravelLogs: URL?, wordPressLog: URL?, phpLog: URL?, siteFolder: String, otherFolders: [String] = [], accessLogs: [URL], appLog: URL?, timeZone: TimeZone) {
            self.laravelLogs = laravelLogs
            self.wordPressLog = wordPressLog
            self.phpLog = phpLog
            self.siteFolder = siteFolder
            self.otherFolders = otherFolders
            self.accessLogs = accessLogs
            self.appLog = appLog
            self.timeZone = timeZone
        }
    }

    // A folder in each form that a log can use: with /private in front, without it, and as its
    // real path. Each form ends with a slash. So /w/shop does not match /w/shop-admin. The longest
    // form comes first. So a replacement does not leave /private behind.
    static func folderPrefixes(of folder: String) -> [String] {
        let other = folder.hasPrefix("/private/") ? String(folder.dropFirst(8)) : "/private\(folder)"

        return Set([folder, other, RealPath.of(URL(filePath: folder, directoryHint: .isDirectory))])
            .map { $0.hasSuffix("/") ? $0 : "\($0)/" }
            .sorted { $0.count > $1.count }
    }

    public static func errors(in sources: Sources, limit: Int) -> [SiteError] {
        var all: [SiteError] = []

        if let folder = sources.laravelLogs {
            all += laravelErrors(in: folder, timeZone: sources.timeZone, limit: limit)
        }

        if let file = sources.wordPressLog {
            all += wordPressErrors(in: file, limit: limit)
        }

        if let file = sources.phpLog {
            all += phpErrors(in: file, siteFolder: sources.siteFolder, otherFolders: sources.otherFolders, limit: limit)
        }

        for file in sources.accessLogs {
            all += failedRequests(in: file, limit: limit)
        }

        if let file = sources.appLog {
            all += nodeErrors(in: file, limit: limit)
        }

        let newest = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit)
        return newest.map { $0.relative(to: sources.siteFolder) }
    }

    // storage/logs/laravel.log and the daily files such as laravel-2026-11-10.log, newest file
    // first. An entry starts with [2026-11-10 11:00:00] local.ERROR: and its stack trace follows
    // on the next lines.
    static func laravelErrors(in folder: URL, timeZone: TimeZone, limit: Int) -> [SiteError] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { modified($0) > modified($1) }
            .prefix(3)
        var errors: [SiteError] = []

        for file in files where errors.count < limit {
            errors += laravelErrors(text: tail(of: file), file: file, timeZone: timeZone).reversed().prefix(limit - errors.count)
        }

        return errors
    }

    static func laravelErrors(text: String, file: URL, timeZone: TimeZone) -> [SiteError] {
        let start = #/^\[(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})[^\]]*\] [\w-]+\.(\w+):\s/#
        let serious: Set<String> = ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"]
        var errors: [SiteError] = []
        var current: (time: String, level: String, lines: [Substring])?
        let dates = formatter("yyyy-MM-dd HH:mm:ss", timeZone: timeZone)

        func close() {
            guard let entry = current, serious.contains(entry.level.uppercased()), let first = entry.lines.first else {
                return
            }

            let frames = entry.lines.dropFirst().filter { $0.hasPrefix("#") }.prefix(100).map { String($0.prefix(2000)) }
            let message = String(first.drop { $0 != ":" }.dropFirst().prefix(messageLength)).trimmingCharacters(in: .whitespaces)
            errors.append(SiteError(source: "laravel", time: entry.time, level: entry.level.uppercased(), message: message, trace: frames.isEmpty ? nil : frames, file: file, date: dates.date(from: entry.time)))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.firstMatch(of: start) {
                close()
                let rest = line[match.range.upperBound...]
                current = (String(match.output.1).replacing("T", with: " "), String(match.output.2), [line.prefix(upTo: match.range.lowerBound) + "\(match.output.2): " + rest])
                continue
            }

            current?.lines.append(line)
        }

        close()
        return errors
    }

    // wp-content/debug.log: [10-Nov-2026 10:00:00 UTC] PHP Fatal error: ... Only the errors that
    // stop a page count. The errors of the database count too.
    static func wordPressErrors(in file: URL, limit: Int) -> [SiteError] {
        phpStyleErrors(text: tail(of: file), source: "wordpress", file: file, limit: limit) { _ in true }
    }

    // The PHP-FPM log of a PHP version holds the errors of all sites. Only the lines with the
    // folder of the site count.
    static func phpErrors(in file: URL, siteFolder: String, otherFolders: [String], limit: Int) -> [SiteError] {
        let own = folderPrefixes(of: siteFolder)
        let others = otherFolders.flatMap(folderPrefixes)

        return phpStyleErrors(text: tail(of: file), source: "php", file: file, limit: limit) { line in
            own.contains { line.contains($0) } && !others.contains { line.contains($0) }
        }
    }

    static func phpStyleErrors(text: String, source: String, file: URL, limit: Int, belongs: (Substring) -> Bool) -> [SiteError] {
        let serious = /PHP (Fatal error|Parse error|Recoverable fatal error)|Uncaught |WordPress database error/
        let stamp = /^\[(\d{2}-\w{3}-\d{4} \d{2}:\d{2}:\d{2})(?: ([^\]]+))?\]\s*/
        var errors: [SiteError] = []
        var formatters: [TimeZone: DateFormatter] = [:]

        for line in text.split(separator: "\n").reversed() where errors.count < limit {
            guard line.contains(serious), belongs(line) else {
                continue
            }

            let match = line.firstMatch(of: stamp)
            let time = match.map { String($0.output.1) }
            let zone = match?.output.2.flatMap { TimeZone(identifier: String($0)) ?? TimeZone(abbreviation: String($0)) } ?? .current
            let message = match.map { line[$0.range.upperBound...] } ?? line
            let dates = formatters[zone] ?? formatter("dd-MMM-yyyy HH:mm:ss", timeZone: zone)
            formatters[zone] = dates
            errors.append(SiteError(source: source, time: time, message: String(message.prefix(messageLength)), file: file, date: time.flatMap(dates.date(from:))))
        }

        return errors
    }

    // The access log of nginx: 127.0.0.1 - - [10/Nov/2026:11:00:00 +0100] "GET / HTTP/2.0" 500 ...
    static func failedRequests(in file: URL, limit: Int) -> [SiteError] {
        let entry = #/\[([^\]]+)\] "([A-Z]+) ([^ "]+)[^"]*" (\d{3})\s/#
        let dates = formatter("dd/MMM/yyyy:HH:mm:ss Z", timeZone: .current)
        var errors: [SiteError] = []

        for line in tail(of: file).split(separator: "\n").reversed() where errors.count < limit {
            guard let match = line.firstMatch(of: entry), let status = Int(match.output.4), status >= 500 else {
                continue
            }

            let time = String(match.output.1)
            errors.append(SiteError(source: "request", time: time, level: "\(status)", message: "\(match.output.2) \(match.output.3) gave status \(status)", file: file, date: dates.date(from: time)))
        }

        return errors
    }

    // The log of a Node.js app has no fixed shape. A line with Error, Exception or ERR! counts,
    // with the lines of its stack trace.
    static func nodeErrors(in file: URL, limit: Int) -> [SiteError] {
        let lines = tail(of: file).split(separator: "\n", omittingEmptySubsequences: false)
        let serious = /\b(\w*Error|Exception)\b|ERR!|Unhandled/
        var errors: [SiteError] = []
        var index = lines.count - 1

        while index >= 0, errors.count < limit {
            let line = lines[index]

            if line.contains(serious), !line.trimmingCharacters(in: .whitespaces).hasPrefix("at ") {
                let trace = lines[(index + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }.prefix(frames).map { String($0.trimmingCharacters(in: .whitespaces).prefix(frameLength)) }
                errors.append(SiteError(source: "node", time: nil, message: String(line.prefix(messageLength)), trace: trace.isEmpty ? nil : trace, file: file, date: nil))
            }

            index -= 1
        }

        return errors
    }

    public static func tail(of file: URL, bytes: Int = tailBytes) -> String {
        TerminalOutput.tailText(of: file, maximumBytes: bytes)
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // A log full of errors has many entries. Each parser makes its formatter once.
    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
