import Foundation

// With the PATH setting on, the terminal of the user must run the links in bin/ for php,
// composer, node and npm (D39). An alias or a shell function wins over the PATH. A line after the
// line of Nexus can win too. A new login shell of zsh tells what each name runs. The app shows
// each name that does not run Nexus. So the user knows that another program runs. (owner)
public struct OtherCommand: Sendable, Hashable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    // No program has the name: the link in bin/ is missing, or it points to an app that moved.
    public var isNotFound: Bool {
        description == "\(name) not found"
    }
}

public enum ShellCommands {
    static let marker = "nexus-shell-check"

    // The files that a new login shell of zsh reads. A sourced file of the user is not in it.
    public static func files(home: URL) -> [URL] {
        [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".profile"].map { home.appending(path: $0) }
            + ["zshenv", "zprofile", "zshrc", "zlogin"].map { URL(filePath: "/etc").appending(path: $0) }
    }

    // The shell files can print text of their own. So the answer starts after a marker line.
    public static var script: String {
        "print -r -- \(marker); whence -v -- \(ProjectTool.allCases.map(\.rawValue).joined(separator: " ")); true"
    }

    // whence -v gives "php is /path/php", "php is an alias for ..." or "php not found". A path
    // with a space comes in single quotes, as the path of Nexus in Application Support does. A
    // folder on the PATH can end with a / or be a link to the bin folder. So the check compares
    // the real folders. ~/.zlogout can print text after the answer. So only the first line for
    // each name counts.
    public static func others(in output: String, bin: URL) -> [OtherCommand] {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        guard let start = lines.lastIndex(of: marker) else {
            return []
        }

        let folder = RealPath.of(bin)
        var answered: Set<ProjectTool> = []

        return lines[(start + 1)...].compactMap { line in
            guard let tool = ProjectTool.allCases.first(where: { line.hasPrefix("\($0.rawValue) ") }), answered.insert(tool).inserted else {
                return nil
            }

            let other = OtherCommand(name: tool.rawValue, description: line)
            let found = "\(tool.rawValue) is "

            guard line.hasPrefix(found) else {
                return other
            }

            let path = unquoted(String(line.dropFirst(found.count)))
            let program = URL(filePath: path)

            guard path.hasPrefix("/"), program.lastPathComponent == tool.rawValue else {
                return other
            }

            return RealPath.of(program.deletingLastPathComponent()) == folder ? nil : other
        }
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count > 1, text.hasPrefix("'"), text.hasSuffix("'") else {
            return text
        }

        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
