import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// A WordPress site from a backup (Phase 4, 3f). The design is "Sheet Import Site", "· States" and
// "· Done". nexusd reads the backup first, and the sheet shows what it found. The steps, a failure
// and Stop are the ones of a new site.
struct ImportSiteForm: View {
    static let formats = "A zip of Local, Jetpack or Studio, a .wpress file of All-in-One WP Migration, or a folder with the files of WordPress and a .sql or .sql.gz dump."

    @Environment(AppModel.self) private var model
    @AppStorage("newSiteFolder") private var savedFolder = ""

    @State private var backup: URL?
    // Each choice reads the backup again, also a second choice of the same file.
    @State private var reads = 0
    @State private var info: BackupInfo?
    @State private var problem: String?
    @State private var reading = false
    @State private var name = ""
    @State private var folder: URL?
    @State private var database = ""
    @State private var git = true
    @State private var errorReport: ErrorReport?

    let refusal: String?

    init(refusal: String?, request: SiteImport?, backup: URL?) {
        self.refusal = refusal

        guard let request else {
            _backup = State(initialValue: backup)
            return
        }

        _backup = State(initialValue: URL(filePath: request.backup))
        _name = State(initialValue: request.name)
        _folder = State(initialValue: URL(filePath: request.parent, directoryHint: .isDirectory))
        _database = State(initialValue: request.database ?? "")
        _git = State(initialValue: request.git)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a WordPress site")
                .font(.headline)

            Form {
                Section {
                    LabeledContent("Backup") {
                        HStack {
                            if let backup {
                                PathText(shortPath(backup))
                            } else {
                                Text("None")
                                    .foregroundStyle(.tertiary)
                            }

                            Button("Choose…", action: chooseBackup)
                        }
                    }
                    .labeledContentStyle(.rowValue)
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(Color.redText)
                    } else if reading {
                        Text("Nexus reads the backup…")
                    } else if info == nil {
                        Text(backup == nil ? "\(Self.formats) You can also drop it on the Overview." : Self.formats)
                    }
                }

                if let info, problem == nil {
                    foundSection(info)
                    siteSection(info)
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

                if reading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Cancel", role: .cancel) {
                    model.endNewSite()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import site", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
        .task(id: reads) {
            await read()
        }
        .onAppear(perform: chooseDefaults)
        .onChange(of: model.databaseInstances.map(\.id), chooseDefaults)
    }

    private func foundSection(_ info: BackupInfo) -> some View {
        Section {
            LabeledContent("Format", value: info.format?.displayName ?? "Unknown")
            LabeledContent("WordPress", value: BackupText.wordPress(info))
            LabeledContent("Dump") {
                Text(dumpText(info))
                    .rowValue(.middle)
            }
            LabeledContent("Table prefix", value: info.format == .wpress ? "SERVMASK_PREFIX, Nexus uses \(info.tablePrefix ?? "wp_")" : info.tablePrefix ?? "As in wp-config.php")
            LabeledContent("Site URL") {
                Text(info.siteURL ?? "Unknown")
                    .rowValue(.middle)
            }
        } header: {
            Text("Found in the backup")
        } footer: {
            if info.format == .localSiteFolder {
                Text("Local writes this dump when the site stops. So it can be older than the site. For a current copy, use Export in Local.")
                    .foregroundStyle(Color.orangeText)
            }
        }
    }

    private func siteSection(_ info: BackupInfo) -> some View {
        Section {
            LabeledContent("Name") {
                CodeField(title: "Name", text: $name, prompt: info.suggestedName)
            }

            LabeledContent("Folder") {
                HStack {
                    PathText(folder.map(shortPath) ?? "")
                    Button("Choose…", action: chooseFolder)
                }
            }
            .labeledContentStyle(.rowValue)

            Picker("Database", selection: $database) {
                ForEach(databases) { Text($0.name).tag($0.id) }
            }

            Toggle("Git repository", isOn: $git)
                .toggleStyle(.switch)
        } footer: {
            if let nameProblem = newSiteNameProblem(name, in: folder) {
                Text(nameProblem)
                    .foregroundStyle(Color.redText)
            } else {
                Text(footer(info))
            }
        }
    }

    private func dumpText(_ info: BackupInfo) -> String {
        let size = info.dumpBytes.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil }
        let date = info.format == .localSiteFolder ? info.dumpDate.map { $0.formatted(.dateTime.day().month(.wide)) } : nil
        return ([info.dump] + [size, date]).compactMap { $0 }.joined(separator: ", ")
    }

    private func footer(_ info: BackupInfo) -> String {
        let siteName = name.isEmpty ? info.suggestedName : name
        let place = folder.map { shortPath($0.appending(path: siteName)) } ?? siteName
        let url = model.newSiteURL(host: "\(siteName).\(model.settings.tld)")
        let urls = info.siteURL.map { "Then it changes \($0) to \(url) in each form, as \"Change the URLs\" does." } ?? "Then it changes the URLs of the site to \(url)."
        let repository = git ? " The repository ignores wp-config.php and the uploads." : ""

        return "Nexus makes the folder \(place) and the database \(NewSiteName.databaseBase(of: siteName)), and imports the dump. \(urls)\(repository)"
    }

    private var databases: [ServiceVersion] {
        model.databaseInstances.filter { $0.kind == .mysql || $0.kind == .mariadb }
    }

    private var canImport: Bool {
        guard let info, info.problem == nil, problem == nil, !reading, folder != nil, !database.isEmpty else {
            return false
        }

        let siteName = name.isEmpty ? info.suggestedName : name
        return newSiteNameProblem(siteName, in: folder) == nil
    }

    private func read() async {
        guard let backup else {
            return
        }

        reading = true
        problem = nil

        let answer = await model.inspectBackup(backup)

        // The answer about an older choice comes after the choice of another backup.
        guard !Task.isCancelled else {
            return
        }

        reading = false

        switch answer {
        case .success(let found):
            info = found
            problem = found.problem

            if name.isEmpty {
                name = found.suggestedName
            }
        case .failure(let failure):
            info = nil
            problem = failure.message
        }
    }

    private func chooseDefaults() {
        if folder == nil {
            let saved = savedFolder.isEmpty ? nil : URL(filePath: savedFolder, directoryHint: .isDirectory)
            folder = saved.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil } ?? model.newSiteFolders.first
        }

        if !databases.contains(where: { $0.id == database }) {
            database = (databases.first { $0.id == "mysql-8.4" } ?? databases.first(where: \.isRunning) ?? databases.first)?.id ?? ""
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = backup?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")

        guard panel.runModal() == .OK, let chosen = panel.url else {
            return
        }

        name = ""
        info = nil
        problem = nil
        backup = chosen
        reads += 1
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

    private func start() {
        guard let backup, let folder, let info else {
            return
        }

        savedFolder = folder.path(percentEncoded: false)
        model.startImport(SiteImport(backup: backup.path(percentEncoded: false), name: name.isEmpty ? info.suggestedName : name, parent: folder.path(percentEncoded: false), database: database, git: git), format: info.format)
    }
}

// The end of an import. The site keeps the users of the backup. The mail check of the Site screen
// shows if a plugin sends real mail (design "Sheet Import Site · States").
struct ImportDoneView: View {
    @Environment(AppModel.self) private var model
    let created: CreatedSite

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(created.host.split(separator: ".").first.map(String.init) ?? created.host) is ready")
                .font(.headline)

            Text(created.message)
                .fixedSize(horizontal: false, vertical: true)

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
                } footer: {
                    Text("Log in with an account of the original site. wp-admin can send a new password to the inbox of Nexus.")
                }

                if let site = model.site(created.host) {
                    SiteMailSection(site: site)
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
