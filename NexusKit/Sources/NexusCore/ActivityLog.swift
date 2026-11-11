import Darwin
import Foundation

// A record of what happened, so a problem can be traced later. The app and nexusd write to one
// file, and the file never leaves the Mac. Each line goes through one write with O_APPEND, so the
// lines of the two programs do not mix. Two files of at most the limit stay on disk.
public final class ActivityLog: Sendable {
    public static let sizeLimit = 5_000_000
    private static let longestText = 500

    private let file: URL
    private let source: String
    private let limit: Int
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.activity")

    public init(file: URL, source: String, limit: Int = ActivityLog.sizeLimit) {
        self.file = file
        self.source = source
        self.limit = limit
    }

    public func write(_ kind: String, _ text: String) {
        let line = Self.line(date: .now, source: source, kind: kind, text: text)

        queue.async { [file, limit] in
            Self.append(line, to: file, limit: limit)
        }
    }

    public func waitForWrites() {
        queue.sync {}
    }

    static func line(date: Date, source: String, kind: String, text: String) -> String {
        let time = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        return "\(time) \(source) \(kind): \(hidingSecrets(in: text))\n"
    }

    // The requests hold no secrets, but an error of another program can repeat one.
    static func hidingSecrets(in text: String) -> String {
        String(withoutSecrets(text.replacingOccurrences(of: "\n", with: " ")).prefix(longestText))
    }

    // Keeps the lines, for the full output of a program in errors.log and in a report. A value ends
    // at the end of its line, so a key without a value does not hide the next line.
    public static func withoutSecrets(_ text: String) -> String {
        let keys = text.replacingOccurrences(
            of: "\\b([a-z_]*(?:password|passwd|pwd|secret|token|api[_-]?key)[a-z_]*)[\"']?[ \\t]*[=:][ \\t]*(?:\"[^\"\\n]*\"|'[^'\\n]*'|\\S+)",
            with: "$1=<hidden>",
            options: [.regularExpression, .caseInsensitive]
        )
        let sql = keys.replacingOccurrences(
            of: "\\b(identified by|password)[ \\t]+'(?:[^'\\n]|'')*'",
            with: "$1 <hidden>",
            options: [.regularExpression, .caseInsensitive]
        )
        let urls = sql.replacingOccurrences(
            of: "://([^:/@\\s]+):[^@\\s]+@",
            with: "://$1:<hidden>@",
            options: .regularExpression
        )

        return urls
    }

    static func append(_ line: String, to file: URL, limit: Int) {
        let path = file.path(percentEncoded: false)

        guard let descriptor = try? AppendingFile.open(file, mode: 0o600) else {
            return
        }

        defer { close(descriptor) }

        var bytes = Array(line.utf8)
        _ = Darwin.write(descriptor, &bytes, bytes.count)

        var status = stat()
        var current = stat()

        // The other program can have moved this full file already. The path then names a new file,
        // and a move of that file would replace the older file.
        if fstat(descriptor, &status) == 0, status.st_size >= limit, stat(path, &current) == 0, current.st_ino == status.st_ino {
            rename(path, olderFile(of: file).path(percentEncoded: false))
        }
    }

    public static func olderFile(of file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("1.log")
    }
}
