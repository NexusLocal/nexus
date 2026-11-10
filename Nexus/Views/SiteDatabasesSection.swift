import NexusCore
import NexusMCP
import SwiftUI

// The database connections of a Laravel site, from the configuration of the application (owner,
// 2026-11-07). The design is the section "Databases" of the frame "Site" in nexus.pen. A connection
// to a server outside Nexus has no Open button, because Nexus does not know its account. The row
// "tests" and the warning of the design "Site Databases Section · Test database" show the database
// of the tests. A workspace has its own database, so only the main folder gets them.
struct SiteDatabasesSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    @State private var databases: [SiteDatabase]?
    @State private var problem: String?
    @State private var tests: TestDatabaseCheck?
    @State private var projectFolder: URL?
    @State private var choosesTestDatabase = false

    private var warnsAboutTests: Bool {
        tests?.usesDevelopmentDatabase == true && !model.keepsTestDatabase(of: site)
    }

    var body: some View {
        Section {
            if let problem {
                MessageText("Nexus cannot read the connections of the application. \(problem)")
            } else if let databases {
                ForEach(databases, id: \.connection) { database in
                    row(database)
                }

                if databases.isEmpty {
                    Text("The application uses no database server.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }

            if let tests {
                if warnsAboutTests {
                    testsWarning(tests)
                } else {
                    testsRow(tests)
                }
            }
        } header: {
            Text("Databases")
        } footer: {
            Text("Nexus finds these connections in the configuration of the application. \"Import dump…\" loads a dump file into that database. \"Open\" uses the app of Settings > Databases > Open with.\(tests != nil && !warnsAboutTests ? " \"tests\" is the database of the tests." : "")")
        }
        .sheet(isPresented: $choosesTestDatabase) {
            if let tests {
                TestDatabaseSheet(site: site, folder: projectFolder ?? site.projectFolder, check: tests, server: testServer) { action in
                    Task {
                        await model.apply(action, to: site)
                        await load()
                    }
                }
            }
        }
        .task(id: "\(site.host) \(site.php) \(site.folder) \(instancePorts)") {
            await load()
        }
        // A change of the .env happens in another app. So the list loads again when Nexus becomes
        // the active app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private var instancePorts: String {
        model.databaseInstances.map { "\($0.id):\($0.ports.first?.number ?? 0)" }.joined(separator: ",")
    }

    private func row(_ database: SiteDatabase) -> some View {
        let service = database.instance.flatMap(model.service)

        return LabeledContent {
            HStack {
                Text(database.database.isEmpty ? "No database name on \(service?.name ?? address(of: database))" : "\(database.database) on \(service?.name ?? address(of: database))")
                    .foregroundStyle(.secondary)
                    .rowValue()

                if let service {
                    if !database.database.isEmpty {
                        Button("Import dump…") {
                            model.sheet = .importDatabase(instance: service.id, dumpInto: database.database)
                        }
                    }

                    OpenDatabaseButton(kind: service.kind, url: service.databaseURL(database.database.isEmpty ? nil : database.database))
                }
            }
        } label: {
            Text(database.connection)
                .font(.system(.body, design: .monospaced))
        }
        .labeledContentStyle(.rowValue)
    }

    private func address(of database: SiteDatabase) -> String {
        database.port.map { "\(database.host):\($0)" } ?? database.host
    }

    // The Nexus server of the development database. Nil for a database on another server or in a
    // SQLite file. The sheet then offers no database of a server.
    private var testServer: ServiceVersion? {
        (databases ?? []).first { $0.database == tests?.developmentDatabase && $0.instance != nil }?.instance.flatMap(model.service)
    }

    private func testsWarning(_ tests: TestDatabaseCheck) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.statusOrange)

            Text("The tests use \(tests.developmentDatabaseLabel), your development database. A test that resets the database removes your local data.")
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Choose test database…") {
                choosesTestDatabase = true
            }
        }
        .padding(10)
        .background(Color.warningBackground, in: .rect(cornerRadius: 8))
    }

    private func testsRow(_ tests: TestDatabaseCheck) -> some View {
        let server = tests.onDevelopmentServer ? testServer?.name : nil
        let value: String = switch tests.kind {
        case .development: "\(tests.developmentDatabaseLabel), the development database"
        case .sqliteMemory: "SQLite in memory, from \(tests.source)"
        case .separate: "\(tests.database ?? "Another database")\(server.map { " on \($0)" } ?? ""), from \(tests.source)"
        }

        return LabeledContent {
            HStack {
                Text(value)
                    .foregroundStyle(tests.usesDevelopmentDatabase ? Color.orangeText : .secondary)
                    .rowValue()

                Button("Change…") {
                    choosesTestDatabase = true
                }
            }
        } label: {
            Text(verbatim: "tests")
                .font(.system(.body, design: .monospaced))
        }
        .labeledContentStyle(.rowValue)
    }

    private func load() async {
        let siteFolder = URL(filePath: site.folder, directoryHint: .isDirectory)
        async let check = Task.detached { () -> (URL, TestDatabaseCheck?) in
            let project = NexusCore.ProjectFolder.projectFolderURL(ofSiteFolder: siteFolder)
            return (project, TestDatabaseCheck.check(projectFolder: project))
        }.value
        let found = await model.siteDatabases(of: site)
        (projectFolder, tests) = await check

        if tests?.usesDevelopmentDatabase != true {
            model.setKeepsTestDatabase(false, of: site)
        }

        switch found {
        case .success(let found):
            databases = found
            problem = nil
        case .failure(let failure):
            databases = []
            problem = failure.message
        }
    }
}
