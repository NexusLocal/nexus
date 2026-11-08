import NexusCore
import SwiftUI

// The database connections of a Laravel site, from the configuration of the application (owner,
// 2026-11-07). The design is the section "Databases" of the frame "Site" in nexus.pen. A connection
// to a server outside Nexus has no Open button, because Nexus does not know its account.
struct SiteDatabasesSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    @State private var databases: [SiteDatabase]?
    @State private var problem: String?

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
        } header: {
            Text("Databases")
        } footer: {
            Text("Nexus finds these connections in the configuration of the application. \"Open\" uses the app of Settings > Databases > Open with.")
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

    private func load() async {
        switch await model.siteDatabases(of: site) {
        case .success(let found):
            databases = found
            problem = nil
        case .failure(let failure):
            databases = []
            problem = failure.message
        }
    }
}
