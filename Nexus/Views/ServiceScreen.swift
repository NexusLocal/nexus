import AppKit
import SwiftUI

struct ServiceScreen: View {
    @Environment(AppModel.self) private var model
    let kind: ServiceKind

    private var versions: [ServiceVersion] {
        model.versions(of: kind)
    }

    private var selectedID: Binding<String> {
        Binding(
            get: {
                if let stored = model.selectedVersion[kind], versions.contains(where: { $0.id == stored }) {
                    return stored
                }

                return versions.first?.id ?? ""
            },
            set: { model.selectedVersion[kind] = $0 }
        )
    }

    private var serviceIndex: Int? {
        model.services.firstIndex { $0.id == selectedID.wrappedValue }
    }

    var body: some View {
        @Bindable var model = model

        Group {
            if let serviceIndex {
                VStack(spacing: 0) {
                    if versions.count > 1 {
                        VersionPicker(versions: versions, selection: selectedID)
                            .padding(.top, 16)
                    }

                    ServiceForm(service: $model.services[serviceIndex])
                }
            } else {
                ContentUnavailableView {
                    Label("No \(kind.title) installed", systemImage: kind.systemImage)
                } description: {
                    Text("Install a version of \(kind.title) in Packages.")
                } actions: {
                    Button("Open Packages") {
                        model.selection = .packages
                    }
                }
            }
        }
        .screenTitle(kind.title, subtitle: subtitle)
        .toolbar {
            if let serviceIndex {
                ServiceToolbar(service: model.services[serviceIndex])
            }
        }
    }

    private var subtitle: String {
        if kind == .webservers {
            return "\(versions.first?.name ?? "nginx") handles all sites"
        }

        let count = versions.count == 1 ? "1 version" : "\(versions.count) versions"

        if let problem = model.problemVersion(of: kind) {
            return "\(count) · \(problem.name) cannot start"
        }

        return versions.allSatisfy(\.isRunning) ? "\(count) · all running" : count
    }
}

// A SwiftUI segmented Picker drops the colored status dots. NSSegmentedControl keeps them.
private struct VersionPicker: NSViewRepresentable {
    let versions: [ServiceVersion]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.ids = versions.map(\.id)
        control.segmentCount = versions.count

        for (index, version) in versions.enumerated() {
            control.setLabel(version.name, forSegment: index)
            control.setImage(.statusDot(version.health), forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setWidth(0, forSegment: index)
        }

        control.selectedSegment = versions.firstIndex { $0.id == selection } ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var ids: [String] = []
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func changed(_ control: NSSegmentedControl) {
            guard ids.indices.contains(control.selectedSegment) else {
                return
            }

            selection.wrappedValue = ids[control.selectedSegment]
        }
    }
}

private struct ServiceToolbar: ToolbarContent {
    let service: ServiceVersion

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!service.isRunning)
        }

        ToolbarItem(placement: .primaryAction) {
            MoreMenu {
                if service.kind.isDatabase {
                    Button("Copy connection URL", systemImage: "link") {
                        copyToPasteboard(service.databaseURL)
                    }
                }

                if service.kind != .dns {
                    Button("Check for updates", systemImage: "arrow.triangle.2.circlepath") {}
                }

                Button("Show config folder", systemImage: "folder") {}

                if service.kind != .dns {
                    Divider()

                    Button("Remove \(service.name)…", systemImage: "trash", role: .destructive) {}
                }
            }
        }
    }
}

private struct ServiceForm: View {
    @Binding var service: ServiceVersion

    var body: some View {
        Form {
            StateSection(service: $service)

            switch service.kind {
            case .webservers:
                WebserverSections(service: $service)
            case .php:
                PHPSections(service: $service)
            case .mysql, .mariadb, .postgresql:
                DatabaseSections(service: $service)
            case .redis, .dns:
                EmptyView()
            }

            if service.kind != .dns {
                LogSection(lines: service.log)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StateSection: View {
    @Environment(AppModel.self) private var model
    @Binding var service: ServiceVersion

    var body: some View {
        Section {
            LabeledContent("Running") {
                HStack {
                    Text(stateText)
                        .foregroundStyle(service.problem == nil ? .secondary : Color.orangeText)

                    Toggle("Running", isOn: Binding(
                        get: { service.isRunning },
                        set: { model.setRunning($0, service: service.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            if !service.version.isEmpty {
                LabeledContent("Version") {
                    HStack {
                        if let update = service.update {
                            Text(service.version)
                                .foregroundStyle(.secondary)
                            Button("Update to \(update)") {}
                        } else {
                            Text("\(service.version) · up to date")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if service.kind == .php {
                LabeledContent("Used by") {
                    Text(service.usedBy.isEmpty ? "No site" : service.usedBy.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 460, alignment: .trailing)
                        .help(service.usedBy.joined(separator: "\n"))
                }
            }

            if [.mysql, .mariadb, .postgresql, .redis, .dns].contains(service.kind), !service.ports.isEmpty {
                PortRow(title: "Port", port: $service.ports[0].number)
            }

            if let dataFolder = service.dataFolder {
                LabeledContent("Data folder") {
                    HStack {
                        PathText(dataFolder)
                        Button("Show in Finder") {}
                    }
                }
            }
        } header: {
            Text(service.name)
        } footer: {
            if let note = service.securityNote {
                Text(note)
                    .foregroundStyle(Color.orangeText)
            } else if let note = service.note {
                Text(note)
            }
        }
    }

    private var stateText: String {
        if let problem = service.problem {
            return problem
        }

        guard service.isRunning else {
            return "stopped"
        }

        return service.since.map { "since \($0)" } ?? "running"
    }
}

private struct WebserverSections: View {
    @Binding var service: ServiceVersion

    private var requiredNames: String {
        let names = service.toggles.filter(\.required).map(\.name)

        guard let last = names.last, names.count > 1 else {
            return names.first ?? ""
        }

        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    var body: some View {
        if service.internalPort {
            Section {
                PortRow(title: "Internal port", port: $service.ports[0].number)
            } header: {
                Text("Port")
            } footer: {
                Text("nginx sends the requests of Apache sites to this port. Only this Mac can reach it.")
            }
        } else {
            Section {
                ForEach($service.ports) { $port in
                    PortRow(title: port.name, port: $port.number)
                }
            } header: {
                Text("Ports")
            } footer: {
                Text("Use 80 and 443 to open sites without a port in the URL. MAMP PRO and Herd also use these ports.")
            }
        }

        Section {
            ToggleGrid(toggles: $service.toggles)
        } header: {
            Text("Modules")
        } footer: {
            Text("\(requiredNames) stay on, because \(service.internalPort ? "Apache needs them behind nginx" : "nginx needs them for every site"). Click a name to see what it does.")
        }
    }
}

private struct PHPSections: View {
    @Binding var service: ServiceVersion

    var body: some View {
        Section {
            ToggleGrid(toggles: $service.toggles)
        } header: {
            Text("Extensions")
        } footer: {
            Text("An extension is on for every site that uses \(service.name). Click a name to see what it does.")
        }

        Section {
            if let error = service.settingsError {
                Label("Line \(error.line): \(error.message). \(service.name) still runs with the old settings.", systemImage: "xmark.circle")
                    .foregroundStyle(Color.redText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.errorBackground, in: .rect(cornerRadius: 6))
            }

            CodeEditor(lines: $service.customSettings, errorLine: service.settingsError?.line)
                .frame(height: 96)
        } header: {
            HStack {
                Text("Custom settings")
                Spacer()
                Button("Revert") {}
                Button("Save and restart") {}
                    .buttonStyle(.borderedProminent)
            }
        } footer: {
            Text("Nexus adds these lines after its own settings in php.ini. Nexus checks the lines before it restarts \(service.name). When a line has an error, \(service.name) keeps the old settings.")
        }
    }
}

private struct DatabaseSections: View {
    @Environment(AppModel.self) private var model
    @Binding var service: ServiceVersion

    var body: some View {
        if service.account != nil {
            Section {
                LabeledContent("User") {
                    TextField("User", text: accountBinding(\.user))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                }

                LabeledContent("Password") {
                    HStack {
                        SecureField("Password", text: accountBinding(\.password), prompt: Text("No password"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 180)
                        Button("Change…") {}
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Nexus uses this account when it imports or opens a database on \(service.name).")
            }
        }

        Section {
            if service.databases.isEmpty {
                Text(service.isRunning ? "No databases yet." : "Start \(service.name) to see its databases.")
                    .foregroundStyle(.secondary)
            }

            ForEach(service.databases) { database in
                HStack(spacing: 10) {
                    Image(systemName: "cylinder")
                        .foregroundStyle(.secondary)
                    MonoText(database.name)
                    Spacer()
                    Text(database.usedBy ?? "No site")
                        .foregroundStyle(.secondary)
                        .frame(width: 160, alignment: .leading)
                    Text(database.size ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                    OpenDatabaseButton(kind: service.kind, url: "\(service.databaseURL)/\(database.name)")
                }
            }
        } header: {
            HStack {
                Text("Databases")
                Spacer()
                Button("Import database…") {
                    model.sheet = .importDatabase(instance: service.id)
                }
            }
        } footer: {
            Text("\"Import database\" copies a database from another server into \(service.name), for example from MAMP PRO. The other server does not change.")
        }
    }

    private func accountBinding(_ keyPath: WritableKeyPath<DatabaseAccount, String>) -> Binding<String> {
        Binding(
            get: { service.account?[keyPath: keyPath] ?? "" },
            set: { service.account?[keyPath: keyPath] = $0 }
        )
    }
}
