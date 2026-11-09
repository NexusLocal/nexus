import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// A new site from a template (Phase 4, 3m). The design is "Sheet New Site · Laravel", "·
// WordPress", "· Node.js", "· Progress", "· Failed", "· Done · WordPress" and "· States". While the
// site is made, the sheet shows its steps and its log. The user can close the sheet, and nexusd
// goes on.
struct NewSiteSheet: View {
    static let templateKey = "newSiteTemplate"

    @Environment(AppModel.self) private var model

    // The import of a backup (3f) uses this sheet with its own form and its own end.
    var importing = false
    var backup: URL?

    var body: some View {
        Group {
            let run = model.newSiteRun

            switch run?.result {
            case .created(let created):
                if run?.importing != nil {
                    ImportDoneView(created: created)
                } else {
                    NewSiteDoneView(created: created)
                }
            case .failed(let failure):
                NewSiteFailedView(failure: failure)
            case .refused(let message):
                form(refusal: message, run: run)
            case .stopped:
                form(refusal: nil, run: run)
            case nil:
                if let run {
                    NewSiteProgressView(run: run)
                } else {
                    form(refusal: nil, run: nil)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: endOtherRun)
    }

    // The kind of the sheet chooses the form. The values of a stopped or refused run come back only
    // in a form of its own kind, and for an import only with its own backup.
    @ViewBuilder
    private func form(refusal: String?, run: NewSiteRun?) -> some View {
        let own = run.flatMap(isOwn)

        if importing {
            ImportSiteForm(refusal: own == nil ? nil : refusal, request: own?.importing, backup: backup)
        } else {
            NewSiteForm(refusal: own == nil ? nil : refusal, site: own?.site)
        }
    }

    private func isOwn(_ run: NewSiteRun) -> NewSiteRun? {
        guard (run.importing != nil) == importing else {
            return nil
        }

        guard let backup, let request = run.importing else {
            return run
        }

        return URL(filePath: request.backup).standardizedFileURL.pathComponents == backup.standardizedFileURL.pathComponents ? run : nil
    }

    private func endOtherRun() {
        guard let run = model.newSiteRun, isOwn(run) == nil else {
            return
        }

        switch run.result {
        case .stopped, .refused:
            model.newSiteRun = nil
        default:
            break
        }
    }
}

// A name that is no valid name of a new site, or whose folder exists already.
func newSiteNameProblem(_ name: String, in folder: URL?) -> String? {
    guard !name.isEmpty else {
        return nil
    }

    do {
        _ = try NewSiteName.validated(name)
    } catch {
        return ErrorText.plain(error)
    }

    if let target = folder?.appending(path: name, directoryHint: .isDirectory), FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
        return "\(shortPath(target)) exists. Choose another name or another folder."
    }

    return nil
}

func shortPath(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
}

private struct NewSiteForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage("newSiteFolder") private var savedFolder = ""
    @AppStorage(NewSiteSheet.templateKey) private var savedTemplate = SiteTemplate.laravel.rawValue

    @State private var template: SiteTemplate
    @State private var name = ""
    @State private var folder: URL?
    @State private var git = true
    @State private var starterKit = LaravelStarterKit.none
    @State private var authentication = LaravelAuthentication.builtIn
    @State private var teams = false
    @State private var tests = LaravelTests.pest
    @State private var boost = true
    @State private var database = ""
    @State private var databaseChosen = false
    @State private var php = ""
    @State private var locale = WordPressLocale.english
    @State private var adminUser = "admin"
    @State private var adminEmail = ""
    @State private var network: WordPressNetworkKind?
    @State private var framework = ViteFramework.react
    @State private var packageManager = PackageManager.npm
    @State private var node = ""
    @State private var errorReport: ErrorReport?

    let refusal: String?

    private let locales = WordPressLocale.choices(preferred: Locale.preferredLanguages)

    // The sheet starts at the template of the last new site.
    init(refusal: String?, site: NewSite?) {
        self.refusal = refusal

        guard let site else {
            let saved = UserDefaults.standard.string(forKey: NewSiteSheet.templateKey)
            _template = State(initialValue: saved.flatMap(SiteTemplate.init(rawValue:)) ?? .laravel)
            return
        }

        _template = State(initialValue: site.template)
        _name = State(initialValue: site.name)
        _folder = State(initialValue: URL(filePath: site.parent, directoryHint: .isDirectory))
        _git = State(initialValue: site.git)
        _starterKit = State(initialValue: site.starterKit)
        _authentication = State(initialValue: site.authentication)
        _teams = State(initialValue: site.teams)
        _tests = State(initialValue: site.tests)
        _boost = State(initialValue: site.boost)
        _database = State(initialValue: site.database ?? "")
        _databaseChosen = State(initialValue: true)
        _php = State(initialValue: site.php ?? "")
        _locale = State(initialValue: site.locale)
        _adminUser = State(initialValue: site.adminUser)
        _adminEmail = State(initialValue: site.adminEmail)
        _network = State(initialValue: site.network)
        _framework = State(initialValue: site.framework)
        _packageManager = State(initialValue: site.packageManager)
        _node = State(initialValue: site.node ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New site")
                .font(.headline)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: SiteTemplate.allCases.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(SiteTemplate.allCases[start..<min(start + 3, SiteTemplate.allCases.count)], id: \.self) { choice in
                            TemplateCard(template: choice, selected: template == choice) {
                                template = choice
                            }
                        }
                    }
                }
            }

            Form {
                Section {
                    LabeledContent("Name") {
                        CodeField(title: "Name", text: $name, prompt: "shop")
                    }

                    LabeledContent("Folder") {
                        HStack {
                            PathText(folder.map(shortPath) ?? "")
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    .labeledContentStyle(.rowValue)

                    Toggle("Git repository", isOn: $git)
                        .toggleStyle(.switch)
                } footer: {
                    if let nameProblem {
                        Text(nameProblem)
                            .foregroundStyle(Color.redText)
                    } else {
                        Text(siteFooter)
                    }
                }

                Section {
                    templateRows
                } header: {
                    Text(template.displayName)
                } footer: {
                    Text(templateFooter)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            if let refusal {
                FailureLabel(message: refusal) { errorReport = $0 }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    model.endNewSite()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create site", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
        .onAppear(perform: chooseDefaults)
        // The sheet can open before the app knows the services and the packages, for example at
        // launch. A value that the user chose in that time stays.
        .onChange(of: model.databaseInstances.map(\.id), chooseDefaults)
        .onChange(of: model.installedPHPVersions, chooseDefaults)
        .onChange(of: model.installedNodeVersions, chooseDefaults)
        .onChange(of: template) {
            let keepsSQLite = template == .laravel && database.isEmpty

            if !keepsSQLite, !databases.contains(where: { $0.id == database }) {
                chooseDatabase()
            }
        }
    }

    @ViewBuilder
    private var templateRows: some View {
        switch template {
        case .laravel:
            Picker("Starter kit", selection: $starterKit) {
                ForEach(LaravelStarterKit.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }

            if starterKit != .none {
                Picker("Authentication", selection: $authentication) {
                    ForEach(LaravelAuthentication.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }

                Toggle("Teams", isOn: $teams)
                    .toggleStyle(.switch)
            }

            Picker("Tests", selection: $tests) {
                ForEach(LaravelTests.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }

            Toggle(isOn: $boost) {
                HStack(spacing: 6) {
                    Text("Laravel Boost")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                .help("Laravel Boost gives an AI coding agent the documentation and the tools of this Laravel version.")
            }
            .toggleStyle(.switch)

            databasePicker

            if laravelPHPVersions.isEmpty {
                LabeledContent("PHP") {
                    HStack {
                        Text("Laravel 13 needs PHP 8.3 or newer")
                            .foregroundStyle(Color.orangeText)
                        installButton("php", line: "8.5", title: "Install PHP 8.5")
                    }
                }
            } else {
                Picker("PHP", selection: $php) {
                    ForEach(laravelPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                }
            }
        case .wordpress:
            Picker("Language", selection: $locale) {
                ForEach(locales) { Text($0.displayName).tag($0.code) }
            }

            LabeledContent("Admin user") {
                CodeField(title: "Admin user", text: $adminUser)
            }

            LabeledContent("Admin email") {
                CodeField(title: "Admin email", text: $adminEmail, prompt: "admin@\(host)")
            }

            Picker("Network", selection: $network) {
                Text("No network").tag(WordPressNetworkKind?.none)
                Text("Network on subfolders").tag(WordPressNetworkKind?.some(.subfolders))
                Text("Network on subdomains").tag(WordPressNetworkKind?.some(.subdomains))
            }

            databasePicker
        case .next, .nuxt, .vite, .astro:
            if template == .vite {
                Picker("Framework", selection: $framework) {
                    ForEach(ViteFramework.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Picker("Package manager", selection: $packageManager) {
                ForEach([PackageManager.npm, .pnpm, .yarn], id: \.self) { Text($0.rawValue).tag($0) }
            }

            if model.installedNodeVersions.isEmpty {
                LabeledContent("Node") {
                    HStack {
                        Text("Not installed")
                            .foregroundStyle(Color.orangeText)
                        installButton("node", line: "24", title: "Install Node 24")
                    }
                }
            } else {
                Picker("Node", selection: $node) {
                    ForEach(nodeVersions, id: \.self) { line in
                        Text(line == nodeVersions.first ? "\(line) (newest)" : line).tag(line)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var databasePicker: some View {
        if databases.isEmpty, template == .wordpress {
            LabeledContent("Database") {
                HStack {
                    Text("WordPress needs MySQL or MariaDB")
                        .foregroundStyle(Color.orangeText)
                    installButton("mysql", line: "8.4", title: "Install MySQL 8.4")
                }
            }
        } else {
            Picker("Database", selection: $database) {
                ForEach(databases) { Text($0.name).tag($0.id) }

                if template == .laravel {
                    Text("SQLite").tag("")
                }
            }
        }
    }

    private func installButton(_ package: String, line: String, title: String) -> some View {
        let item = model.packages.first { $0.package == package && $0.line == line }
        let downloading = model.tasks.contains { task in
            if case .install(let name, let taskLine, _, _) = task.work {
                return name == package && taskLine == line
            }

            return false
        }

        return Button(downloading ? "Installing…" : title) {
            if let item {
                model.install(item)
            }
        }
        .disabled(item == nil || downloading)
    }

    private var host: String {
        "\(name.isEmpty ? "shop" : name).\(model.settings.tld)"
    }

    private var finalFolder: URL? {
        folder?.appending(path: name.isEmpty ? "shop" : name, directoryHint: .isDirectory)
    }

    private var nameProblem: String? {
        newSiteNameProblem(name, in: folder)
    }

    private var siteFooter: String {
        let place = finalFolder.map(shortPath) ?? "the folder"
        let opens = "Nexus makes the folder \(place) and opens the site on \(model.newSiteURL(host: host))."

        guard git else {
            return opens
        }

        return template == .wordpress
            ? "\(opens) The repository ignores wp-config.php and the uploads, so workspaces work at once."
            : "\(opens) Workspaces need git, so the site gets a repository with a first commit."
    }

    private var templateFooter: String {
        let url = model.newSiteURL(host: host)
        let manager = packageManager.rawValue

        switch template {
        case .laravel:
            guard let instance = model.service(database) else {
                return "laravel new 5.32 runs with these choices. The database is a SQLite file in the project."
            }

            return "Nexus makes the database \(databaseName) on \(instance.name) first. Then laravel new 5.32 runs with these choices, and its migrations go into that database."
        case .wordpress:
            let values = model.siteDefaults.forWordPress.installed(phpLines: model.installedPHPVersions, hasApache: model.service(ServiceID.apache) != nil)
            let server = (values.server ?? model.siteDefaults.server).displayName
            let php = values.php ?? model.defaultPHP

            return "The site gets \(server) and PHP \(php). Nexus makes a strong password for the admin user and shows it one time at the end."
        case .vite:
            return "Nexus runs create-vite 9 with the template \(framework.rawValue)-ts, then \(manager) install. After that it starts \(manager) run dev and sends \(url) to it."
        case .next, .nuxt, .astro:
            let creator = (template.creator ?? "").replacingOccurrences(of: "@", with: " ")
            return "Nexus runs \(creator), then \(manager) install. After that it starts \(manager) run dev and sends \(url) to it."
        }
    }

    private var databaseName: String {
        NewSiteName.databaseBase(of: name.isEmpty ? "shop" : name)
    }

    private var databases: [ServiceVersion] {
        model.databaseInstances.filter { template == .laravel || $0.kind == .mysql || $0.kind == .mariadb }
    }

    private var laravelPHPVersions: [String] {
        model.installedPHPVersions
            .filter { !VersionLine.isOlder($0, than: "8.3") }
            .sorted { VersionLine.isOlder($1, than: $0) }
    }

    private var nodeVersions: [String] {
        model.installedNodeVersions.reversed()
    }

    private var canCreate: Bool {
        guard !name.isEmpty, nameProblem == nil, folder != nil else {
            return false
        }

        switch template {
        case .laravel:
            return !php.isEmpty
        case .wordpress:
            return !database.isEmpty && !adminUser.isEmpty
        case .next, .nuxt, .vite, .astro:
            return !node.isEmpty
        }
    }

    private func chooseDefaults() {
        if folder == nil {
            let saved = savedFolder.isEmpty ? nil : URL(filePath: savedFolder, directoryHint: .isDirectory)
            folder = saved.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil } ?? model.newSiteFolders.first
        }

        if !laravelPHPVersions.contains(php) {
            php = laravelPHPVersions.first ?? ""
        }

        if !nodeVersions.contains(node) {
            node = nodeVersions.first ?? ""
        }

        if !locales.contains(where: { $0.code == locale }) {
            locale = locales.first?.code ?? WordPressLocale.english
        }

        if !databaseChosen, !databases.isEmpty {
            chooseDatabase()
        }
    }

    // MySQL 8.4 first, as for "Set up WordPress" (owner, 2026-11-06).
    private func chooseDatabase() {
        databaseChosen = true
        let running = databases.filter(\.isRunning)
        database = (databases.first { $0.id == "mysql-8.4" } ?? running.first ?? databases.first)?.id ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder

        guard panel.runModal() == .OK, let chosen = panel.url else {
            return
        }

        folder = chosen
    }

    private func create() {
        guard let folder else {
            return
        }

        savedFolder = folder.path(percentEncoded: false)
        savedTemplate = template.rawValue
        model.startNewSite(NewSite(
            template: template,
            name: name,
            parent: folder.path(percentEncoded: false),
            git: git,
            database: database.isEmpty ? nil : database,
            php: template == .laravel ? php : nil,
            node: template.kind == .node ? node : nil,
            starterKit: starterKit,
            authentication: authentication,
            teams: starterKit != .none && teams,
            tests: tests,
            boost: boost,
            locale: locale,
            adminUser: adminUser.trimmingCharacters(in: .whitespaces),
            adminEmail: adminEmail.trimmingCharacters(in: .whitespaces),
            network: network,
            framework: framework,
            packageManager: packageManager
        ))
    }
}

private struct TemplateCard: View {
    let template: SiteTemplate
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayName)
                        .fontWeight(.semibold)
                    Text(template.summary)
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

private struct NewSiteProgressView: View {
    @Environment(AppModel.self) private var model
    let run: NewSiteRun

    var body: some View {
        let task = model.newSiteTask
        let site = run.site
        let place = shortPath(URL(filePath: site.parent).appending(path: site.name))

        VStack(alignment: .leading, spacing: 12) {
            Text(run.importing == nil ? "Creating \(site.name)" : "Importing \(site.name)")
                .font(.headline)

            Text(run.importing == nil ? "\(NewSiteDescription.text(site)) in \(place)" : "\(run.format?.displayName ?? "Backup") in \(place)")

            if let steps = task?.steps {
                StepList(steps: steps)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Nexus prepares the new site…")
                        .foregroundStyle(.secondary)
                }
            }

            LogBox(lines: task?.log ?? [])

            Text("You can close this sheet. Nexus goes on, and the Overview shows the task under Activity.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Show log file") {
                    if let file = task?.logFile {
                        NSWorkspace.shared.open(URL(filePath: file))
                    }
                }
                .disabled(task?.logFile == nil)

                Spacer()

                Button("Stop") {
                    if let task {
                        model.stopTask(task.id)
                    }
                }
                .disabled(task == nil)

                Button("Close") {
                    model.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct NewSiteFailedView: View {
    @Environment(AppModel.self) private var model
    @State private var errorReport: ErrorReport?
    let failure: SiteCreationFailure

    var body: some View {
        let parts = ErrorDetails.split(failure.message)
        let name = model.newSiteRun?.site.name ?? ""
        let title = model.newSiteRun?.importing == nil ? "Nexus could not create \(name)" : "Nexus could not import \(name)"

        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text(parts.text)
                .fixedSize(horizontal: false, vertical: true)

            StepList(steps: failure.steps)
            LogBox(lines: failure.log)

            Text(keptText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.newSiteRun?.trashProblem {
                FailureLabel(message: problem) { errorReport = $0 }
            }

            HStack {
                Button("Show log file") {
                    NSWorkspace.shared.open(URL(filePath: failure.logFile))
                }

                Button("Move to trash") {
                    model.trashNewSiteLeftovers(failure)
                }
                .disabled(model.newSiteRun?.trashing == true)

                Spacer()

                if parts.id != nil {
                    Button("Send report…") {
                        errorReport = ErrorReport(message: failure.message, title: title, place: .window)
                    }
                }

                Button("Close") {
                    model.endNewSite()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
    }

    private var keptText: String {
        let folder = shortPath(URL(filePath: failure.folder))
        let site = failure.site.map { "the site \($0), " } ?? ""
        let database = failure.database.map { " and the database \($0)" } ?? ""
        let removesSite = failure.site == nil ? "" : "removes the site, "
        let removes = failure.database == nil ? "moves the folder to the Trash" : "moves the folder to the Trash and removes the database"

        return "Nexus keeps \(site)the folder \(folder)\(database), so you can look at them. \"Move to trash\" \(removesSite)\(removes)."
    }
}

private struct NewSiteDoneView: View {
    @Environment(AppModel.self) private var model
    let created: CreatedSite

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(created.host.split(separator: ".").first.map(String.init) ?? created.host) is ready")
                .font(.headline)

            Text("WordPress runs on \(created.url).")

            Form {
                Section {
                    LabeledContent("Site") {
                        HStack {
                            Text(created.url)
                                .foregroundStyle(.secondary)
                                .rowValue()
                            Button("Open") {
                                model.openInBrowser(created.url)
                            }
                        }
                    }

                    LabeledContent("Admin user") {
                        MonoText(created.adminUser ?? "")
                    }

                    LabeledContent("Password") {
                        HStack {
                            MonoText(created.adminPassword ?? "")
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(created.adminPassword ?? "", forType: .string)
                            }
                        }
                    }
                } footer: {
                    Text("Nexus does not keep this password. Copy it now. Later, wp-admin can send a new password to the inbox of Nexus.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Open wp-admin") {
                    model.openInBrowser("\(created.url)/wp-admin/")
                }

                Button("Done") {
                    model.endNewSite()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct StepList: View {
    let steps: [TaskStep]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    icon(step.state)
                        .frame(width: 16)

                    Text(step.title)
                        .foregroundStyle(step.state == .waiting ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    if let value = value(of: step) {
                        Text(value)
                            .font(.callout)
                            .foregroundStyle(step.state == .failed ? Color.redText : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(height: 36)
                .padding(.horizontal, 12)

                if index < steps.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func icon(_ state: TaskStepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.greenText)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.redText)
        case .waiting:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private func value(of step: TaskStep) -> String? {
        switch step.state {
        case .running:
            step.detail
        case .done:
            step.seconds.map { "\($0) s" }
        case .failed:
            step.seconds.map { "Stopped after \($0) s" }
        case .waiting:
            nil
        }
    }
}

private struct LogBox: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 160)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator)
        }
    }
}

// "Laravel with React, Pest and Laravel Boost" for the title of the steps.
enum NewSiteDescription {
    static func text(_ site: NewSite) -> String {
        switch site.template {
        case .laravel:
            var parts: [String] = []

            if site.starterKit != .none {
                parts.append(site.starterKit.displayName)
            }

            parts.append(site.tests.displayName)

            if site.boost {
                parts.append("Laravel Boost")
            }

            return "Laravel with \(EnglishList.joined(parts))"
        case .wordpress:
            switch site.network {
            case nil: return "WordPress"
            case .subfolders: return "WordPress network on subfolders"
            case .subdomains: return "WordPress network on subdomains"
            }
        case .vite:
            return "Vite with \(site.framework.displayName)"
        case .next, .nuxt, .astro:
            return site.template.displayName
        }
    }
}
