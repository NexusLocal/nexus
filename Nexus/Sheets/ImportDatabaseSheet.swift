import NexusCore
import NexusIPC
import SwiftUI

struct ImportDatabaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var instance: String
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
    // The name of the copy that this sheet started. The sample data has no copy.
    @State private var startedName: String?
    @State private var sampleImporting = false

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
        [instance, host, port, user, password].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a database")
                .font(.headline)

            Text("Copy a database from another server into Nexus, for example from MAMP PRO. Nexus only reads the other server.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
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

                    Picker("Database", selection: $database) {
                        if sources.isEmpty {
                            Text(loadingSources ? "Loading…" : "No database").tag("")
                        }

                        ForEach(sources, id: \.name) { source in
                            Text(source.name).tag(source.name)
                        }
                    }
                    .disabled(sources.isEmpty)
                } header: {
                    Text("From")
                } footer: {
                    if let sourcesProblem {
                        Text(sourcesProblem)
                            .foregroundStyle(Color.orangeText)
                    }
                }

                Section("Into") {
                    Picker("Instance", selection: $instance) {
                        ForEach(model.databaseInstances) { Text($0.name).tag($0.id) }
                    }

                    // A text field can write its text back without a change, for example when
                    // it gets the focus. Only another name than the database is an edit.
                    field("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = $0 != database }))

                    Toggle("Replace the database when it exists", isOn: $replace)
                        .toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(importing)

            switch importResult {
            case .failed(let message):
                Label(message, systemImage: "xmark.circle")
                    .foregroundStyle(Color.redText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.errorBackground, in: .rect(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
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

                    Button("Import") {
                        startImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(database.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            useStandardAccount(of: kind)
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
        guard model.isLive else {
            sources = Self.sampleSources
            select(database.isEmpty ? Self.sampleSources[0].name : database)
            return
        }

        guard !host.isEmpty, let number = Int(port) else {
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

        let server = DatabaseServer(host: host, port: number, account: DatabaseAccount(user: user, password: password))
        let result = await model.sourceDatabases(on: server, for: instance)
        guard !Task.isCancelled else {
            return
        }

        switch result {
        case .success(let list):
            sources = list
            sourcesProblem = nil
            select(list.contains { $0.name == database } ? database : list.first?.name ?? "")
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
        if !nameEdited {
            name = database
        }
    }

    private func startImport() {
        guard model.isLive else {
            sampleImporting = true
            return
        }

        let copyName = name.trimmingCharacters(in: .whitespaces)
        let server = DatabaseServer(host: host, port: Int(port), account: DatabaseAccount(user: user, password: password))
        startedName = copyName
        model.startImport(DatabaseCopy(source: server, database: database, instance: instance, name: copyName, replace: replace))
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

    private static let sampleSources = [
        DatabaseSize(name: "3rdrisk_platform", bytes: 2_800_000_000),
        DatabaseSize(name: "shop", bytes: 48_000_000),
        DatabaseSize(name: "crm", bytes: 12_000_000),
    ]

    private static let sampleTask = TaskInfo(
        id: "sample",
        work: .copyDatabase(database: "3rdrisk_platform", instance: "mysql-8.0", name: "3rdrisk_platform"),
        started: .now.addingTimeInterval(-90),
        completed: 1_200_000_000,
        total: 2_800_000_000,
        table: "audit_logs",
        tableNumber: 14,
        tableCount: 63
    )
}

// The size of the tables on the other server is an estimate for the size of the copy. So the
// text says "about", and the time left shows only when the copy runs for a few seconds.
private struct ImportProgress: View {
    let task: TaskInfo?

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
            return "Starting the copy"
        }

        let copied = task.completed.formatted(.byteCount(style: .file))
        guard let total = task.total, total >= task.completed else {
            return "Copying \(copied)"
        }

        return "Copying \(copied) of about \(total.formatted(.byteCount(style: .file)))"
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
