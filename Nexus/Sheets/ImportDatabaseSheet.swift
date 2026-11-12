import AppKit
import NexusCore
import NexusIPC
import SwiftUI

struct ImportDatabaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var instance: String
    // The server and the database of a WordPress site (Phase 4, 3d). The fields start with them.
    var source: WordPressCopySource?
    // The database of a row on the Site screen. The sheet then starts with a dump file for it.
    var dumpInto: String?
    // The database of the WordPress site. A list that fails to load does not make it go.
    @State private var wantedDatabase: String?
    @State private var errorReport: ErrorReport?
    // A Nexus instance, or nil for another server such as MAMP PRO.
    @State private var sourceInstance: String?
    @State private var host = "127.0.0.1"
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var database = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var replace = false
    @State private var sources: [DatabaseSize] = []
    @State private var sourcesProblem: String?
    @State private var loadingSources = false
    // A dump file as the source (owner, 2026-11-09).
    @State private var usesDumpFile = false
    @State private var dumpFile: URL?
    @State private var dumpChoice: String?
    @State private var dumpInfo: DumpInfo?
    @State private var dumpProblem: String?
    @State private var inspecting = false
    @State private var existing: DumpExisting?
    @State private var trashDays = 7
    // The name of the copy that this sheet started. The sample data has no copy.
    @State private var startedName: String?
    @State private var sampleImporting = false

    #if DEBUG
    @MainActor static var debugDumpFile: URL?
    #endif

    private enum Source: Hashable {
        case nexus(String)
        case other
        case dumpFile
    }

    private var kind: DatabaseKind {
        model.service(instance)?.kind.databaseKind ?? .mysql
    }

    private var importKey: String? {
        startedName.map { AppModel.importKey(instance: instance, name: $0) }
    }

    private var importing: Bool {
        sampleImporting || importKey.map { model.runningImports.contains($0) } ?? false
    }

    private var importResult: ImportResult? {
        importKey.flatMap { model.importResults[$0] }
    }

    // nexusd starts the task of the copy after its checks. Before that, a stop has no task.
    private var canStop: Bool {
        sampleImporting || startedName.flatMap { model.importTask(instance: instance, name: $0) } != nil
    }

    private var sourceKey: String {
        [instance, sourceInstance ?? "", host, port, user, password].joined(separator: "\n")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var inspectionKey: String {
        [String(usesDumpFile), dumpFile?.path(percentEncoded: false) ?? "", dumpChoice ?? "", instance, trimmedName].joined(separator: "\n")
    }

    // MySQL and MariaDB speak the same protocol. PostgreSQL only reads PostgreSQL.
    private var nexusSources: [ServiceVersion] {
        model.databaseInstances.filter { source in
            source.id != instance && source.isActive && source.account != nil && source.kind.databaseKind?.usesMySQLProtocol == kind.usesMySQLProtocol
        }
    }

    private var sourceServer: DatabaseServer? {
        guard let sourceInstance else {
            guard !host.isEmpty, let number = Int(port) else {
                return nil
            }

            return DatabaseServer(host: host, port: number, account: DatabaseAccount(user: user, password: password))
        }

        guard let source = model.service(sourceInstance), let account = source.account, let number = source.ports.first?.number else {
            return nil
        }

        return DatabaseServer(host: "127.0.0.1", port: number, account: account)
    }

    private var sourceChoice: Binding<Source> {
        Binding {
            guard !usesDumpFile else {
                return .dumpFile
            }

            return sourceInstance.map(Source.nexus) ?? .other
        } set: { choice in
            switch choice {
            case .nexus(let id):
                usesDumpFile = false
                sourceInstance = id
            case .other:
                usesDumpFile = false
                sourceInstance = nil
            case .dumpFile:
                usesDumpFile = true

                if dumpFile == nil {
                    Task { chooseDumpFile() }
                }
            }
        }
    }

    // The database exists when nexusd found its tables.
    private var databaseExists: Bool {
        dumpInfo?.existingTables != nil
    }

    private var dumpReady: Bool {
        guard let dumpInfo, dumpFile != nil, !inspecting, dumpInfo.problem == nil, dumpProblem == nil else {
            return false
        }

        return dumpInfo.dumps.isEmpty || dumpInfo.dump != nil
    }

    private var canImport: Bool {
        guard !trimmedName.isEmpty else {
            return false
        }

        guard usesDumpFile else {
            return !database.isEmpty
        }

        return dumpReady && (!databaseExists || existing != nil)
    }

    private var importTitle: String {
        guard usesDumpFile, databaseExists else {
            return "Import"
        }

        switch existing {
        case .replaceTables:
            return dumpInfo?.tables.map { "Replace \(Count.text($0.count, "table"))" } ?? "Replace tables"
        case .replaceDatabase:
            return "Replace database"
        case nil:
            return "Import"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a database")
                .font(.headline)

            Text("Copy a database from another server, or load a dump file into a database. Nexus only reads the other server and the file.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
                    Picker("Source", selection: sourceChoice) {
                        ForEach(nexusSources) { source in
                            Text(source.name).tag(Source.nexus(source.id))
                        }

                        if !nexusSources.isEmpty {
                            Divider()
                        }

                        Text("Another server").tag(Source.other)
                        Divider()
                        Text("A dump file…").tag(Source.dumpFile)
                    }

                    if usesDumpFile {
                        dumpRows
                    } else {
                        serverRows
                    }
                } header: {
                    Text("From")
                } footer: {
                    fromFooter
                }

                Section {
                    Picker("Instance", selection: $instance) {
                        ForEach(model.databaseInstances) { Text($0.name).tag($0.id) }
                    }

                    // A text field can write its text back without a change, for example when
                    // it gets the focus. Only another name than the database is an edit.
                    field(usesDumpFile ? "Database" : "Name", text: Binding(get: { name }, set: { name = $0; nameEdited = $0 != database }))

                    if !usesDumpFile {
                        Toggle("Replace the database when it exists", isOn: $replace)
                            .toggleStyle(.switch)
                    } else if databaseExists {
                        Picker("\(trimmedName) already exists", selection: $existing) {
                            Text("Choose…").tag(DumpExisting?.none)
                            Text("Replace only the tables in the dump").tag(Optional(DumpExisting.replaceTables))
                            Text("Replace the whole database").tag(Optional(DumpExisting.replaceDatabase))
                        }
                    }
                } header: {
                    Text("Into")
                } footer: {
                    if usesDumpFile, dumpReady {
                        DumpSummary(name: trimmedName, info: dumpInfo, existing: existing, trashDays: trashDays)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(importing)

            switch importResult {
            case .failed(let message):
                FailureLabel(message: message) { errorReport = $0 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.errorBackground, in: .rect(cornerRadius: 6))
            case .stopped(let message):
                Label(message, systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }

            if sampleImporting {
                ImportProgress(task: Self.sampleTask)
            } else if importing, let startedName {
                ImportProgress(task: model.importTask(instance: instance, name: startedName))
            }

            HStack {
                Spacer()

                if importing {
                    Button("Stop import") {
                        stopImport()
                    }
                    .disabled(!canStop)

                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(importTitle) {
                        startImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
        .onAppear {
            if let dumpInto {
                name = dumpInto
                nameEdited = true
                existing = .replaceTables
            }

            #if DEBUG
            if let file = Self.debugDumpFile {
                usesDumpFile = true
                dumpFile = file
                name = nameEdited ? name : Self.databaseName(from: file)
                return
            }
            #endif

            if dumpInto != nil {
                usesDumpFile = true
                Task { chooseDumpFile() }
                return
            }

            guard let source else {
                useStandardAccount(of: kind)
                sourceInstance = nexusSources.first?.id
                return
            }

            sourceInstance = nil
            wantedDatabase = source.database
            host = source.server.host
            port = String(source.server.port ?? kind.standardPort)
            user = source.server.account.user
            password = source.server.account.password
            database = source.database
            name = source.database
        }
        // A chosen server that is no source anymore goes away. "Another server" stays chosen.
        .onChange(of: nexusSources.map(\.id)) { _, sources in
            if let sourceInstance, !sources.contains(sourceInstance) {
                self.sourceInstance = sources.first
            }
        }
        .onDisappear {
            if let importKey, model.importInSheet == importKey {
                model.importInSheet = nil
            }
        }
        .onChange(of: kind) { old, new in
            useStandardAccount(of: new, insteadOf: old)
        }
        .onChange(of: database) {
            followDatabase()
        }
        .task(id: sourceKey) {
            await loadSources()
        }
        .task(id: inspectionKey) {
            await inspectDump()
        }
        .task {
            await loadTrashDays()
        }
    }

    @ViewBuilder
    private var serverRows: some View {
        if sourceInstance == nil {
            field("Host", text: $host)
            field("Port", text: $port)
                .digitsOnly($port)
            field("User", text: $user)

            LabeledContent("Password") {
                SecureField("Password", text: $password, prompt: Text("No password"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 200)
            }
        }

        Picker("Database", selection: $database) {
            if sources.isEmpty {
                Text(loadingSources ? "Loading…" : "No database").tag("")
            }

            ForEach(sources, id: \.name) { source in
                Text(source.name).tag(source.name)
            }
        }
        .disabled(sources.isEmpty)
    }

    @ViewBuilder
    private var dumpRows: some View {
        LabeledContent("File") {
            HStack {
                Text(dumpFile.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "No file")
                    .foregroundStyle(.secondary)
                    .rowValue(.middle)
                    .help(dumpFile?.path(percentEncoded: false) ?? "")

                Button("Choose…") {
                    chooseDumpFile()
                }
            }
        }

        if let dumpInfo, dumpInfo.dumps.count > 1 {
            Picker("Dump", selection: $dumpChoice) {
                if dumpInfo.dump == nil {
                    Text("Choose…").tag(String?.none)
                }

                ForEach(dumpInfo.dumps, id: \.self) { dump in
                    Text(dump).tag(Optional(dump))
                }
            }
        } else if let dump = dumpInfo?.dump {
            LabeledContent("Dump") {
                Text(dump)
                    .foregroundStyle(.secondary)
                    .rowValue(.middle)
            }
        }
    }

    @ViewBuilder
    private var fromFooter: some View {
        if usesDumpFile {
            if let problem = dumpProblem ?? dumpInfo?.problem {
                MessageText(problem, color: .redText) { errorReport = $0 }
            } else if inspecting {
                Text("Nexus reads the dump file…")
            } else if let dumpInfo, dumpInfo.dumps.count > 1, dumpInfo.dump == nil {
                Text("\(dumpFile?.lastPathComponent ?? "The archive") has \(dumpInfo.dumps.count) dumps. Choose the dump for this database.")
            } else {
                Text("Nexus reads a .sql or .sql.gz file. It also reads a .zip, .tar or .tar.gz file with such a dump in it. For PostgreSQL it also reads a file that pg_dump -Fc makes.")
            }
        } else if let sourcesProblem {
            MessageText(sourcesProblem) { errorReport = $0 }
        }
    }

    private func chooseDumpFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = dumpFile?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")

        guard panel.runModal() == .OK, let chosen = panel.url else {
            return
        }

        dumpFile = chosen
        dumpChoice = nil
        dumpInfo = nil
        dumpProblem = nil

        if !nameEdited {
            name = Self.databaseName(from: chosen)
        }
    }

    // A short wait comes first. So each typed letter of the name does not read the file again.
    private func inspectDump() async {
        // A cancelled run can leave inspecting on. A run for another source turns it off.
        guard usesDumpFile, let dumpFile else {
            inspecting = false
            return
        }

        guard model.isLive else {
            dumpInfo = Self.sampleDumpInfo
            return
        }

        inspecting = true
        defer {
            if !Task.isCancelled {
                inspecting = false
            }
        }

        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else {
            return
        }

        let inspection = DumpInspection(file: dumpFile.path(percentEncoded: false), dump: dumpChoice, target: .instance(instance), name: trimmedName.isEmpty ? nil : trimmedName)
        let result = await model.inspectDump(inspection)
        guard !Task.isCancelled else {
            return
        }

        switch result {
        case .success(let info):
            dumpInfo = info
            dumpProblem = nil

            if dumpChoice == nil, let dump = info.dump {
                dumpChoice = dump
            }
        case .failure(let problem):
            dumpInfo = nil
            dumpProblem = problem.message
        }
    }

    private func loadTrashDays() async {
        guard model.isLive, case .answer(.workspaceSettings(let settings)) = await model.outcome(of: .workspaceSettings) else {
            return
        }

        trashDays = settings.dumpDays
    }

    // A port and a user that the user did not change follow the kind of the instance.
    private func useStandardAccount(of kind: DatabaseKind, insteadOf old: DatabaseKind? = nil) {
        if port.isEmpty || old.map({ port == String($0.standardPort) }) == true {
            port = String(kind.standardPort)
        }

        if user.isEmpty || old.map({ user == Self.standardUser(of: $0) }) == true {
            user = Self.standardUser(of: kind)
        }
    }

    private static func standardUser(of kind: DatabaseKind) -> String {
        kind == .postgresql ? "postgres" : "root"
    }

    // A short wait comes first. So each typed letter does not ask nexusd for the list.
    private func loadSources() async {
        guard !usesDumpFile else {
            return
        }

        guard model.isLive else {
            sources = Self.sampleSources
            select(database.isEmpty ? Self.sampleSources[0].name : database)
            return
        }

        guard let server = sourceServer else {
            sources = []
            sourcesProblem = nil
            loadingSources = false
            select("")
            return
        }

        // A new host or account cancels this load and starts the next one. So only the last
        // load ends the loading state.
        loadingSources = true
        defer {
            if !Task.isCancelled {
                loadingSources = false
            }
        }

        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else {
            return
        }

        let result = await model.sourceDatabases(on: server, for: instance)
        guard !Task.isCancelled else {
            return
        }

        switch result {
        case .success(let list):
            sources = list
            sourcesProblem = nil
            let choice = [wantedDatabase, database].compactMap { $0 }.first { name in list.contains { $0.name == name } }
            select(choice ?? list.first?.name ?? "")

            if choice != nil, choice == wantedDatabase {
                wantedDatabase = nil
            }
        case .failure(let problem):
            sources = []
            sourcesProblem = problem.message
            select("")
        }
    }

    private func select(_ source: String) {
        database = source
        followDatabase()
    }

    // The name of the copy is the name of the database until the user types another name.
    private func followDatabase() {
        if !nameEdited, !usesDumpFile {
            name = database
        }
    }

    private func startImport() {
        guard model.isLive else {
            sampleImporting = true
            return
        }

        guard usesDumpFile else {
            guard let server = sourceServer else {
                return
            }

            startedName = trimmedName
            model.startImport(DatabaseCopy(source: server, database: database, instance: instance, name: trimmedName, replace: replace))
            return
        }

        guard let dumpFile else {
            return
        }

        startedName = trimmedName
        model.startDumpImport(DumpImport(file: dumpFile.path(percentEncoded: false), dump: dumpInfo?.dump, target: .instance(instance), name: trimmedName, existing: databaseExists ? existing : nil))
    }

    private func stopImport() {
        guard model.isLive else {
            sampleImporting = false
            return
        }

        if let startedName, let task = model.importTask(instance: instance, name: startedName) {
            model.stopTask(task.id)
        }
    }

    // All fields of this form have the same width and start on the left (UX rules).
    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .font(.system(.body, design: .monospaced))
                .frame(width: 200)
        }
    }

    // shop-2026-11-08.sql.gz gives shop_2026_11_08. A database name has letters, digits and _.
    static func databaseName(from file: URL) -> String {
        var base = file.lastPathComponent.lowercased()

        for suffix in [".gz", ".tgz", ".zip", ".tar", ".sql", ".dump", ".backup"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }

        let cleaned = base.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }

        return String(cleaned).split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
    }

    private static let sampleSources = [
        DatabaseSize(name: "foo_platform", bytes: 2_800_000_000),
        DatabaseSize(name: "shop", bytes: 48_000_000),
        DatabaseSize(name: "crm", bytes: 12_000_000),
    ]

    private static let sampleDumpInfo = DumpInfo(
        dumps: ["shop.sql"],
        dump: "shop.sql",
        format: .mysql,
        bytes: 1_200_000_000,
        tables: ["users", "orders", "products", "carts", "payments", "invoices", "coupons", "reviews", "addresses", "shipments", "returns", "settings"],
        existingTables: (1...40).map { "table_\($0)" }
    )

    private static let sampleTask = TaskInfo(
        id: "sample",
        work: .copyDatabase(database: "foo_platform", instance: "mysql-8.0", name: "foo_platform"),
        started: .now.addingTimeInterval(-90),
        completed: 1_200_000_000,
        total: 2_800_000_000,
        table: "audit_logs",
        tableNumber: 14,
        tableCount: 63
    )
}

// What happens to the data, under the database (design slide 242). The lines name the tables of the
// dump and the tables that stay, so a replace holds no surprise.
private struct DumpSummary: View {
    let name: String
    let info: DumpInfo?
    let existing: DumpExisting?
    let trashDays: Int

    private var tables: [String] {
        info?.tables ?? []
    }

    private var existingTables: [String]? {
        info?.existingTables
    }

    private var otherTables: [String] {
        (existingTables ?? []).filter { !tables.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if existingTables == nil {
                Text("Nexus makes the database \(name) and loads the dump into it.")
            } else {
                switch existing {
                case nil:
                    Text("Choose what happens to \(name), or type another name for a new database.")
                        .foregroundStyle(Color.orangeText)
                case .replaceTables:
                    line("tablecells", info?.tables == nil ? "Each table of the dump replaces the table with the same name." : "\(Count.text(tables.count, "table")) get the data of the dump: \(examples).")
                    line("checkmark", stayText)
                    copyLine
                case .replaceDatabase:
                    line("exclamationmark.triangle", deleteText, color: .orangeText)
                    line("tablecells", info?.tables == nil ? "Then \(name) gets the tables of the dump." : "Then \(name) gets the \(Count.text(tables.count, "table")) of the dump.")
                    copyLine
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stayText: String {
        switch otherTables.count {
        case 0: "\(name) has no other tables."
        case 1: "The other table of \(name) stays as it is."
        default: "The other \(otherTables.count) tables of \(name) stay as they are."
        }
    }

    private var deleteText: String {
        let all = existingTables?.count ?? 0

        switch otherTables.count {
        case 0: return "All tables of \(name) are deleted."
        case 1: return "All \(all) tables of \(name) are deleted, also the 1 table that is not in the dump."
        default: return "All \(all) tables of \(name) are deleted, also the \(otherTables.count) tables that are not in the dump."
        }
    }

    // The first three tables and the number of the others.
    private var examples: String {
        let shown = tables.prefix(3).joined(separator: ", ")
        return tables.count > 3 ? "\(shown) and \(tables.count - 3) more" : shown
    }

    private var copyLine: some View {
        line("archivebox", "Nexus first puts a copy of \(name) in the trash. You can restore it for \(trashDays) days.")
    }

    private func line(_ symbol: String, _ text: String, color: Color = .secondary) -> some View {
        Label {
            Text(text)
                .foregroundStyle(color)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }
}

// The size of the tables on the other server is an estimate for the size of the copy. So the
// text says "about", and the time left shows only when the copy runs for a few seconds. A dump
// file has an exact size only when it is not compressed.
private struct ImportProgress: View {
    let task: TaskInfo?

    private var loadsDump: Bool {
        if case .importDump = task?.work {
            return true
        }

        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(amount)
                Spacer()
                if let timeLeft {
                    Text(timeLeft)
                        .foregroundStyle(.secondary)
                }
            }

            if let task, task.total != nil {
                ProgressView(value: task.fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var amount: String {
        guard let task, task.completed > 0 else {
            return loadsDump ? "Starting the import" : "Starting the copy"
        }

        let done = task.completed.formatted(.byteCount(style: .file))
        let verb = loadsDump ? "Loading" : "Copying"

        guard let total = task.total, total >= task.completed else {
            return "\(verb) \(done)"
        }

        return loadsDump ? "\(verb) \(done) of \(total.formatted(.byteCount(style: .file)))" : "\(verb) \(done) of about \(total.formatted(.byteCount(style: .file)))"
    }

    private var timeLeft: String? {
        guard let task, let total = task.total, total > task.completed, task.completed > 0 else {
            return nil
        }

        let elapsed = Date.now.timeIntervalSince(task.started)
        guard elapsed > 3 else {
            return nil
        }

        let seconds = Double(total - task.completed) / (Double(task.completed) / elapsed)
        let minutes = Int((seconds / 60).rounded())

        switch minutes {
        case 0: return "Less than a minute left"
        case 1: return "About 1 minute left"
        default: return "About \(minutes) minutes left"
        }
    }

    private var detail: String {
        let goesOn = "You can close this sheet. The import goes on."

        guard let task, let table = task.table, let number = task.tableNumber else {
            return goesOn
        }

        let count = task.tableCount.map { " of \($0)" } ?? ""
        return "Table \(table) (\(number)\(count)). \(goesOn)"
    }
}
