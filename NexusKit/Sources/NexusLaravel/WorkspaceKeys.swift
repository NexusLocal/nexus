import NexusCore

// The placeholders of the keys that a site adds (D45).
public enum WorkspaceKeys {
    public static let workspacePlaceholder = "{workspace}"
    public static let databasePlaceholder = "{database}"

    public static func portNames(in texts: [String]) -> [String] {
        let names = texts.flatMap { $0.matches(of: #/\{port:([A-Za-z0-9_-]+)\}/#).map { String($0.output.1) } }
        return Array(Set(names)).sorted()
    }

    // A SQLite path can hold a space, and the shell of a command would split that path.
    public static func shellWord(_ text: String) -> String {
        guard text.wholeMatch(of: #/[A-Za-z0-9_\/.:=@%+,-]*/#) == nil else {
            return text
        }

        return "'\(text.replacing("'", with: #"'\''"#))'"
    }

    public static func expanded(_ keys: [WorkspaceEnvKey], workspace: String, host: String, database: String?, ports: [String: Int]) -> [String: String] {
        keys.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = expanded(entry.value, workspace: workspace, host: host, database: database, ports: ports)
        }
    }

    public static func expanded(_ text: String, workspace: String, host: String, database: String?, ports: [String: Int]) -> String {
        let value = text
            .replacing(workspacePlaceholder, with: workspace)
            .replacing("{host}", with: host)
            .replacing(databasePlaceholder, with: database ?? "")

        return ports.reduce(value) { value, port in
            value.replacing("{port:\(port.key)}", with: String(port.value))
        }
    }
}
