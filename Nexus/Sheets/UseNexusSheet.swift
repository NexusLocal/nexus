import NexusCore
import NexusIPC
import SwiftUI

// "Use Nexus…" asks first (owner, 2026-11-14). The design is "Sheet Use Nexus" and "Sheet Use Nexus
// · Copying" in nexus.pen. Each row shows a key with its old and its new value. The popup in the
// header of the database group chooses the instance. A copy shows its progress, and the user can
// close the sheet while it runs. Without a copy the sheet closes at once, as "Send mail to Nexus".
struct UseNexusSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let info: UseNexusInfo

    @State private var instance: String?
    @State private var copies = true
    @State private var errorReport: ErrorReport?

    init(info: UseNexusInfo) {
        self.info = info
        _instance = State(initialValue: info.database?.choices.first?.instance)
    }

    private var choice: UseNexusChoice? {
        info.database?.choices.first { $0.instance == instance }
    }

    private var run: UseNexusRun? {
        model.useNexusRuns[info.host]
    }

    private var copying: Bool {
        guard let run else {
            return false
        }

        return run.request.copy && run.result == nil
    }

    // nexusd starts the task of the copy after its checks. Before that, a stop has no task.
    private var canStop: Bool {
        !model.isLive || model.useNexusTask(of: info.host) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(info.sheetTitle)
                .font(.headline)

            Text("Nexus changes these keys in the .env of the main checkout. The old values stay as comment lines that start with \"\(EnvFile.commentStart)\".")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                if let appURL = info.appURL {
                    Section {
                        EnvKeyRow(appURL)
                    } header: {
                        Text("Site")
                    }
                }

                if let database = info.database {
                    Section {
                        ForEach(choice?.changes ?? [], id: \.key) { change in
                            EnvKeyRow(change)
                        }
                    } header: {
                        HStack {
                            Text("Database")
                            Spacer()
                            Picker("Instance", selection: $instance) {
                                ForEach(database.choices, id: \.instance) { choice in
                                    Text(choice.name).tag(Optional(choice.instance))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    } footer: {
                        databaseFooter(database.database)
                    }
                }

                if !info.redis.isEmpty {
                    Section {
                        ForEach(info.redis, id: \.key) { change in
                            EnvKeyRow(change)
                        }
                    } header: {
                        Text("Redis")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(copying)

            switch run?.result {
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

            if copying {
                ImportProgress(task: model.isLive ? model.useNexusTask(of: info.host) : Self.sampleTask, goesOn: "You can close this sheet. Nexus changes the .env after the copy.")
            } else {
                Text("A queue worker reads the new values after a restart.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                if copying {
                    Button("Stop copy") {
                        model.stopUseNexusCopy(of: info.host)
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

                    Button("Use Nexus") {
                        useNexus()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
        .onAppear {
            model.useNexusInSheet = info.host

            if let run {
                instance = run.request.instance
                copies = run.request.copy
            }
        }
        .onDisappear {
            if model.useNexusInSheet == info.host {
                model.useNexusInSheet = nil
            }

            if run?.result != nil {
                model.useNexusRuns[info.host] = nil
            }
        }
        .onChange(of: model.useNexusDone[info.host] != nil) { _, isDone in
            if isDone {
                dismiss()
            }
        }
    }

    // A copy needs a database on the old server that the instance does not have. Without a copy,
    // Nexus makes the database empty on the instance.
    @ViewBuilder
    private func databaseFooter(_ database: String?) -> some View {
        if let choice, let database, choice.canCopy {
            Toggle(isOn: $copies) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.copyTitle(database: database))
                    Text(choice.copyHelp(database: database))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        } else if let text = choice?.emptyDatabaseText(database: database) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func useNexus() {
        let request = UseNexusRequest(
            host: info.host,
            instance: choice?.instance,
            copy: choice?.canCopy == true && copies,
            changes: info.changes(choosing: choice?.instance)
        )

        model.startUseNexus(request, database: info.database?.database)

        if !request.copy {
            dismiss()
        }
    }

    private static let sampleTask = TaskInfo(
        id: "sample",
        work: .copyDatabase(database: "shop", instance: "mysql-8.4", name: "shop"),
        started: .now.addingTimeInterval(-90),
        completed: 1_200_000_000,
        total: 2_800_000_000,
        table: "audit_logs",
        tableNumber: 14,
        tableCount: 63
    )
}
