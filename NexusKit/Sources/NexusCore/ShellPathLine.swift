import Foundation

// The PATH setting (D39): one line at the end of ~/.zshrc that puts the bin folder of Nexus first
// on the PATH. zsh reads ~/.zshrc last at the start of a shell. So a line at its end wins over the
// PHP folders that other tools put on the PATH. An alias still wins over it. The comment at the
// end of the line marks the line of Nexus, also when the user moves it.
public struct ShellPathLine: Sendable {
    public enum State: Sendable, Equatable {
        case off
        case on
        // Another line comes after the line of Nexus. That line can put other folders first.
        case notLast
    }

    public static let marker = "# Added by Nexus (Settings > General > Add Nexus to PATH)"

    public let file: URL
    public let line: String

    public init(bin: URL, home: URL) {
        file = home.appending(path: ".zshrc")
        line = "export PATH=\"\(Self.shellPath(bin, home: home)):$PATH\" \(Self.marker)"
    }

    public static var standard: ShellPathLine {
        ShellPathLine(bin: NexusPaths.standard.bin, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public func state() -> State {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .off
        }

        return Self.state(of: text)
    }

    public func turnOn() throws {
        try change { Self.adding(line, to: $0) }
    }

    public func turnOff() throws {
        try change(Self.removing)
    }

    static func state(of text: String) -> State {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        guard lines.contains(where: { $0.contains(marker) }) else {
            return .off
        }

        let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last?.contains(marker) == true ? .on : .notLast
    }

    // A line of Nexus that is not at the end moves to the end.
    static func adding(_ line: String, to text: String) -> String {
        var kept = removing(from: text)

        if !kept.isEmpty, !kept.hasSuffix("\n") {
            kept += "\n"
        }

        return kept + line + "\n"
    }

    static func removing(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(marker) }
            .joined(separator: "\n")
    }

    // A ~/.zshrc can be a link to a file in a folder of dotfiles. The change goes to that file, so
    // the link stays. The file keeps its permissions. A file that is not UTF-8 stays as it is.
    private func change(_ transform: (String) -> String) throws {
        let target = file.resolvingSymlinksInPath()
        let path = target.path(percentEncoded: false)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: path)
        let text = exists ? try String(contentsOf: target, encoding: .utf8) : ""
        let changed = transform(text)

        guard changed != text else {
            return
        }

        let permissions = exists ? try fileManager.attributesOfItem(atPath: path)[.posixPermissions] : nil
        try Data(changed.utf8).write(to: target, options: .atomic)

        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    // The folder in double quotes. A folder in the home folder starts with $HOME. So the line still
    // works after a move to another Mac.
    static func shellPath(_ folder: URL, home: URL) -> String {
        let path = RealPath.trimmed(folder.path(percentEncoded: false))
        let homePath = RealPath.trimmed(home.path(percentEncoded: false)) + "/"
        let escaped = { (text: String) in
            text.reduce(into: "") { result, character in
                if "\\\"$`".contains(character) {
                    result.append("\\")
                }

                result.append(character)
            }
        }

        guard path.hasPrefix(homePath) else {
            return escaped(path)
        }

        return "$HOME/" + escaped(String(path.dropFirst(homePath.count)))
    }
}
