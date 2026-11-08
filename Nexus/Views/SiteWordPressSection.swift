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
    @State private var asksToChangeURLs = false
    @State private var asksToUndo = false
    @State private var changingURLs = false

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
                    siteURLRow(info, home: home)
                }

                if let configHome = info.configHome {
                    urlRow("WP_HOME in \(homeFileName(info))", value: configHome, warns: info.urlPlan?.configFrom != nil)
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
                    change { await model.setWordPressDBHost(site, value: value, user: info.suggestedUser) }
                }
            }
        }
        .alert("Change the URLs of \(site.host)?", isPresented: $asksToChangeURLs, presenting: info?.urlPlan) { plan in
            Button("Change the URLs") {
                changingURLs = true
                change { await model.changeWordPressURLs(site, plan: plan) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(changeText(plan))
        }
        .alert("Undo the URL change of \(site.host)?", isPresented: $asksToUndo, presenting: info?.urlChange) { urlChange in
            Button("Undo the change") {
                change { await model.undoWordPressURLChange(site, plan: urlChange.plan) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { urlChange in
            Text(undoText(urlChange))
        }
        // The import sheet of "Copy to Nexus…" can bring the database to Nexus.
        .onChange(of: model.sheet?.id) { old, new in
            if new == nil, old?.hasPrefix("import-") == true {
                Task { await load() }
            }
        }
    }

    // The home option of the database, with "Change the URLs" when it or WP_HOME differs from the
    // URL of Nexus, and "Undo…" after a change (Phase 4, 3d). The design is "Site WordPress URL
    // States" and "Site WordPress URL Change".
    @ViewBuilder
    private func siteURLRow(_ info: WordPressSiteInfo, home: String) -> some View {
        if changingURLs {
            LabeledContent("Site URL in WordPress") {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Changing the URLs…")
                        .foregroundStyle(.secondary)
                }
            }
            .labeledContentStyle(.rowValue)
        } else {
            LabeledContent("Site URL in WordPress") {
                HStack {
                    urlValue(home, warns: info.urlPlan?.databaseFrom != nil)

                    if let plan = info.urlPlan {
                        Button("Change the URLs to \(plan.to)…") {
                            asksToChangeURLs = true
                        }
                        .fixedSize()
                        .disabled(changing)
                    } else if info.urlChange != nil {
                        Button("Undo…") {
                            asksToUndo = true
                        }
                        .fixedSize()
                        .disabled(changing)
                    }
                }
            }
            .labeledContentStyle(.rowValue)
        }
    }

    private func urlRow(_ label: String, value: String, warns: Bool) -> some View {
        LabeledContent(label) {
            urlValue(value, warns: warns)
        }
        .labeledContentStyle(.rowValue)
    }

    private func urlValue(_ value: String, warns: Bool) -> some View {
        HStack {
            if warns {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.statusOrange)
            }

            Text(value)
                .foregroundStyle(warns ? Color.orangeText : Color.secondary)
                .help(value)
        }
        .rowValue(.middle)
    }

    private func homeFileName(_ info: WordPressSiteInfo) -> String {
        info.configHomeFile.map { ($0 as NSString).lastPathComponent } ?? info.configName
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

                if let suggested = info.suggestedDBHost {
                    Button(suggested == info.dbHost ? "Set the account…" : "Set DB_HOST…") {
                        asksToSetDBHost = true
                    }
                    .fixedSize()
                    .disabled(changing)
                }

                if let instance = info.copyInstance {
                    Button("Copy to Nexus…") {
                        Task { await model.copyWordPressDatabase(site, instance: instance) }
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
        } else if changingURLs, let info, let plan = info.urlPlan {
            Text(changingText(info, plan))
        } else if let info, let problem = info.problem {
            MessageText(problem)
        } else if let info, info.configFile == nil, info.type == .bedrock {
            Text("This Bedrock project has no .env. Copy .env.example to .env, and fill in the database.")
        } else if let info, info.configFile == nil {
            Text(info.setUpDatabase == nil ? "No MySQL or MariaDB of Nexus runs. Start MySQL 8.4 to set up WordPress." : "\(setUpText) The browser then shows the installer of WordPress.")
        } else if let info, info.databaseExists == false, let database = info.database {
            Text("\(info.configTextAtStart) names the database \(database). Nexus makes it empty on \(instanceName(info.instance)). The browser then shows the installer of WordPress.")
        } else if let info, let plan = info.urlPlan {
            Text(planText(info, plan))
                .foregroundStyle(Color.orangeText)
        } else if let info, let urlChange = info.urlChange {
            Text(doneText(info, urlChange))
        } else if let info, info.type == .bedrock {
            Text("Nexus reads \(info.configText). The site URL comes from the options table of the database.")
        } else if let info {
            Text("Nexus reads \(info.configText) without a run of the file. The site URL comes from the options table of the database.")
        }
    }

    private var setUpText: String {
        "Nexus makes the database \(info?.setUpDatabase ?? "") on \(instanceName(info?.setUpInstance)) and writes wp-config.php."
    }

    private func planText(_ info: WordPressSiteInfo, _ plan: WordPressURLPlan) -> String {
        guard plan.configFrom != nil else {
            return "WordPress uses \(plan.databaseFrom ?? "") as its URL, for example after an import from MAMP PRO. Nexus serves this site on \(plan.to). So links and redirects go to the old URL."
        }

        let file = fileName(plan)
        let links = plan.oldURLs.count > 1 ? plan.databaseFrom.map { ["The database has the links of \($0)."] } ?? [] : []

        return (["WordPress takes its URL from WP_HOME in \(file)."] + links + ["The button sets WP_HOME to \(plan.to) and changes the URLs in the database.", "The old line stays in \(file) as a comment line."]).joined(separator: " ")
    }

    private func changeText(_ plan: WordPressURLPlan) -> String {
        let database = info?.database ?? ""
        var sentences = ["Nexus writes a dump of the database \(database) to the trash first.", "Then WP-CLI replaces \(EnglishList.joined(plan.oldURLs)) with \(plan.to) in all tables of \(database)."]

        if plan.configFrom != nil {
            sentences += ["Nexus also sets WP_HOME in \(fileName(plan)).", "The old line stays as a comment line."]
        }

        return sentences.joined(separator: " ")
    }

    private func changingText(_ info: WordPressSiteInfo, _ plan: WordPressURLPlan) -> String {
        "Nexus writes a dump of the database \(info.database ?? "") to the trash. Then WP-CLI replaces \(EnglishList.joined(plan.oldURLs)) with \(plan.to)."
    }

    private func doneText(_ info: WordPressSiteInfo, _ urlChange: WordPressURLChange) -> String {
        let until = Self.day.string(from: urlChange.expires)
        let places = urlChange.replacements == 1 ? "1 place" : "\(urlChange.replacements.formatted()) places"
        let plan = urlChange.plan

        return "Nexus replaced \(EnglishList.joined(plan.oldURLs)) with \(plan.to) in \(places). The dump of the old database stays in the trash until \(until). \"Undo…\" puts it back."
    }

    private func undoText(_ urlChange: WordPressURLChange) -> String {
        var sentences: [String] = []

        if urlChange.dump != nil {
            sentences += ["Nexus puts back the database \(urlChange.database) from the dump of \(Self.time.string(from: urlChange.date)).", "Changes in the database after that time are lost."]
        }

        if urlChange.plan.configFrom != nil {
            sentences.append("WP_HOME in \(fileName(urlChange.plan)) gets its old value.")
        }

        return sentences.joined(separator: " ")
    }

    private func fileName(_ plan: WordPressURLPlan) -> String {
        plan.configFile.map { ($0 as NSString).lastPathComponent } ?? info?.configName ?? "wp-config.php"
    }

    private static let day = dateFormatter("d MMMM")
    private static let time = dateFormatter("d MMMM 'at' HH:mm")

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
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
            changingURLs = false
        }
    }
}

// "Set DB_HOST…" asks first, as "Send mail to Nexus…" does (D44). The design is "Sheet Set
// DB_HOST" in nexus.pen.
struct SetDBHostSheet: View {
    @Environment(AppModel.self) private var model
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

    // The design is "Sheet Set DB_HOST · Account" when the account changes too.
    private var instanceName: String {
        let port = DatabaseAddress(dbHost: value).localPort
        return model.databaseInstances.first { $0.ports.first?.number == port }?.name ?? "the Nexus instance"
    }

    // DB_HOST can be right already while the account is wrong.
    private var changesHost: Bool {
        info.dbHost != value
    }

    private var title: String {
        guard info.suggestedUser != nil else {
            return "Set DB_HOST of \(host) to \(value)?"
        }

        return changesHost ? "Set DB_HOST and the account of \(host)?" : "Set the account of \(host)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text(info.suggestedUser == nil
                ? "Nexus changes this line in \(file). WordPress then reaches the database \(info.database ?? "") on its Nexus instance."
                : "\(info.configTextAtStart) has another account than \(instanceName). Nexus changes these lines in \(file). WordPress then reaches the database \(info.database ?? "") with the account of that instance.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
                    if changesHost {
                        keyRow("DB_HOST", value)
                    }

                    if let user = info.suggestedUser {
                        keyRow("DB_USER", user)
                        keyRow("DB_PASSWORD", "••••••")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            Text(info.suggestedUser == nil
                ? "The old line stays in \(file) as a comment line that starts with \"\(commentStart)\". PHP reads the new value at the next request."
                : "The old lines stay in \(file) as comment lines that start with \"\(commentStart)\". PHP reads the new values at the next request.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(changesHost ? "Set DB_HOST" : "Set the account") {
                    dismiss()
                    set()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        LabeledContent {
            Text(verbatim: text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        } label: {
            Text(verbatim: key)
                .font(.system(.body, design: .monospaced))
        }
    }
}
