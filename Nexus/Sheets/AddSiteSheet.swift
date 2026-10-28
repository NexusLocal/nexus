import AppKit
import NexusCore
import SwiftUI

// The sheet stays open while nexusd adds the site, because nexusd can start nginx and PHP first.
// A failure shows in the sheet, so the user can change the values.
struct AddSiteSheet: View {
    enum FolderType {
        case oneProject
        case manyProjects
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folderType: FolderType
    @State private var folder: URL?
    @State private var host = ""
    @State private var aliases = ""
    @State private var group = ""
    @State private var server = WebServer.nginx.rawValue
    @State private var php = ""
    @State private var adding = false
    @State private var failure: String?

    init(folder: URL?, manyProjects: Bool) {
        _folder = State(initialValue: folder)
        _folderType = State(initialValue: manyProjects ? .manyProjects : .oneProject)
    }

    private var protectedFolder: String? {
        folder.flatMap { ProtectedFolder.name(of: $0.path(percentEncoded: false)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a site")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder type")
                    .fontWeight(.semibold)

                HStack(spacing: 10) {
                    FolderTypeCard(title: "One project", detail: "The folder becomes one site.", selected: folderType == .oneProject) {
                        folderType = .oneProject
                    }
                    FolderTypeCard(title: "Many projects", detail: "Each folder inside becomes a site. New folders become sites later too.", selected: folderType == .manyProjects) {
                        folderType = .manyProjects
                    }
                }
            }

            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            if let folder {
                                PathText((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            } else {
                                Text("No folder")
                                    .foregroundStyle(.tertiary)
                            }

                            Button("Choose…", action: chooseFolder)
                        }
                    }
                } footer: {
                    if let protectedFolder {
                        Text(ProtectedFolder.explanation(protectedFolder))
                    }
                }

                Section {
                    if folderType == .oneProject {
                        LabeledContent("Host") {
                            TextField("Host", text: $host)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .font(.system(.body, design: .monospaced))
                                .plainTextInput()
                                .frame(width: 220)
                        }

                        LabeledContent("Aliases") {
                            TextField("Aliases", text: $aliases, prompt: Text("None"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .plainTextInput()
                                .frame(width: 220)
                        }

                        Picker("Group", selection: $group) {
                            Text("None").tag("")
                            ForEach(model.groupNames, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    Picker("Webserver", selection: $server) {
                        Text("nginx").tag(WebServer.nginx.rawValue)
                        Text("Apache").tag(WebServer.apache.rawValue)
                    }

                    Picker("PHP", selection: $php) {
                        ForEach(model.installedPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Label(failure, systemImage: "xmark.circle")
                    .foregroundStyle(Color.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                if adding {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(folderType == .oneProject ? "Add site" : "Add folder") {
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adding || folder == nil || php.isEmpty || folderType == .oneProject && host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            server = model.siteDefaults.server.rawValue
            php = model.defaultPHP

            if let folder, host.isEmpty {
                host = suggestedHost(for: folder)
            }
        }
    }

    private func suggestedHost(for folder: URL) -> String {
        "\(HostName.label(from: folder.lastPathComponent)).\(model.settings.tld)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder

        guard panel.runModal() == .OK, let chosen = panel.url else {
            return
        }

        if folder.map(suggestedHost) == host || host.isEmpty {
            host = suggestedHost(for: chosen)
        }

        folder = chosen
        failure = nil
    }

    private func add() {
        guard let folder, let choice = WebServer(rawValue: server) else {
            return
        }

        adding = true
        failure = nil

        Task {
            failure = switch folderType {
            case .oneProject:
                await model.addSite(folder: folder, host: host.trimmingCharacters(in: .whitespaces).lowercased(), aliases: HostList.names(in: aliases), group: group.isEmpty ? nil : group, server: choice, php: php)
            case .manyProjects:
                await model.park(folder: folder, server: choice, php: php)
            }
            adding = false

            if failure == nil {
                dismiss()
            }
        }
    }
}

// A folder with a file of a project, such as composer.json or a public folder, is one project.
// A folder without such a file holds many projects when a folder in it is a project. A large
// folder takes time to read, so the check runs outside the main thread.
nonisolated enum ProjectFolder {
    private static let markers = ["composer.json", "package.json", "artisan", "index.php", "index.html", "public", ".git", "wp-config.php"]

    static func holdsManyProjects(_ folder: URL) -> Bool {
        guard !isProject(folder) else {
            return false
        }

        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && isProject(child)
        }
    }

    private static func isProject(_ folder: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
    }
}

private struct FolderTypeCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Color.accentSoft : Color.clear, in: .rect(cornerRadius: 10))
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
