import Foundation

// Compares version lines by number, so 8.10 is newer than 8.2.
public enum VersionLine {
    public static func isOlder(_ line: String, than other: String) -> Bool {
        line.compare(other, options: .numeric) == .orderedAscending
    }

    public static func newest(_ lines: some Sequence<String>) -> String? {
        lines.max { isOlder($0, than: $1) }
    }
}
