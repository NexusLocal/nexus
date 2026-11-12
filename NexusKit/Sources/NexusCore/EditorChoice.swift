import Foundation

// The code editor of Settings > General in the app, for nexus edit and for the web page of the
// dumps in nexusd. A chosen app that is not installed anymore gives the first known editor, as in
// the app. The app itself opens files with NSWorkspace.
public enum EditorChoice: Equatable, Sendable {
    case none
    case app(path: String)
    case firstKnown

    public init(preference: String?, appExists: (String) -> Bool) {
        guard let preference else {
            self = .firstKnown
            return
        }

        if preference.isEmpty {
            self = .none
            return
        }

        self = appExists(preference) ? .app(path: preference) : .firstKnown
    }

    public static var current: EditorChoice {
        let preference = UserDefaults.standard.persistentDomain(forName: NexusIdentifiers.app)?[CodeEditors.preferenceKey] as? String

        return EditorChoice(preference: preference) { FileManager.default.fileExists(atPath: $0) }
    }

    // Opens a file or a folder, at a line when Nexus knows how for the editor. Without a code
    // editor a file opens in the default text editor of macOS. The path can come from a dump of a
    // site. So it never opens in its own app: a .command file or an app would then run. Returns
    // false when nothing opened it.
    public func open(_ path: String, line: Int? = nil) async -> Bool {
        switch self {
        case .none:
            return await SystemOpen.run(["-t", path])
        case .app(let app):
            let identifier = Bundle(path: app)?.bundleIdentifier
            let target = CodeEditors.target(path, line: line, editor: identifier) { scheme in CodeEditors.app(at: URL(filePath: app), declares: scheme) }
            return await Self.open(path, target: target, app: ["-a", app], linkApp: ["-a", app])
        case .firstKnown:
            for identifier in CodeEditors.bundleIdentifiers {
                let target = CodeEditors.target(path, line: line, editor: identifier) { _ in true }

                if await Self.open(path, target: target, app: ["-b", identifier], linkApp: []) {
                    return true
                }
            }

            return false
        }
    }

    // app names the editor for open: -a with its path, or -b with its bundle identifier. A link
    // without linkApp goes to the app that declares its scheme. Without such an app open fails,
    // for example with an older version of the editor. The file then opens without the line.
    private static func open(_ path: String, target: CodeEditors.FileAtLine?, app: [String], linkApp: [String]) async -> Bool {
        switch target {
        case .launchArguments(let arguments)?:
            return await SystemOpen.run(["-n"] + app + ["--args"] + arguments)
        case .link(let link)?:
            if await SystemOpen.run(linkApp + [link.absoluteString]) {
                return true
            }

            return await SystemOpen.run(app + [path])
        case nil:
            return await SystemOpen.run(app + [path])
        }
    }
}

// /usr/bin/open with these arguments. Returns true when it ended without an error. The wait holds
// no thread.
public enum SystemOpen {
    public static func run(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/open")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { ended in
                continuation.resume(returning: ended.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
