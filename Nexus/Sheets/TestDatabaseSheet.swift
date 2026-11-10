import NexusCore
import NexusIPC
import NexusMCP
import SwiftUI

enum TestDatabaseChoice: Hashable {
    case make
    case sqliteMemory
    case other
    case keep
}

// "Choose test database…" and "Change…" of the Databases section. The design is "Sheet Test
// Database" in nexus.pen. Nothing changes until the user clicks the button. Nexus writes only the
// env file of the tests, never phpunit.xml. server is the Nexus server of the development
// database, or nil when that database is on another server or in a SQLite file.
struct TestDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let site: SiteItem
    let folder: URL
    let check: TestDatabaseCheck
    let server: ServiceVersion?
    let choose: (TestDatabaseAction) -> Void

    @State private var choice: TestDatabaseChoice?
    @State private var databases: [DatabaseSize]?
    @State private var listed = false
    @State private var otherDatabase = ""
    @State private var files: TestDatabasePlan.Files?
    @State private var plans: [TestDatabaseChoice: TestDatabasePlan] = [:]
    @State private var conflicts: [TestDatabaseChoice: [String]] = [:]
    @State private var gitStates: [String: TestDatabasePlan.GitState] = [:]

    private var development: String {
        check.developmentDatabaseLabel
    }

    private var testName: String {
        "\(check.developmentDatabase ?? "laravel")_testing"
    }

    private var testDatabaseExists: Bool {
        databases?.contains { $0.name == testName } == true
    }

    // A database that a site or a workspace uses is not free for the tests. A test that resets it
    // would remove the data of that project.
    private var otherDatabases: [String] {
        (databases ?? []).filter { ($0.usedBy ?? []).isEmpty && $0.name != check.developmentDatabase }.map(\.name)
    }

    // Tests that use the development database get the safe choice first, and never "Keep it as it
    // is" without a click. Other tests keep their database until the user picks another one.
    private var selected: TestDatabaseChoice? {
        if let choice {
            return choice
        }

        guard check.usesDevelopmentDatabase else {
            return .keep
        }

        if server != nil, conflicts[.make, default: []].isEmpty {
            return .make
        }

        return conflicts[.sqliteMemory, default: []].isEmpty ? .sqliteMemory : nil
    }

    private var current: String {
        switch check.kind {
        case .development: development
        case .sqliteMemory: "SQLite in memory"
        case .separate: check.database ?? "another database"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a database for the tests")
                .font(.headline)

            Text(intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let blocker {
                Text(blocker)
                    .foregroundStyle(Color.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                option(.make, title: "Make a test database", description: description(of: .make))
                option(.sqliteMemory, title: "Use SQLite in memory", description: description(of: .sqliteMemory))
                option(.other, title: "Use another database", description: description(of: .other))

                if selected == .other, !otherDatabases.isEmpty {
                    Picker("Database", selection: $otherDatabase) {
                        ForEach(otherDatabases, id: \.self) { name in
                            Text(verbatim: name)
                                .tag(name)
                        }
                    }
                    .padding(.leading, 30)
                }

                option(.keep, title: "Keep it as it is", description: description(of: .keep))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line.text)
                            .foregroundStyle(line.warns ? Color.orangeText : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: line.icon)
                            .foregroundStyle(line.warns ? Color.statusOrange : .secondary)
                    }
                    .font(.callout)
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(buttonTitle) {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFinish)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            files = TestDatabasePlan.Files.read(check: check, projectFolder: folder)
            updatePlans()

            let written = [check.testEnvFile, plans.values.compactMap(\.backupFile).first].compactMap { $0 }
            async let states = TestDatabasePlan.gitStates(of: written, in: folder)

            if let server {
                databases = await model.databaseSizes(on: server.id)
                otherDatabase = otherDatabases.first ?? ""
            }

            listed = true
            gitStates = await states
        }
        .onChange(of: otherDatabase) {
            updatePlans()
        }
    }

    // Without APP_ENV in phpunit.xml the tests read .env. An env file of Nexus then has no effect.
    private var blocker: String? {
        guard check.testEnvFile == nil else {
            return nil
        }

        return "\(check.phpunitFile) sets no APP_ENV. So the tests read .env, and Nexus cannot give them other values. Add <env name=\"APP_ENV\" value=\"testing\"/> to \(check.phpunitFile) first."
    }

    private var intro: String {
        check.usesDevelopmentDatabase
            ? "The tests of \(site.host) use \(development), your development database. A test that resets the database removes your local data. Choose what the tests use. Nothing changes until you click the button."
            : "The tests of \(site.host) use \(current). Choose what the tests use. Nothing changes until you click the button."
    }

    private func description(of choice: TestDatabaseChoice) -> String {
        if let keys = conflicts[choice], !keys.isEmpty {
            return "\(check.phpunitFile) sets \(keys.joined(separator: " and ")) itself, and Nexus does not change \(check.phpunitFile). Change that line yourself."
        }

        switch choice {
        case .make:
            guard serverProblem == nil, let server else {
                return serverProblem ?? ""
            }

            return testDatabaseExists
                ? "\(testName) exists on \(server.name). The tests use it."
                : "Nexus makes the empty database \(testName) on \(server.name) for the tests."
        case .sqliteMemory:
            return "The tests use no database server. Some migrations do not work on SQLite."
        case .other:
            guard serverProblem == nil, let server else {
                return serverProblem ?? ""
            }

            return otherDatabases.isEmpty && listed ? "\(server.name) has no database that no site uses." : "Choose a database on \(server.name) that no site uses."
        case .keep:
            return check.usesDevelopmentDatabase
                ? "The tests keep using \(development). Nexus does not show this warning again for this site. Agents still get the warning."
                : "The tests keep using \(current)."
        }
    }

    // Why the sheet cannot make or list a database on the server of the development database.
    private var serverProblem: String? {
        guard let server else {
            return "The development database is not on a server of Nexus."
        }

        return listed && databases == nil ? "Nexus cannot list the databases of \(server.name). Start \(server.name) first." : nil
    }

    private var buttonTitle: String {
        switch selected {
        case .make: testDatabaseExists ? "Use \(testName)" : "Make test database"
        case .sqliteMemory: "Use SQLite in memory"
        case .other: "Use this database"
        case .keep: "Keep it as it is"
        case nil: "Choose"
        }
    }

    private func isAvailable(_ choice: TestDatabaseChoice) -> Bool {
        switch choice {
        case .keep: true
        case .sqliteMemory: plans[.sqliteMemory] != nil
        case .make: plans[.make] != nil && server != nil && databases != nil
        case .other: plans[.other] != nil && !otherDatabases.isEmpty
        }
    }

    private var canFinish: Bool {
        selected.map(isAvailable) ?? false
    }

    // The sheet makes the plans once for each change and not for each draw. Without APP_ENV there
    // is no plan, but the lines of phpunit.xml still explain each choice.
    private func updatePlans() {
        let targets: [TestDatabaseChoice: TestDatabasePlan.Target] = [
            .make: .database(testName),
            .sqliteMemory: .sqliteMemory,
            .other: .database(otherDatabase.isEmpty ? testName : otherDatabase),
        ]

        guard let files else {
            conflicts = targets.mapValues { TestDatabasePlan.phpunitConflicts(for: $0, check: check, projectFolder: folder) }
            return
        }

        plans = targets.compactMapValues { TestDatabasePlan.make(for: $0, check: check, files: files) }
        conflicts = targets.mapValues { TestDatabasePlan.phpunitConflicts(for: $0, check: check, files: files) }
    }

    // Each line that Nexus adds or changes shows before Nexus writes it.
    private var previewLines: [(icon: String, text: String, warns: Bool)] {
        guard let selected, selected != .keep, let plan = plans[selected] else {
            return [("checkmark", "Nothing changes in the files of the project.", false)]
        }

        var lines: [(icon: String, text: String, warns: Bool)] = []

        if plan.createsFile {
            lines.append(("doc.badge.plus", "Nexus makes \(plan.file): a copy of .env with \(plan.changeText). Laravel reads it instead of .env in tests.", false))
        } else if plan.changesNothing {
            lines.append(("checkmark", "\(plan.file) has these values already. Nexus does not change it.", false))
        } else {
            lines.append(("doc", "Nexus sets \(plan.changeText) in \(plan.file). It keeps the old file as \(plan.backupFile ?? "a backup").", false))
        }

        if selected == .make, !testDatabaseExists {
            lines.append(("cylinder", "Nexus makes the empty database \(testName). The migrations of the tests fill it.", false))
        }

        lines.append(("checkmark", ".env and \(check.phpunitFile) stay as they are.", false))

        guard !plan.changesNothing else {
            return lines
        }

        let written = [plan.file] + (plan.backupFile.map { [$0] } ?? [])
        let shown = written.filter { gitStates[$0] == .shown }

        if shown.count == 1 {
            lines.append(("exclamationmark.triangle", "Git does not ignore \(shown[0]). It holds the keys of .env. Add it to .gitignore before you commit.", true))
        } else if !shown.isEmpty {
            lines.append(("exclamationmark.triangle", "Git does not ignore \(shown.joined(separator: " and ")). These files hold the keys of .env. Add them to .gitignore before you commit.", true))
        }

        if gitStates[plan.file] == .tracked {
            lines.append(("exclamationmark.triangle", "Git tracks \(plan.file). So your next commit can include this change.", true))
        }

        return lines
    }

    private func option(_ value: TestDatabaseChoice, title: String, description: String) -> some View {
        let isAvailable = isAvailable(value)

        return ChoiceCard(title: title, detail: description, selected: selected == value) {
            choice = value
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.5)
    }

    private func finish() {
        guard let selected, isAvailable(selected) else {
            return
        }

        guard selected != .keep else {
            if check.usesDevelopmentDatabase {
                choose(.keep)
            }

            dismiss()
            return
        }

        guard let plan = plans[selected] else {
            return
        }

        let makes = server.flatMap { selected == .make && !testDatabaseExists ? NewTestDatabase(name: testName, instance: $0.id) : nil }
        dismiss()
        choose(.use(plan, makes: makes))
    }
}
