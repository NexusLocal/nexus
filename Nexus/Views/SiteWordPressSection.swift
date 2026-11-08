import NexusCore
import NexusIPC
import SwiftUI

// The configuration and the database of a WordPress site (Phase 4, 3b). The design is "Site
// WordPress Section" in nexus.pen, with four states. Nexus changes a file or makes a database only
// after a click.
struct SiteWordPressSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem
    @State private var info: WordPressSiteInfo?
    @State private var checked = false
    @State private var changing = false
    @State private var asksToSetUp = false
    @State private var asksToSetDBHost = false

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(checked ? info?.version ?? "Not found" : "Checking…")
                    .foregroundStyle(.secondary)
                    .rowValue()
            }
            .labeledContentStyle(.rowValue)

            if let info {
                configurationRow(info)

                if info.configFile != nil, let database = info.database {
                    databaseRow(info, database: database)
                }

                if let home = info.home {
                    LabeledContent("Site URL in WordPress") {
                        Text(home)
                            .foregroundStyle(.secondary)
                            .rowValue(.middle)
                            .help(home)
                    }
                    .labeledContentStyle(.rowValue)
                }
            }
        } header: {
            Text("WordPress")
        } footer: {
            footer
        }
        .task(id: "\(site.host) \(site.php) \(site.folder)") {
            await load()
        }
        .alert("Set up WordPress for \(site.host)?", isPresented: $asksToSetUp) {
            Button("Set up WordPress") {
                if let database = info?.setUpDatabase, let instance = info?.setUpInstance {
                    change { await model.setUpWordPress(site, database: database, instance: instance) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(setUpText)
        }
        .sheet(isPresented: $asksToSetDBHost) {
            if let info, let value = info.suggestedDBHost {
                SetDBHostSheet(host: site.host, value: value, info: info) {
                    change { await model.setWordPressDBHost(site, value: value) }
                }
            }
        }
    }

    @ViewBuilder
    private func configurationRow(_ info: WordPressSiteInfo) -> some View {
        LabeledContent("Configuration") {
            HStack {
                if let file = info.configFile {
                    PathText(file)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: (file as NSString).expandingTildeInPath)])
                    }
                } else {
                    Text(info.type == .bedrock ? "No .env" : "No wp-config.php")
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    if info.setUpDatabase != nil {
                        Button("Set up WordPress…") {
                            asksToSetUp = true
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(changing)
                    }
                }
            }
        }
        .labeledContentStyle(.rowValue)
    }

    @ViewBuilder
    private func databaseRow(_ info: WordPressSiteInfo, database: String) -> some View {
        let warns = info.databaseExists == false || info.problem != nil

        LabeledContent("Database") {
            HStack {
                HStack {
                    if warns {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusOrange)
                    }

                    Text(databaseText(info, database: database))
                        .foregroundStyle(warns ? Color.orangeText : Color.secondary)
                }
                .rowValue()

                if info.databaseExists == true, let service = info.instance.flatMap(model.service) {
                    OpenDatabaseButton(kind: service.kind, url: service.databaseURL(database))
                }

                if info.databaseExists == false, info.suggestedDBHost == nil {
                    Button("Create database") {
                        change { await model.createWordPressDatabase(site) }
                    }
                    .fixedSize()
                    .disabled(changing)
                }

                if info.suggestedDBHost != nil {
                    Button("Set DB_HOST…") {
                        asksToSetDBHost = true
                    }
                    .fixedSize()
                    .disabled(changing)
                }
            }
        }
        .labeledContentStyle(.rowValue)
    }

    @ViewBuilder
    private var footer: some View {
        if checked, info == nil {
            Text("Nexus cannot read the configuration of this site.")
                .foregroundStyle(Color.orangeText)
        } else if let info, let problem = info.problem {
            Text(problem)
                .foregroundStyle(Color.orangeText)
        } else if let info, info.configFile == nil, info.type == .bedrock {
            Text("This Bedrock project has no .env. Copy .env.example to .env, and fill in the database.")
        } else if let info, info.configFile == nil {
            Text(info.setUpDatabase == nil ? "No MySQL or MariaDB of Nexus runs. Start MySQL 8.4 to set up WordPress." : "\(setUpText) The browser then shows the installer of WordPress.")
        } else if let info, info.databaseExists == false, let database = info.database {
            Text("\(info.configTextAtStart) names the database \(database). Nexus makes it empty on \(instanceName(info.instance)). The browser then shows the installer of WordPress.")
        } else if let info, info.type == .bedrock {
            Text("Nexus reads \(info.configText). The site URL comes from the options table of the database.")
        } else if let info {
            Text("Nexus reads \(info.configText) without a run of the file. The site URL comes from the options table of the database.")
        }
    }

    private var setUpText: String {
        "Nexus makes the database \(info?.setUpDatabase ?? "") on \(instanceName(info?.setUpInstance)) and writes wp-config.php."
    }

    private func databaseText(_ info: WordPressSiteInfo, database: String) -> String {
        if info.databaseExists == false {
            return "\(database) is not on \(instanceName(info.instance))"
        }

        if info.instance == nil, let host = info.dbHost {
            return "\(database) on \(host)"
        }

        return "\(database) on \(instanceName(info.instance))"
    }

    private func instanceName(_ id: String?) -> String {
        id.flatMap { model.service($0)?.name } ?? id ?? "MySQL"
    }

    private func load() async {
        info = await model.wordPressSite(of: site)
        checked = true
    }

    private func change(_ action: @escaping () async -> Bool) {
        changing = true

        Task {
            if await action() {
                await load()
            }

            changing = false
        }
    }
}

// "Set DB_HOST…" asks first, as "Send mail to Nexus…" does (D44). The design is "Sheet Set
// DB_HOST" in nexus.pen.
struct SetDBHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    let value: String
    let info: WordPressSiteInfo
    let set: () -> Void

    private var file: String {
        info.configText
    }

    private var commentStart: String {
        (info.type == .bedrock ? EnvFile.beforeNexus : WordPressFiles.beforeNexus).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set DB_HOST of \(host) to \(value)?")
                .font(.headline)

            Text("Nexus changes this line in \(file). WordPress then reaches the database \(info.database ?? "") on its Nexus instance.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
                    LabeledContent {
                        Text(verbatim: value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } label: {
                        Text(verbatim: "DB_HOST")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            Text("The old line stays in \(file) as a comment line that starts with \"\(commentStart)\". PHP reads the new value at the next request.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set DB_HOST") {
                    dismiss()
                    set()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
