import Foundation

// The code editors that Nexus knows, in the order that Nexus suggests them (D61). The app and
// nexus edit share them. The app keeps the path of the chosen editor under preferenceKey. An empty
// path is the choice "None".
public enum CodeEditors {
    public static let preferenceKey = "editorApp"

    // How an editor opens a file at a line. A JetBrains IDE gets the line as an argument of a new
    // instance, as its command line launcher does. That instance gives the file to the IDE that
    // runs and quits. The other editors get a link in their own scheme: with the path and the line
    // after "file", with a file URL in the query, or with the path in the query.
    enum AtLine {
        case launchArguments
        case pathLink(scheme: String)
        case fileURLLink(scheme: String)
        case filenameLink(scheme: String)
    }

    private static let editors: [(bundleIdentifier: String, atLine: AtLine)] = [
        ("com.jetbrains.PhpStorm", .launchArguments),
        ("com.microsoft.VSCode", .pathLink(scheme: "vscode")),
        ("com.todesktop.230313mzl4w4u92", .pathLink(scheme: "cursor")),
        ("com.exafunction.windsurf", .pathLink(scheme: "windsurf")),
        ("dev.zed.Zed", .pathLink(scheme: "zed")),
        ("com.sublimetext.4", .fileURLLink(scheme: "subl")),
        ("com.panic.Nova", .filenameLink(scheme: "nova")),
        ("com.jetbrains.WebStorm", .launchArguments),
        ("com.jetbrains.intellij", .launchArguments),
        ("com.jetbrains.intellij.ce", .launchArguments),
        ("com.barebones.bbedit", .fileURLLink(scheme: "x-bbedit")),
        ("com.macromates.TextMate", .fileURLLink(scheme: "txmt")),
    ]

    public static let bundleIdentifiers = editors.map(\.bundleIdentifier)

    public enum FileAtLine: Equatable, Sendable {
        case launchArguments([String])
        case link(URL)
    }

    // The value of a query item. The & and the = of a path must not end the value.
    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    // nil means that Nexus knows no way for this editor. The app then opens the file without the
    // line.
    public static func fileAtLine(_ path: String, line: Int, editor bundleIdentifier: String) -> FileAtLine? {
        guard let atLine = editors.first(where: { $0.bundleIdentifier == bundleIdentifier })?.atLine else {
            return nil
        }

        let link: String

        switch atLine {
        case .launchArguments:
            return .launchArguments(["--line", String(line), path])
        case .pathLink(let scheme):
            link = "\(scheme)://file\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path):\(line)"
        case .fileURLLink(let scheme):
            link = "\(scheme)://open?url=\(URL(filePath: path).absoluteString.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "")&line=\(line)"
        case .filenameLink(let scheme):
            link = "\(scheme)://core/open/file?filename=\(path.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "")&line=\(line)"
        }

        return URL(string: link).map(FileAtLine.link)
    }

    // How the app and nexusd open a file at a line in this editor. nil opens the file itself: Nexus
    // knows no way for the editor, there is no line, or an older version of the editor lacks the
    // scheme of its link.
    public static func target(_ path: String, line: Int?, editor bundleIdentifier: String?, declares: (String?) -> Bool) -> FileAtLine? {
        guard let line, let bundleIdentifier, let atLine = fileAtLine(path, line: line, editor: bundleIdentifier) else {
            return nil
        }

        if case .link(let link) = atLine, !declares(link.scheme) {
            return nil
        }

        return atLine
    }

    public static func app(at app: URL, declares scheme: String?) -> Bool {
        guard let scheme, let types = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }

        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }
    }
}
