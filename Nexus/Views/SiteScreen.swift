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
    @FocusState private var focusedKeyField: Int?
    @State private var commands: [String]
    @FocusState private var focusedCommand: Int?
    @State private var workspaceProcesses: Bool
    @State private var mainProcesses: Bool
    @State private var preset: [String] = []
    @State private var backgroundCommands: [String]
    @FocusState private var focusedBackgroundCommand: Int?
    @State private var kind: SiteKind
    @State private var appCommand: String
    @State private var address: String
    @FocusState private var focusedKindField: KindField?
    @State private var wordPressInfo: WordPressSiteInfo?
    @State private var asksToAddWorkspaceLines = false
    @State private var workspaceDatabases: WorkspaceDatabaseChoice
    @State private var workspaceSeeders: Bool

    private enum KindField {
        case command
        case address
    }

    init(site: SiteItem) {
        self.site = site
        _kind = State(initialValue: site.kind)
        _appCommand = State(initialValue: site.command ?? site.projectCommand ?? "")
        _address = State(initialValue: site.address ?? "")
        _server = State(initialValue: site.server)
        _php = State(initialValue: site.php)
        _node = State(initialValue: site.nodeSetting ?? NodeLines.fromProject)
        _automaticWorkspaces = State(initialValue: site.automaticWorkspaces)
        _ownKeys = State(initialValue: site.workspaceKeys)
        _commands = State(initialValue: site.workspaceCommands)
        _workspaceProcesses = State(initialValue: site.workspaceProcesses)
        _mainProcesses = State(initialValue: site.mainProcesses)
        _backgroundCommands = State(initialValue: site.backgroundCommands ?? [])
        _workspaceDatabases = State(initialValue: WorkspaceDatabaseChoice(site.workspaceDatabases))
        _workspaceSeeders = State(initialValue: site.workspaceSeeders)
    }

    // The value of Settings > Workspaces, which a site on Default follows.
    private var defaultDatabases: WorkspaceDatabaseKind {
        model.siteList?.newWorkspaceDatabases ?? .copy
    }

    private var newWorkspaceDatabases: WorkspaceDatabaseKind {
        workspaceDatabases.kind ?? defaultDatabases
    }

    private var group: Binding<String> {
        Binding(
            get: { site.group ?? "" },
            set: { model.move(site, toGroup: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        updating(form)
    }

    // The design of a WordPress site is "Site · WordPress" in nexus.pen (Phase 4, 3a).
    private var isWordPress: Bool {
        kind == .php && site.isWordPress
    }

    // A Node.js app and a proxy site have no PHP and no .env. So they get only their own section and,
    // for a Node.js app, the workspaces (D67). A WordPress site has no .env either.
    private var form: some View {
        Form {
            Section {
                LabeledContent("Host") {
                    Text(site.host)
                        .rowValue()
                }
                .labeledContentStyle(.rowValue)

                LabeledContent("Aliases") {
                    HStack {
                        Text(site.aliases.isEmpty ? "None" : site.aliases.joined(separator: ", "))
                            .foregroundStyle(site.aliases.isEmpty ? .tertiary : .secondary)
                            .rowValue()
                            .help(site.aliases.joined(separator: ", "))
                        Button("Edit…") {
                            model.sheet = .editAliases(host: site.host)
                        }
                    }
                }
                .labeledContentStyle(.rowValue)

                Picker("Group", selection: group) {
                    Text("None").tag("")
                    ForEach(model.groupNames, id: \.self) { Text($0).tag($0) }
                }

                Picker("Runs as", selection: $kind) {
                    ForEach(SiteKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }

                if kind == .php, let projectType = site.projectType, projectType != .other {
                    LabeledContent("Project") {
                        Text(projectType.displayName)
                            .foregroundStyle(.secondary)
                            .rowValue()
                    }
                    .labeledContentStyle(.rowValue)
                }

                LabeledContent("Folder") {
                    HStack {
                        PathText(site.folder)
                        Button("Show in Finder") {
                            model.showInFinder(site)
                        }
                    }
                }
                .labeledContentStyle(.rowValue)

                if kind == .php {
                    LabeledContent("Document root") {
                        PathText(site.documentRoot)
                    }
                    .labeledContentStyle(.rowValue)
                }

                LabeledContent("URL") {
                    HStack {
                        if let url = URL(string: site.url) {
                            Link(site.url, destination: url)
                                .foregroundStyle(Color.accentText)
                                .rowValue(.middle)
                                .help(site.url)
                        } else {
                            Text(site.url)
                                .rowValue(.middle)
                        }

                        Button("Copy") {
                            copyToPasteboard(site.url)
                        }
                    }
                }
                .labeledContentStyle(.rowValue)
            } header: {
                Text("General")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = site.problem {
                        MessageText("\(site.host) does not run. \(problem)")
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

            switch kind {
            case .php:
                serverSection

                if site.projectType == .laravel {
                    SiteDatabasesSection(site: site)
                }

                if isWordPress {
                    SiteWordPressSection(site: site, info: $wordPressInfo)
                }
            case .node:
                appSection
            case .proxy:
                proxySection
            }

            if kind != .proxy {
                SiteMailSection(site: site)
                workspacesSection
            }

            if kind == .php {
                phpSections
            }

            // An empty database of a Node.js app gets its tables from a command of the migrations.
            if kind == .node {
                commandsSection
            }
        }
        .formStyle(.grouped)
    }

    private var nodePicker: some View {
        Picker("Node", selection: $node) {
            Text(site.projectNode.map { "\($0.line) (\($0.reason))" } ?? "From the project")
                .tag(NodeLines.fromProject)
            ForEach(nodeChoices, id: \.self) { Text("Node \($0)").tag($0) }
        }
    }

    @ViewBuilder
    private var missingNodeLine: some View {
        if let line = site.node ?? site.projectNode?.line, !model.installedNodeVersions.contains(line) {
            Text("This site needs Node \(line). Install it on the Packages screen.")
                .foregroundStyle(Color.orangeText)
        }
    }

    private var hasAppLog: Bool {
        site.app.map { FileManager.default.fileExists(atPath: $0.log) } ?? false
    }

    private var serverSection: some View {
        Section {
            Picker("Webserver", selection: $server) {
                Text("nginx").tag(WebServer.nginx.rawValue)
                Text("Apache").tag(WebServer.apache.rawValue)
            }

            Picker("PHP", selection: $php) {
                ForEach(phpChoices, id: \.self) { Text("PHP \($0)").tag($0) }
            }

            nodePicker
        } header: {
            Text("Server")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if isWordPress, server == WebServer.apache.rawValue {
                    Text("nginx handles HTTPS for every site and sends each request on to Apache. Apache reads the rules that plugins write into .htaccess.")
                } else {
                    Text("nginx handles HTTPS for every site. For an Apache site, nginx sends each request on to Apache.")
                }

                missingNodeLine
            }
        }
    }

    // The design of this section is "Site · Node app" in nexus.pen (D67).
    private var appSection: some View {
        Section {
            LabeledContent("Framework") {
                Text(site.framework.map { "\($0.displayName) (from package.json)" } ?? "None found")
                    .foregroundStyle(.secondary)
                    .rowValue()
            }
            .labeledContentStyle(.rowValue)

            LabeledContent("Command") {
                CodeField(title: "Command", text: $appCommand, prompt: site.projectCommand ?? "npm run dev", width: 260)
                    .focused($focusedKindField, equals: .command)
                    .onSubmit { saveAppCommand() }
            }

            nodePicker

            LabeledContent("Port") {
                Text(verbatim: site.app?.port.map { "internal \(String($0))" } ?? "Not given yet")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("State") {
                HStack {
                    StatusDot(health: Health(site.app?.state))
                    Text(site.app?.stateText ?? "Not started")
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Button("Show log") {
                        if let log = site.app?.log {
                            NSWorkspace.shared.open(URL(filePath: log))
                        }
                    }
                    .disabled(!hasAppLog)
                    .help(hasAppLog ? "" : "The app has no log yet, because it did not start.")

                    Button("Restart") {
                        Task { await model.restartApp(of: site) }
                    }
                }
            }
        } header: {
            Text("App")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(site.processProblems, id: \.self) { problem in
                    MessageText(problem)
                }

                missingNodeLine

                Text("Nexus starts the command with a free port in PORT. nginx sends \(site.url) to that port with HTTPS. Hot reload also works on this address.")
            }
        }
    }

    // The design of this section is "Site · Proxy" in nexus.pen (D67).
    private var proxySection: some View {
        Section {
            LabeledContent("Address") {
                CodeField(title: "Address", text: $address, prompt: "http://127.0.0.1:3000", width: 260)
                    .focused($focusedKindField, equals: .address)
                    .onSubmit { saveAddress() }
            }
        } header: {
            Text("Proxy")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if site.kind != .proxy {
                    Text("Enter the address of your server, and press Return. \(site.host) then runs as a proxy.")
                }

                Text(SiteKindNote.proxy(url: site.url))
            }
        }
    }

    // The design of a WordPress site is "Site Workspaces Section · WordPress" and "Site Workspaces
    // Section · wp-config.php" in nexus.pen (Phase 4, 3e).
    private var workspacesSection: some View {
        Section {
            Toggle("Create workspaces automatically", isOn: $automaticWorkspaces)
                .toggleStyle(.switch)

            if site.offersEmptyDatabases {
                Picker(selection: $workspaceDatabases) {
                    Text("Default (\(defaultDatabases.displayName.lowercased()))").tag(WorkspaceDatabaseChoice.default)
                    Divider()
                    ForEach(WorkspaceDatabaseKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(WorkspaceDatabaseChoice(kind))
                    }
                } label: {
                    Text("Databases")
                    Text(workspaceDatabases == .default ? "This site follows Settings > Workspaces. When you change that setting, this site changes too." : "This site keeps its own choice. Settings > Workspaces does not change it.")
                }

                if site.projectType == .laravel, newWorkspaceDatabases == .empty {
                    Toggle("Run the seeders", isOn: $workspaceSeeders)
                        .toggleStyle(.switch)
                }
            }

            if isWordPress, let lines = wordPressInfo?.workspaceLines {
                workspaceLinesRow(lines)
            }

            ForEach(site.workspaces) { workspace in
                LabeledContent {
                    HStack {
                        Text(workspace.hosts?.first ?? workspace.folder)
                            .foregroundStyle(.secondary)
                            .rowValue(.middle)

                        if let links = workspace.links, workspace.isolationProblem == nil {
                            linkProgress(links)
                        } else {
                            Text(stateText(of: workspace))
                                .foregroundStyle(workspace.isolationProblem == nil ? Color.secondary : Color.orangeText)
                                .fixedSize(horizontal: true, vertical: false)
                                .id(stateText(of: workspace))
                        }

                        if workspace.isolationProblem != nil || !(workspace.warnings ?? []).isEmpty {
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
                .labeledContentStyle(.rowValue)
                .help((workspace.folder as NSString).abbreviatingWithTildeInPath)
            }
        } header: {
            Text("Workspaces")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = site.workspaceProblem {
                    MessageText(problem)
                }

                ForEach(Array(Set(site.workspaces.compactMap(\.problem))).sorted(), id: \.self) { problem in
                    MessageText(problem)
                }

                // A reason or a warning can name a failed program with its details in errors.log.
                ForEach(site.workspaces) { workspace in
                    if let message = workspace.isolationMessage {
                        MessageText(message, title: "The workspace \(workspace.name) of \(site.host) is not isolated")
                    }

                    ForEach(workspace.warnings ?? [], id: \.self) { warning in
                        MessageText("\(workspace.name): \(warning)", title: "A warning of the workspace \(workspace.name) of \(site.host)")
                    }
                }

                ForEach(site.workspaces.filter { $0.links != nil && $0.isolationProblem == nil }) { workspace in
                    Text(linksText(of: workspace))
                }

                if isWordPress, wordPressInfo?.workspaceLines?.state == .missing {
                    Text("\"Add the lines for workspaces…\" changes \(workspaceLinesFiles) of the main checkout. Commit the change. A worktree of a branch with this commit gets its own database.")
                }

                Text(workspacesNote)
            }
        }
        .sheet(isPresented: $asksToAddWorkspaceLines) {
            if let lines = wordPressInfo?.workspaceLines {
                AddWorkspaceLinesSheet(host: site.host, lines: lines) {
                    Task {
                        if await model.addWordPressWorkspaceLines(site, lines: lines) {
                            wordPressInfo = await model.wordPressSite(of: site)
                        }
                    }
                }
            }
        }
    }

    // A tracked wp-config.php needs lines that load wp-config-nexus.php (Phase 4, 3e).
    @ViewBuilder
    private func workspaceLinesRow(_ lines: WordPressWorkspaceLines) -> some View {
        LabeledContent(lines.configFile) {
            HStack {
                switch lines.state {
                case .missing:
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusOrange)

                        Text(lines.changes.isEmpty ? "wp-config-nexus.php is not in .gitignore" : "Has no lines for workspaces")
                            .foregroundStyle(Color.orangeText)
                    }
                    .rowValue()

                    Button("Add the lines for workspaces…") {
                        asksToAddWorkspaceLines = true
                    }
                    .fixedSize()
                case .uncommitted:
                    Text("The lines for workspaces are not committed yet")
                        .foregroundStyle(.secondary)
                        .rowValue()
                }
            }
        }
        .labeledContentStyle(.rowValue)
    }

    private var workspaceLinesFiles: String {
        guard let lines = wordPressInfo?.workspaceLines else {
            return "wp-config.php"
        }

        return EnglishList.joined([lines.configFile] + (lines.ignoreFile.map { [$0] } ?? []))
    }

    private func linkProgress(_ links: WorkspaceLinkInfo) -> some View {
        HStack(spacing: 8) {
            Text("Changing links")
                .foregroundStyle(.secondary)

            ProgressView(value: links.progress)
                .frame(width: 80)

            Text(links.progress, format: .percent.precision(.fractionLength(0)))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    // A network waits in Preparing for the change of its links. Another site is Ready first.
    private func linksText(of workspace: WorkspaceInfo) -> String {
        guard let links = workspace.links else {
            return ""
        }

        let from = EnglishList.joined(links.from)

        guard workspace.state == .ready else {
            return "Nexus changes the links in the posts of \(workspace.name) from \(from) to \(links.to). A network waits for this change, because WordPress finds its sites by their domain."
        }

        return "\(workspace.name) is ready. Nexus still changes the links in its posts from \(from) to \(links.to). Until then, a link in a post can go to the main site."
    }

    private var workspacesNote: String {
        guard kind == .node else {
            let note = "When git adds a worktree to this site, Nexus makes a workspace for it. This works for every tool that uses git worktrees. When git no longer lists the worktree, Nexus removes the workspace and keeps a dump of its databases in the trash."

            return isWordPress ? "\(note) Each workspace gets its own copy of the database server and its own domain in WordPress. Its plugins and WP-Cron write only into that copy." : note
        }

        return "When git adds a worktree to this site, Nexus makes a workspace for it. Each workspace runs its own copy of the app on its own port and domain."
    }

    @ViewBuilder
    private var phpSections: some View {
        Section {
            Toggle("Run in workspaces", isOn: $workspaceProcesses)
                .toggleStyle(.switch)

            Toggle("Run for the main checkout", isOn: $mainProcesses)
                .toggleStyle(.switch)

            CommandRows(commands: $backgroundCommands, saved: site.backgroundCommands ?? preset, focusedRow: $focusedBackgroundCommand, prompt: isWordPress ? "npm run dev" : "php artisan horizon", save: saveBackgroundCommands)
        } header: {
            Text("Background processes")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(site.processProblems, id: \.self) { problem in
                    MessageText(problem)
                }

                if isWordPress {
                    Text("A WordPress site has no background processes of its own. Add a command, for example npm run dev for the build of a theme.")
                } else {
                    Text("Each workspace runs its own copy of these commands. {port:vite} gets a free port in each workspace. A change saves when you press Return or click outside the field. Existing workspaces then use the new list.")
                }
            }
        }

        if !isWordPress {
            workspaceSetupSections
        }
    }

    // The design of the suggestion is "Site Workspaces Section · Empty database" in nexus.pen.
    private var commandsSection: some View {
        Section {
            if let suggestion = migrationSuggestion {
                HStack {
                    Label("This app uses \(suggestion.contains("prisma") ? "Prisma" : "Drizzle Kit"). An empty database gets its tables from \(suggestion).", systemImage: "lightbulb")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Add") {
                        commands = completeCommands + [suggestion]
                        saveCommands()
                    }
                }
            }

            CommandRows(commands: $commands, saved: site.workspaceCommands, focusedRow: $focusedCommand, prompt: kind == .node ? "npx prisma migrate deploy" : "php artisan tenant:domain shop-{workspace}.test", save: saveCommands)
        } header: {
            Text("Commands after database clone")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if migrationSuggestion != nil {
                    Text("Without such a command, the databases of a new workspace stay without tables.")
                }

                Text("Nexus runs these commands in a new workspace after it clones the databases. A change saves when you press Return or click outside the field. Existing workspaces do not run the change. The commands can use {workspace}, {host}, {database} and {port:<name>}. Nexus adds the quotes that {database} needs. A database has the same name as on the main site. So a command that connects itself needs {port:database}, the port of the database server of the workspace.")
            }
        }
    }

    // A Node.js app with Prisma or Drizzle Kit and an empty database (step 3 of the order of the work).
    private var migrationSuggestion: String? {
        guard kind == .node, newWorkspaceDatabases == .empty, let command = site.migrationCommand, !site.workspaceCommands.contains(command) else {
            return nil
        }

        return command
    }

    @ViewBuilder
    private var workspaceSetupSections: some View {
        commandsSection

        Section {
            ForEach(nexusKeys.filter { entry in !ownKeys.contains { $0.key == entry.key } }, id: \.key) { entry in
                LabeledContent {
                    Text(entry.value)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                        .rowValue(.middle)
                        .help(entry.value)
                } label: {
                    Text(entry.key)
                        .font(.system(.body, design: .monospaced))
                }
                .labeledContentStyle(.rowValue)
            }

            ForEach(ownKeys.indices, id: \.self) { index in
                HStack {
                    TextField("Key", text: ownKey(at: index, \.key), prompt: Text("KEY"))
                        .labelsHidden()
                        .plainTextInput()
                        .focused($focusedKeyField, equals: index * 2)
                        .onSubmit { saveOwnKeys() }

                    TextField("Value", text: ownKey(at: index, \.value), prompt: Text("{port:name}"))
                        .labelsHidden()
                        .plainTextInput()
                        .focused($focusedKeyField, equals: index * 2 + 1)
                        .onSubmit { saveOwnKeys() }

                    RowSaveState(isSaved: isKeySaved(at: index))

                    RowRemoveButton(help: "Remove key") {
                        ownKeys.remove(at: index)
                        saveOwnKeys()
                    }
                }
                .font(.system(.body, design: .monospaced))
            }

            Button("Add a key") {
                ownKeys.append(WorkspaceEnvKey(key: "", value: ""))
            }
            .trailingInRow()
        } header: {
            Text("Environment keys")
        } footer: {
            Text("Nexus writes these keys to the .env of each workspace. The .env of the main checkout does not change. A change saves when you press Return or click outside the field. Existing workspaces then get the change. Your keys can use {workspace}, {host}, {database} and {port:<name>}.")
        }
    }

    private func updating(_ form: some View) -> some View {
        form
        // A move between the two fields of one row also saves. A new row without a key is no
        // key for nexusd yet, so that save does nothing.
        .onChange(of: focusedKeyField) { old, _ in
            if old != nil {
                saveOwnKeys()
            }
        }
        .onChange(of: focusedCommand) { old, _ in
            if old != nil {
                saveCommands()
            }
        }
        .onChange(of: focusedBackgroundCommand) { old, _ in
            if old != nil {
                saveBackgroundCommands()
            }
        }
        .onDisappear {
            guard model.site(site.host) != nil else {
                return
            }

            saveOwnKeys()
            saveCommands()
            saveBackgroundCommands()
            saveAppCommand()
            saveAddress()
        }
        .task(id: EnvPreviewSource(keys: site.workspaceKeys, commands: site.workspaceCommands, backgroundCommands: site.backgroundCommands)) {
            nexusKeys = await model.workspaceEnv(of: site)
        }
        .task(id: site.backgroundCommands == nil) {
            guard site.backgroundCommands == nil else {
                return
            }

            let commands = await model.backgroundPreset(of: site)

            guard !Task.isCancelled else {
                return
            }

            preset = commands

            // The probe can take seconds, and the user can type a command in that time.
            if completeBackgroundCommands.isEmpty {
                backgroundCommands = commands
            }
        }
        .screenTitle(site.host, subtitle: subtitle)
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
            workspaceProcesses = site.workspaceProcesses
            mainProcesses = site.mainProcesses
            workspaceDatabases = WorkspaceDatabaseChoice(site.workspaceDatabases)
            workspaceSeeders = site.workspaceSeeders
        }
        .onChange(of: workspaceDatabases) {
            guard workspaceDatabases != WorkspaceDatabaseChoice(site.workspaceDatabases) else {
                return
            }

            change(SiteChange(workspaceDatabases: workspaceDatabases)) { workspaceDatabases = WorkspaceDatabaseChoice(site.workspaceDatabases) }
        }
        .onChange(of: workspaceSeeders) {
            guard workspaceSeeders != site.workspaceSeeders else {
                return
            }

            change(SiteChange(workspaceSeeders: workspaceSeeders)) { workspaceSeeders = site.workspaceSeeders }
        }
        // A move to the next field saves, and the answer of nexusd comes while the user types
        // there. So a list with the focus keeps the text of the user.
        .onChange(of: site.workspaceKeys) {
            if focusedKeyField == nil, site.workspaceKeys != completeKeys {
                ownKeys = site.workspaceKeys
            }
        }
        .onChange(of: site.workspaceCommands) {
            if focusedCommand == nil, site.workspaceCommands != completeCommands {
                commands = site.workspaceCommands
            }
        }
        .onChange(of: site.backgroundCommands) {
            if focusedBackgroundCommand == nil, let current = site.backgroundCommands, current != completeBackgroundCommands {
                backgroundCommands = current
            }
        }
        .onChange(of: workspaceProcesses) {
            guard workspaceProcesses != site.workspaceProcesses else {
                return
            }

            change(SiteChange(workspaceProcesses: workspaceProcesses)) { workspaceProcesses = site.workspaceProcesses }
        }
        .onChange(of: mainProcesses) {
            guard mainProcesses != site.mainProcesses else {
                return
            }

            change(SiteChange(mainProcesses: mainProcesses)) { mainProcesses = site.mainProcesses }
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
        .onChange(of: site.kind) {
            kind = site.kind
        }
        // A field that the user types in keeps the text of the user.
        .onChange(of: site.command) {
            if focusedKindField != .command {
                appCommand = site.command ?? site.projectCommand ?? ""
            }
        }
        .onChange(of: site.projectCommand) {
            if focusedKindField != .command {
                appCommand = site.command ?? site.projectCommand ?? ""
            }
        }
        .onChange(of: site.address) {
            if focusedKindField != .address {
                address = site.address ?? ""
            }
        }
        // A proxy site needs its address first. So the choice of a proxy waits for that address. The
        // Address field comes in this update, so it gets the focus in the next one.
        .onChange(of: kind) {
            guard kind != site.kind else {
                return
            }

            guard kind != .proxy || site.address != nil else {
                Task { focusedKindField = .address }
                return
            }

            change(SiteChange(runsAs: kind)) { kind = site.kind }
        }
        .onChange(of: focusedKindField) { old, _ in
            if old == .command {
                saveAppCommand()
            }

            if old == .address {
                saveAddress()
            }
        }
    }

    private var subtitle: String {
        switch kind {
        case .php where isWordPress:
            "\(site.projectType?.displayName ?? "WordPress") · \((WebServer(rawValue: server) ?? .nginx).displayName) · PHP \(php)"
        case .php:
            "\((WebServer(rawValue: server) ?? .nginx).displayName) · PHP \(php)"
        case .node:
            "\(site.framework?.displayName ?? SiteKind.node.displayName) · Node \(site.node ?? site.projectNode?.line ?? "from the project")"
        case .proxy:
            "Proxy to \(site.address.map(SiteKindNote.shortAddress) ?? "a port")"
        }
    }

    // An empty command, or the script of package.json, makes the site follow package.json again.
    private func saveAppCommand() {
        let typed = appCommand.trimmingCharacters(in: .whitespaces)
        let saved = site.command ?? site.projectCommand ?? ""

        guard site.kind == .node, typed != saved else {
            return
        }

        let value = typed.isEmpty || typed == site.projectCommand ? Site.commandFromProject : typed

        change(SiteChange(command: value)) { appCommand = saved }
    }

    // The first address of a site that runs as another kind also makes it a proxy site.
    private func saveAddress() {
        let typed = address.trimmingCharacters(in: .whitespaces)

        guard kind == .proxy, !typed.isEmpty, typed != site.address || site.kind != .proxy else {
            return
        }

        change(SiteChange(runsAs: .proxy, address: typed)) { address = site.address ?? "" }
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
            "Preparing"
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

    // SwiftUI can ask for a row that the user just removed.
    private func isKeySaved(at index: Int) -> Bool {
        guard ownKeys.indices.contains(index), !ownKeys[index].key.isEmpty || !ownKeys[index].value.isEmpty else {
            return true
        }

        return site.workspaceKeys.contains(ownKeys[index])
    }

    // A new row without a key stays on the screen, and it is no key for nexusd yet.
    private var completeKeys: [WorkspaceEnvKey] {
        ownKeys.filter { !$0.key.isEmpty }
    }

    // A new row without text stays on the screen, and it is no command for nexusd yet.
    private var completeCommands: [String] {
        CommandRows.complete(commands)
    }

    private var completeBackgroundCommands: [String] {
        CommandRows.complete(backgroundCommands)
    }

    private func saveCommands() {
        guard completeCommands != site.workspaceCommands else {
            return
        }

        change(SiteChange(workspaceCommands: completeCommands)) { commands = site.workspaceCommands }
    }

    // A site follows the preset until the user changes the list. A preset that did not arrive yet
    // is no change.
    private func saveBackgroundCommands() {
        guard completeBackgroundCommands != site.backgroundCommands ?? preset else {
            return
        }

        change(SiteChange(backgroundCommands: completeBackgroundCommands)) { backgroundCommands = site.backgroundCommands ?? preset }
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

// A {port:reverb} in a command adds the Reverb keys to the .env of a workspace.
private struct EnvPreviewSource: Equatable {
    let keys: [WorkspaceEnvKey]
    let commands: [String]
    let backgroundCommands: [String]?
}

private struct CommandRows: View {
    @Binding var commands: [String]
    let saved: [String]
    let focusedRow: FocusState<Int?>.Binding
    let prompt: String
    let save: () -> Void

    static func complete(_ commands: [String]) -> [String] {
        commands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        ForEach(commands.indices, id: \.self) { index in
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)

                TextField("Command", text: command(at: index), prompt: Text(prompt))
                    .labelsHidden()
                    .plainTextInput()
                    .focused(focusedRow, equals: index)
                    .onSubmit { save() }

                RowSaveState(isSaved: isSaved(command(at: index).wrappedValue))

                RowRemoveButton(help: "Remove command") {
                    commands.remove(at: index)
                    save()
                }
            }
            .font(.system(.body, design: .monospaced))
        }

        Button("Add a command") {
            commands.append("")
        }
        .trailingInRow()
    }

    // A new row without text is no command for nexusd yet.
    private func isSaved(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || saved.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }

    private func command(at index: Int) -> Binding<String> {
        Binding {
            commands.indices.contains(index) ? commands[index] : ""
        } set: { text in
            if commands.indices.contains(index) {
                commands[index] = text
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
    @State private var errorReport: ErrorReport?

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

            Text("Separate the names with a comma or a space, for example www.\(site.host), \(site.host.split(separator: ".").first ?? "site").local. A name that starts with *. covers each name below it, for example *.\(site.host). It works only in the dev domain. A name outside the dev domain gets a line in /etc/hosts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                FailureLabel(message: failure) { errorReport = $0 }
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
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
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
