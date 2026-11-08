import AppKit
import NexusCore
import NexusIPC
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
    @State private var kind = SiteKind.php
    @State private var project: NodeProject?
    @State private var projectNode: NodeChoice?
    @State private var command = ""
    @State private var node = NodeLines.fromProject
    @State private var address = ""
    @State private var adding = false
    @State private var failure: String?
    @State private var errorReport: ErrorReport?
    @State private var wordPress: WordPressChoice?
    @State private var projectType: PHPProjectType?
    @State private var workspaceDatabases = WorkspaceDatabaseChoice.default

    let tld: String

    // The values that a WordPress folder gives, as nexusd gives them (owner, 2026-11-06).
    private struct WordPressChoice {
        let type: PHPProjectType
        let server: String
        let php: String
    }

    // The Host field gets the focus when the sheet appears. A value that comes after that does not
    // show in the field. So the host is here from the start.
    init(folder: URL?, manyProjects: Bool, tld: String) {
        self.tld = tld
        _folder = State(initialValue: folder)
        _folderType = State(initialValue: manyProjects ? .manyProjects : .oneProject)
        _host = State(initialValue: folder.map { Self.suggestedHost(for: $0, tld: tld) } ?? "")
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
                    .labeledContentStyle(.rowValue)
                } footer: {
                    if let protectedFolder {
                        Text(ProtectedFolder.explanation(protectedFolder))
                    }
                }

                Section {
                    if folderType == .oneProject {
                        oneProjectRows
                    } else {
                        phpRows
                    }
                } footer: {
                    if folderType == .oneProject {
                        kindFooter
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            if let failure {
                FailureLabel(message: failure) { errorReport = $0 }
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
                .disabled(adding || folder == nil || !hasRequiredValues)
            }
        }
        .padding(20)
        .frame(width: 540)
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
        .onAppear {
            server = model.siteDefaults.server.rawValue
            php = model.defaultPHP

            if let folder {
                detect(in: folder)
            }
        }
        // The sheet can open before the app knows the installed versions, for example at launch. A
        // value that the user chose in that time stays.
        .onChange(of: model.installedPHPVersions) {
            guard php.isEmpty else {
                return
            }

            let detectedServer = wordPress?.server
            php = model.defaultPHP

            if let folder, detectedServer == nil || server == detectedServer {
                detectWordPress(in: folder)
            }
        }
        .onChange(of: folderType) {
            if let folder {
                detectWordPress(in: folder)
            }
        }
    }

    private var hasRequiredValues: Bool {
        guard folderType == .oneProject else {
            return !php.isEmpty
        }

        guard !host.isEmpty else {
            return false
        }

        return switch kind {
        case .php: !php.isEmpty
        case .node: !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .proxy: !address.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @ViewBuilder
    private var oneProjectRows: some View {
        LabeledContent("Host") {
            CodeField(title: "Host", text: $host)
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

        Picker("Runs as", selection: $kind) {
            ForEach(SiteKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }

        switch kind {
        case .php:
            phpRows
        case .node:
            LabeledContent("Command") {
                CodeField(title: "Command", text: $command, prompt: "npm run dev")
            }

            Picker("Node", selection: $node) {
                Text(projectNode.map { "\($0.line) (\($0.reason))" } ?? "From the project").tag(NodeLines.fromProject)
                ForEach(model.installedNodeVersions, id: \.self) { Text("Node \($0)").tag($0) }
            }
        case .proxy:
            LabeledContent("Address") {
                CodeField(title: "Address", text: $address, prompt: "http://127.0.0.1:3000")
            }
        }

        if offersEmptyDatabases {
            Picker("Workspace databases", selection: $workspaceDatabases) {
                Text("Default (\((model.siteList?.newWorkspaceDatabases ?? .copy).displayName.lowercased()))").tag(WorkspaceDatabaseChoice.default)
                Divider()
                ForEach(WorkspaceDatabaseKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(WorkspaceDatabaseChoice(kind))
                }
            }
        }
    }

    // A WordPress site always gets a copy, and a PHP site that is no Laravel application gets no
    // databases in a workspace (D54).
    private var offersEmptyDatabases: Bool {
        kind == .node || (kind == .php && projectType == .laravel)
    }

    @ViewBuilder
    private var phpRows: some View {
        Picker("Webserver", selection: $server) {
            Text("nginx").tag(WebServer.nginx.rawValue)
            Text("Apache").tag(WebServer.apache.rawValue)
        }

        Picker("PHP", selection: $php) {
            ForEach(model.installedPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
        }
    }

    @ViewBuilder
    private var kindFooter: some View {
        let url = "https://\(host.isEmpty ? "the host" : host)"

        switch kind {
        case .php:
            if let wordPress, !php.isEmpty, server == wordPress.server, php == wordPress.php {
                Text("Nexus found \(wordPress.type.displayName) in the folder. So the site gets \((WebServer(rawValue: server) ?? .nginx).displayName) and PHP \(php).")
            }
        case .node:
            Text(appNote(url: url))
        case .proxy:
            Text(SiteKindNote.proxy(url: url))
        }
    }

    private func appNote(url: String) -> String {
        guard project?.command != nil else {
            return "package.json has no dev or start script. Enter the command that starts the app. Nexus gives it a free port in PORT and sends \(url) to it."
        }

        let found = project?.framework.map { "Nexus found \($0.displayName) in package.json. " } ?? ""

        return "\(found)Nexus starts the command with a free port and sends \(url) to it."
    }

    // The files of the folder decide the kind, the command and the Node version (D67). The user can
    // change each of them.
    // The Node picker starts at the Node version of the defaults for a new site, as in nexusd (D59).
    // The line of the project follows the same rule as the line that the Site screen shows.
    private func detect(in folder: URL) {
        let defaultNode = model.siteDefaults.node.flatMap { model.installedNodeVersions.contains($0) ? $0 : nil }

        kind = SiteKind.detected(in: folder)
        project = NodeProject.read(in: Self.projectFolder(of: folder))
        command = project?.command ?? ""
        node = defaultNode ?? NodeLines.fromProject
        projectNode = NodeLines.choose(hint: NodeVersionFiles.hint(from: folder, upTo: folder), installed: model.installedNodeVersions)
        detectWordPress(in: folder)
    }

    // A WordPress folder gets the WordPress values of Settings > Sites, with the rule of nexusd. A
    // folder of many projects keeps the values of a new site, because they apply to each project in
    // it. The WordPress values of a folder before go when the user did not change them.
    private func detectWordPress(in folder: URL) {
        if let wordPress, server == wordPress.server, php == wordPress.php {
            server = model.siteDefaults.server.rawValue
            php = model.defaultPHP
        }

        wordPress = nil
        projectType = nil

        guard folderType == .oneProject else {
            return
        }

        let type = PHPProject.type(of: Self.projectFolder(of: folder))
        projectType = type

        guard type.isWordPress else {
            return
        }

        let values = model.siteDefaults.forWordPress.installed(phpLines: model.installedPHPVersions, hasApache: model.service(ServiceID.apache) != nil)
        let choice = WordPressChoice(type: type, server: (values.server ?? model.siteDefaults.server).rawValue, php: values.php ?? model.defaultPHP)

        server = choice.server
        php = choice.php
        wordPress = choice
    }

    private static func projectFolder(of folder: URL) -> URL {
        URL(filePath: NexusCore.ProjectFolder.projectFolder(ofSiteFolder: folder), directoryHint: .isDirectory)
    }

    private static func suggestedHost(for folder: URL, tld: String) -> String {
        "\(HostName.label(from: folder.lastPathComponent)).\(tld)"
    }

    private func suggestedHost(for folder: URL) -> String {
        Self.suggestedHost(for: folder, tld: tld)
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
        detect(in: chosen)
    }

    // A command that is the same as the script of package.json is no command of the user. So the
    // site follows a later change of package.json.
    private var settings: SiteChange {
        let typed = command.trimmingCharacters(in: .whitespaces)

        return SiteChange(
            node: kind == .node ? node : nil,
            runsAs: kind,
            command: kind == .node && typed != project?.command ? typed : nil,
            address: kind == .proxy ? address.trimmingCharacters(in: .whitespaces) : nil,
            workspaceDatabases: offersEmptyDatabases ? workspaceDatabases : nil
        )
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
                await model.addSite(folder: folder, host: host.trimmingCharacters(in: .whitespaces).lowercased(), aliases: HostList.names(in: aliases), group: group.isEmpty ? nil : group, server: choice, php: kind == .php ? php : nil, settings: settings)
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
