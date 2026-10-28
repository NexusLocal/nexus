import Foundation

// Reads the keys of a .env file. A value can have quotes, and a value without quotes ends at a #
// with a space before it. A line can start with export. ${...} stays as text.
public enum EnvFile {
    public static func values(of file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return [:]
        }

        return values(in: text)
    }

    public static func values(in text: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }

            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equals].trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                continue
            }

            values[key] = value(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
        }

        return values
    }

    private static func value(_ raw: String) -> String {
        if let quote = raw.first, quote == "\"" || quote == "'" {
            let rest = raw.dropFirst()
            return String(rest.prefix { $0 != quote })
        }

        if let comment = raw.range(of: " #") {
            return String(raw[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        return raw
    }
}
