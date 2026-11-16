import Foundation

// A dev server is a background command with {port:vite} (owner, 2026-11-15). It runs only after a
// page of its site or workspace.
public enum DevServer {
    public static let portName = "vite"
    public static let placeholder = "{port:\(portName)}"

    public static func isDevServer(_ command: String) -> Bool {
        command.contains(placeholder)
    }

    // The words of the command before its first option, for example npm run dev.
    public static func displayName(of command: String) -> String {
        let words = command.split(separator: " ").prefix { !$0.hasPrefix("-") && !$0.contains("{port:") }
        return words.isEmpty ? command : words.joined(separator: " ")
    }

    // The page of a failed start names the build of the same package manager.
    public static func buildCommand(for command: String) -> String {
        let manager = command.split(separator: " ").first.map(String.init) ?? ""
        return ["pnpm", "yarn", "bun"].contains(manager) ? "\(manager) run build" : "npm run build"
    }

    // public/hot holds an address such as http://[::1]:5173.
    public static func port(inHotFile contents: String) -> Int? {
        URL(string: contents.trimmingCharacters(in: .whitespacesAndNewlines))?.port
    }
}

// "Stop a dev server after" in Settings > Sites (owner, 2026-11-15). The raw value is the number
// of minutes, and 0 is Never. The order of the cases is the order of the picker.
public enum DevServerStop: Int, Codable, Sendable, CaseIterable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case never = 0

    public static let standard = DevServerStop.fiveMinutes

    public var title: String {
        self == .never ? "Never" : Count.text(rawValue, "minute")
    }

    public var duration: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue * 60)
    }
}
