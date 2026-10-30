import NexusCore
import NexusIPC
import SwiftUI

// A picker keeps the new value while nexusd works. A refused change shows the old value again.
// The event of nexusd then gives the new site, and the pickers follow it.
struct SiteScreen: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    @State private var server: String
    @State private var php: String
    @State private var node: String
    @State private var automaticWorkspaces: Bool
    @State private var nexusKeys: [WorkspaceEnvKey] = []
    @State private var ownKeys: [WorkspaceEnvKey]

    init(site: SiteItem) {
        self.site = site
        _server = State(initialValue: site.server)
        _php = State(initialValue: site.php)
        _node = State(initialValue: site.nodeSetting ?? NodeLines.fromProject)
        _automaticWorkspaces = State(initialValue: site.automaticWorkspaces)
        _ownKeys = State(initialValue: site.workspaceKeys)
    }

    private var group: Binding<String> {
        Binding(
            get: { site.group ?? "" },
            set: { model.move(site, toGroup: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Host") {
                    Text(site.host)
                }

                LabeledContent("Aliases") {
                    HStack {
                        Text(site.aliases.isEmpty ? "None" : site.aliases.joined(separator: ", "))
                            .foregroundStyle(site.aliases.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                        Button("Edit…") {
                            model.sheet = .editAliases(host: site.host)
                        }
                    }
                }

                Picker("Group", selection: group) {
                    Text("None").tag("")
                    ForEach(model.groupNames, id: \.self) { Text($0).tag($0) }
                }

                LabeledContent("Folder") {
                    HStack {
                        PathText(site.folder)
                        Button("Show in Finder") {
                            model.showInFinder(site)
                        }
                    }
                }

                LabeledContent("Document root") {
                    PathText(site.documentRoot)
                }

                LabeledContent("URL") {
                    HStack {
                        if let url = URL(string: site.url) {
                            Link(site.url, destination: url)
                                .foregroundStyle(Color.accentText)
                        } else {
                            Text(site.url)
                        }

                        Button("Copy") {
                            copyToPasteboard(site.url)
                        }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = site.problem {
                        Text("\(site.host) does not run. \(problem)")
                            .foregroundStyle(Color.orangeText)
                    }

                    if let parkedFolder = site.parkedFolder, site.hasOwnSettings {
                        Text("This project is in the folder of projects \(parkedFolder), and it has settings of its own. \"Remove site\" removes them, and the project gets the settings of the folder again.")
                    } else if let parkedFolder = site.parkedFolder {
                        Text("This site comes from the folder of projects \(parkedFolder). Remove or rename its folder there to remove the site or to change its host.")
                    }

                    if let protectedFolder = site.protectedFolder {
                        Text(ProtectedFolder.explanation(protectedFolder))
                    }
                }
            }

            Section {
                Picker("Webserver", selection: $server) {
                    Text("nginx").tag(WebServer.nginx.rawValue)
                    Text("Apache").tag(WebServer.apache.rawValue)
                }

                Picker("PHP", selection: $php) {
                    ForEach(phpChoices, id: \.self) { Text("PHP \($0)").tag($0) }
                }

                Picker("Node", selection: $node) {
                    Text(site.projectNode.map { "\($0.line) (\($0.reason))" } ?? "From the project")
                        .tag(NodeLines.fromProject)
                    ForEach(nodeChoices, id: \.self) { Text("Node \($0)").tag($0) }
                }
            } header: {
                Text("Server")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("nginx handles HTTPS for every site. For an Apache site, nginx sends each request on to Apache.")

                    if let line = site.node, !model.installedNodeVersions.contains(line) {
                        Text("nexus node and nexus npm need Node \(line) for this site. Install it on the Packages screen.")
                            .foregroundStyle(Color.orangeText)
                    }
                }
            }

            Section {
                Toggle("Create workspaces automatically", isOn: $automaticWorkspaces)
                    .toggleStyle(.switch)

                ForEach(site.workspaces) { workspace in
                    LabeledContent {
                        HStack {
                            Text(workspace.hosts?.first ?? workspace.folder)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(stateText(of: workspace))
                                .foregroundStyle(workspace.isolationProblem == nil ? Color.secondary : Color.orangeText)

                            if workspace.isolationProblem != nil {
                                Button("Retry") {
                                    Task { await model.retry(workspace, of: site) }
                                }
                            }

                            if let url = workspace.url {
                                Button("Open") {
                                    model.openInBrowser(url)
                                }
                            }
                        }
                    } label: {
                        Label(workspace.name, systemImage: "arrow.triangle.branch")
                    }
                    .help((workspace.folder as NSString).abbreviatingWithTildeInPath)
                }
            } header: {
                Text("Workspaces")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = site.workspaceProblem {
                        Text(problem)
                            .foregroundStyle(Color.orangeText)
                    }

                    ForEach(Array(Set(site.workspaces.compactMap(\.problem))).sorted(), id: \.self) { problem in
                        Text(problem)
                            .foregroundStyle(Color.orangeText)
                    }

                    ForEach(site.workspaces.filter { $0.isolationProblem != nil }) { workspace in
                        Text("\(workspace.name) is not isolated: \(workspace.isolationProblem ?? "")")
                            .foregroundStyle(Color.orangeText)
                    }

                    Text("When git adds a worktree to this site, Nexus makes a workspace for it. This works for every tool that uses git worktrees. When git no longer lists the worktree, Nexus removes the workspace.")
                }
            }

            Section {
                ForEach(nexusKeys.filter { entry in !ownKeys.contains { $0.key == entry.key } }, id: \.key) { entry in
                    LabeledContent {
                        Text(entry.value)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Text(entry.key)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                ForEach(ownKeys.indices, id: \.self) { index in
                    HStack {
                        TextField("Key", text: ownKey(at: index, \.key), prompt: Text("KEY"))
                            .labelsHidden()
                            .plainTextInput()
                            .onSubmit { saveOwnKeys() }

                        TextField("Value", text: ownKey(at: index, \.value), prompt: Text("{port:name}"))
                            .labelsHidden()
                            .plainTextInput()
                            .onSubmit { saveOwnKeys() }

                        Button("Remove", systemImage: "minus") {
                            ownKeys.remove(at: index)
                            saveOwnKeys()
                        }
                        .labelStyle(.iconOnly)
                    }
                    .font(.system(.body, design: .monospaced))
                }

                Button("Add a key") {
                    ownKeys.append(WorkspaceEnvKey(key: "", value: ""))
                }
            } header: {
                Text("Environment keys")
            } footer: {
                Text("Nexus writes these keys to the .env of each workspace. The .env of the main checkout does not change. Your keys can use {workspace}, {host}, {database} and {port:<name>}.")
            }
        }
        .formStyle(.grouped)
        .task(id: site.workspaceKeys) {
            nexusKeys = await model.workspaceEnv(of: site)
        }
        .screenTitle(site.host, subtitle: "\((WebServer(rawValue: server) ?? .nginx).displayName) · PHP \(php)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openInBrowser(site)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                .labelStyle(.titleAndIcon)
            }

            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    SiteActions(site: site, includeBrowser: false)
                }
            }
        }
        .onChange(of: site) {
            server = site.server
            php = site.php
            node = site.nodeSetting ?? NodeLines.fromProject
            automaticWorkspaces = site.automaticWorkspaces
        }
        .onChange(of: site.workspaceKeys) {
            if site.workspaceKeys != completeKeys {
                ownKeys = site.workspaceKeys
            }
        }
        .onChange(of: automaticWorkspaces) {
            guard automaticWorkspaces != site.automaticWorkspaces else {
                return
            }

            change(SiteChange(automaticWorkspaces: automaticWorkspaces)) { automaticWorkspaces = site.automaticWorkspaces }
        }
        .onChange(of: server) {
            guard server != site.server, let choice = WebServer(rawValue: server) else {
                return
            }

            change(SiteChange(server: choice)) { server = site.server }
        }
        .onChange(of: php) {
            guard php != site.php else {
                return
            }

            change(SiteChange(php: php)) { php = site.php }
        }
        .onChange(of: node) {
            let current = site.nodeSetting ?? NodeLines.fromProject

            guard node != current else {
                return
            }

            change(SiteChange(node: node)) { node = current }
        }
    }

    // A site keeps a PHP version that is not installed anymore, so the picker shows it.
    private var phpChoices: [String] {
        model.installedPHPVersions.contains(site.php) ? model.installedPHPVersions : [site.php] + model.installedPHPVersions
    }

    // A chosen Node line that is not installed anymore stays in the picker too.
    private var nodeChoices: [String] {
        let installed = model.installedNodeVersions

        guard let chosen = site.nodeSetting, !installed.contains(chosen) else {
            return installed
        }

        return [chosen] + installed
    }

    private func stateText(of workspace: WorkspaceInfo) -> String {
        switch workspace.state {
        case .ready:
            "Ready"
        case .notIsolated:
            "Not isolated"
        case .preparing, nil:
            model.copyProgress(of: workspace).map { "Copying databases \($0)%" } ?? "Preparing"
        }
    }

    // A text field can read its row once more after the row goes away.
    private func ownKey(at index: Int, _ field: WritableKeyPath<WorkspaceEnvKey, String>) -> Binding<String> {
        Binding {
            ownKeys.indices.contains(index) ? ownKeys[index][keyPath: field] : ""
        } set: { text in
            if ownKeys.indices.contains(index) {
                ownKeys[index][keyPath: field] = text
            }
        }
    }

    // A new row without a key stays on the screen, and it is no key for nexusd yet.
    private var completeKeys: [WorkspaceEnvKey] {
        ownKeys.filter { !$0.key.isEmpty }
    }

    private func saveOwnKeys() {
        guard completeKeys != site.workspaceKeys else {
            return
        }

        change(SiteChange(workspaceKeys: completeKeys)) { ownKeys = site.workspaceKeys }
    }

    private func change(_ change: SiteChange, revert: @escaping () -> Void) {
        Task {
            if await !model.editSite(site, change) {
                revert()
            }
        }
    }
}

struct EditAliasesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let site: SiteItem

    @State private var aliases: String
    @State private var saving = false
    @State private var failure: String?

    init(site: SiteItem) {
        self.site = site
        _aliases = State(initialValue: site.aliases.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aliases of \(site.host)")
                .font(.headline)

            TextField("Aliases", text: $aliases, prompt: Text("None"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .plainTextInput()

            Text("Separate the names with a comma or a space, for example www.\(site.host), \(site.host.split(separator: ".").first ?? "site").local. A name outside the dev domain gets a line in /etc/hosts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Label(failure, systemImage: "xmark.circle")
                    .foregroundStyle(Color.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                if saving {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let names = HostList.names(in: aliases)

        // An edit of a site of a parked folder gives it settings of its own. So a save without a
        // change sends nothing.
        guard names != site.aliases else {
            dismiss()
            return
        }

        saving = true

        Task {
            failure = await model.failureOfEdit(site, SiteChange(aliases: names))
            saving = false

            if failure == nil {
                dismiss()
            }
        }
    }
}

enum HostList {
    static func names(in text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map { $0.lowercased() }
    }
}
