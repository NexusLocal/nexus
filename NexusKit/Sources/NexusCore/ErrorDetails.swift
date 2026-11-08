import Foundation
import Synchronization

// The full output of a program that failed goes to logs/errors.log, next to the activity log. A
// message keeps only the line that tells the cause and a reference such as "(details 3F2A9C)". The
// app shows that line with "Details…", and its sheet reads the entry here (owner, 2026-11-07).
public enum ErrorDetails {
    public static let sizeLimit = 5_000_000
    private static let file = Mutex<URL?>(nil)
    private static let recent = Mutex<[Int: String]>([:])

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let header: String
        public let output: String
    }

    // nexusd sets the file at its start. Without a file, a failure gets no entry and no reference.
    public static func write(to file: URL?) {
        self.file.withLock { $0 = file }
    }

    // A command error records its output only when its text is made, so only for a failure that a
    // person can see. The same failure gets the same entry, also when its text is made twice. A
    // program that failed without output gets no entry.
    public static func record(program: String, status: Int32, output: String) -> String? {
        guard let file = file.withLock({ $0 }) else {
            return nil
        }

        var hasher = Hasher()
        hasher.combine(program)
        hasher.combine(status)
        hasher.combine(output)
        let key = hasher.finalize()

        if let id = recent.withLock({ $0[key] }) {
            return id
        }

        let id = record(program: program, status: status, output: output, in: file)

        recent.withLock { recent in
            if recent.count > 200 {
                recent.removeAll()
            }

            recent[key] = id
        }

        return id
    }

    static func record(program: String, status: Int32, output: String, in file: URL) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return nil
        }

        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let time = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
        let body = excerpt(ActivityLog.withoutSecrets(text), head: 10_000, tail: 40_000)

        ActivityLog.append("==== \(id) \(time) \(program), exit status \(status)\n\(body)\n==== end \(id)\n", to: file, limit: sizeLimit)
        return id
    }

    // The start and the end of a long text, cut at the ends of lines. PHP names the cause before its
    // trace, and most other programs name it at the end. A line "..." shows the cut.
    public static func excerpt(_ text: String, head: Int, tail: Int) -> String {
        guard text.count > head + tail else {
            return text
        }

        let start = text.prefix(head)
        let end = text.suffix(tail)
        let wholeStart = start.range(of: "\n", options: .backwards).map { start[..<$0.lowerBound] } ?? start
        let wholeEnd = end.range(of: "\n").map { end[$0.upperBound...] } ?? end

        return "\(wholeStart)\n...\n\(wholeEnd)"
    }

    public static func reference(_ id: String) -> String {
        "(details \(id))"
    }

    // The message without its references, and the newest reference.
    public static func split(_ message: String) -> (text: String, id: String?) {
        let ids = message.matches(of: referencePattern).map { String($0.output.1) }
        return (message.replacing(referencePattern, with: ""), ids.last)
    }

    public static func entry(_ id: String, in file: URL) -> Entry? {
        for candidate in [file, ActivityLog.olderFile(of: file)] {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8), let start = text.range(of: "==== \(id) ", options: .backwards) else {
                continue
            }

            let rest = text[start.upperBound...]
            let headerEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            let bodyStart = headerEnd < rest.endIndex ? rest.index(after: headerEnd) : headerEnd
            let bodyEnd = rest.range(of: "\n==== end \(id)")?.lowerBound ?? rest.endIndex

            return Entry(id: id, header: String(rest[..<headerEnd]), output: bodyStart <= bodyEnd ? String(rest[bodyStart..<bodyEnd]) : "")
        }

        return nil
    }

    // The line that tells the cause, in this order:
    // - an error of PHP, for example the message of an uncaught exception before its trace;
    // - the line after "In Connection.php line 825:" of a Symfony or Laravel console;
    // - "Error:" of WP-CLI, "ERROR" of the clients of MySQL and MariaDB, and the errors of git,
    //   Composer and npm;
    // - else the first line that is no trace, no warning and no notice.
    public static func summary(of output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "..." && split($0).id == nil }

        if let php = lines.first(where: { line in phpErrors.contains { line.contains($0) } }) {
            return sentence(phpError(php))
        }

        if let place = lines.firstIndex(where: { $0.wholeMatch(of: consolePlace) != nil }), place + 1 < lines.endIndex {
            return sentence(lines[place + 1])
        }

        if let error = lines.first(where: { $0.hasPrefix("Error: ") }) {
            return sentence(String(error.dropFirst("Error: ".count)))
        }

        if let error = lines.first(where: { line in errorStarts.contains { line.hasPrefix($0) } }) {
            return sentence(error)
        }

        return lines.first { line in !line.hasPrefix("#") && !line.hasPrefix("Stack trace") && !noiseStarts.contains { line.hasPrefix($0) } }.map(sentence) ?? ""
    }

    private static let phpErrors = ["Fatal error:", "Parse error:"]
    private static let errorStarts = ["ERROR ", "error: ", "fatal: ", "npm error ", "npm ERR! ", "Your requirements could not be resolved"]
    private static let noiseStarts = ["...", "PHP Warning:", "Warning:", "PHP Deprecated:", "Deprecated:", "PHP Notice:", "Notice:", "mysql: [Warning]"]

    // "PHP Fatal error:  Uncaught Name\Of\Exception: The message. in /path/Config.php:106"
    static func phpError(_ line: String) -> String {
        guard let start = phpErrors.lazy.compactMap({ line.range(of: $0) }).first else {
            return line
        }

        var text = line[start.upperBound...].trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("Uncaught "), let colon = text.range(of: ": ") {
            text = String(text[colon.upperBound...])
        }

        if let place = text.range(of: " in /", options: .backwards) {
            text = String(text[..<place.lowerBound])
        }

        return text
    }

    // At most 300 characters, and a period at the end. So a next sentence of the message does not
    // run on.
    static func sentence(_ text: String) -> String {
        var short = text

        if short.count > 300 {
            let cut = short.prefix(300)
            short = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
        }

        return ".!?…)".contains(short.last ?? ".") ? short : short + "."
    }

    nonisolated(unsafe) private static let referencePattern = /\s*\(details ([0-9A-F]{6})\)/
    nonisolated(unsafe) private static let consolePlace = /In .+ line \d+:/
}
