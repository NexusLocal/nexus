import AppKit
import NexusCore

// The code editor of Settings > General opens a file, at a line when Nexus knows how. A user
// without a code editor gets the app of the file, or TextEdit when the file has none. A .ini or a
// .env file often has no app.
extension AppModel {
    static let textEdit = URL(filePath: "/System/Applications/TextEdit.app", directoryHint: .isDirectory)

    func openInEditor(_ path: String, line: Int? = nil) {
        let file = URL(filePath: path)

        Task {
            do {
                try await open(file, line: line)
            } catch {
                failure = ActionFailure(title: "\(file.lastPathComponent) did not open", message: error.localizedDescription, place: .window)
            }
        }
    }

    private func open(_ file: URL, line: Int?) async throws {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()

        guard let editor = editorApp?.location else {
            try await workspace.open([file], withApplicationAt: workspace.urlForApplication(toOpen: file) ?? Self.textEdit, configuration: configuration)
            return
        }

        let identifier = Bundle(url: editor)?.bundleIdentifier
        let target = CodeEditors.target(file.path(percentEncoded: false), line: line, editor: identifier) { scheme in CodeEditors.app(at: editor, declares: scheme) }

        switch target {
        case .launchArguments(let arguments)?:
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            try await workspace.openApplication(at: editor, configuration: configuration)
        case .link(let link)?:
            try await workspace.open([link], withApplicationAt: editor, configuration: configuration)
        case nil:
            try await workspace.open([file], withApplicationAt: editor, configuration: configuration)
        }
    }
}
