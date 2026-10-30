import NexusCore

// The placeholders of the keys that a site adds (D45).
public enum WorkspaceKeys {
    public static let workspacePlaceholder = "{workspace}"

    public static func portNames(in keys: [WorkspaceEnvKey]) -> [String] {
        let names = keys.flatMap { $0.value.matches(of: #/\{port:([A-Za-z0-9_-]+)\}/#).map { String($0.output.1) } }
        return Array(Set(names)).sorted()
    }

    public static func expanded(_ keys: [WorkspaceEnvKey], workspace: String, host: String, database: String?, ports: [String: Int]) -> [String: String] {
        keys.reduce(into: [String: String]()) { result, entry in
            let value = entry.value
                .replacing(workspacePlaceholder, with: workspace)
                .replacing("{host}", with: host)
                .replacing("{database}", with: database ?? "")

            result[entry.key] = ports.reduce(value) { value, port in
                value.replacing("{port:\(port.key)}", with: String(port.value))
            }
        }
    }
}
