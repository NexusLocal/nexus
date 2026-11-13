import NexusCore
import SwiftUI

struct PackagesScreen: View {
    enum Filter: String, CaseIterable {
        case all = "All"
        case installed = "Installed"
        case updates = "Updates available"
    }

    @Environment(AppModel.self) private var model
    @AppStorage(AppPreference.checkPackageUpdates) private var checkPackageUpdates = true
    @AppStorage(AppPreference.installPackageUpdates) private var installPackageUpdates = true
    @State private var filter = Filter.all

    private var sections: [(title: String, packages: [PackageItem])] {
        let visible = model.packages.filter { package in
            switch filter {
            case .all: true
            case .installed: package.isInstalled
            case .updates: package.hasUpdate
            }
        }

        return Dictionary(grouping: visible, by: \.section)
            .map { (title: $0.key, packages: $0.value.sorted(by: Self.showsBefore)) }
            .sorted { sectionOrder($0.title) < sectionOrder($1.title) }
    }

    var body: some View {
        Form {
            PackageCheckSection {
                filter = .updates
                model.showsPackageCheck = false
            }

            Section {
                Toggle("Check for package updates automatically", isOn: $checkPackageUpdates)
                Toggle("Install package updates automatically", isOn: $installPackageUpdates)
            } header: {
                Text("Automatic updates")
            } footer: {
                Text("Nexus checks at launch and once a day. An update of a package keeps its data. Nexus restarts the service after the update.")
            }

            if let problem = model.installedProblemText {
                Section {
                    MessageText(problem)
                }
            }

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.packages) { package in
                        PackageRow(package: package)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .screenTitle("Packages", subtitle: subtitle)
        .onChange(of: checkPackageUpdates) {
            if checkPackageUpdates {
                Task { await model.checkPackages() }
            }
        }
        .onChange(of: installPackageUpdates) {
            if installPackageUpdates {
                model.installUpdates()
            }
        }
        // Without the automatic check, the first visit reads the manifest. Without it the screen
        // cannot show what Nexus can install.
        .task {
            if model.packagesChecked.isEmpty {
                await model.checkPackages()
            } else {
                await model.loadInstalledRuntimes()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.checkPackagesOnClick()
                } label: {
                    if model.checkingPackages {
                        Label {
                            Text("Checking…")
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.checkingPackages)
            }

            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    Button("Show packages folder", systemImage: "folder") {
                        model.showPackagesFolder()
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let installed = model.packages.filter(\.isInstalled).count
        let checked = model.packagesChecked.isEmpty ? "not checked yet" : "checked \(model.packagesChecked)"
        let updates = Count.text(model.updateCount, "update")
        return "\(installed) installed · \(updates) · \(checked)"
    }

    private func sectionOrder(_ title: String) -> Int {
        let order = ["Webservers", "PHP", "MySQL", "MariaDB", "PostgreSQL", "Redis", "Mail", "Tools"]
        return order.firstIndex(of: title) ?? order.count
    }

    // The design puts nginx before Apache. It puts Node, Composer and WP-CLI in this order. The
    // other rows go from old to new by their names. So Redis 8.10 comes after Redis 8.2.
    private static func showsBefore(_ first: PackageItem, _ second: PackageItem) -> Bool {
        let order = ["nginx", "httpd", "node", "composer", "wp-cli"]
        if first.package != second.package, let firstIndex = order.firstIndex(of: first.package), let secondIndex = order.firstIndex(of: second.package) {
            return firstIndex < secondIndex
        }

        return first.name.compare(second.name, options: .numeric) == .orderedAscending
    }
}

private struct PackageRow: View {
    @Environment(AppModel.self) private var model
    let package: PackageItem

    var body: some View {
        HStack(spacing: 12) {
            Text(package.name)
                .frame(width: 120, alignment: .leading)

            Text(package.version)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            note

            Spacer()

            stateView
        }
    }

    @ViewBuilder
    private var note: some View {
        if let end = package.securityEnd {
            Text(package.securityEnded ? "No security fixes since \(end)." : "Security fixes end on \(end).")
                .foregroundStyle(Color.orangeText)
        } else if let version = package.newVersion {
            Text(version == package.version ? "A new build of \(version) is available." : "\(version) is available.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch package.state {
        case .available:
            Button("Install") {
                model.install(package)
            }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(InstalledLabelStyle())
            Button("Remove…") {
                model.removal = .package(package)
            }
            .disabled(package.required)
            .help(package.required ? "Nexus needs \(package.name)." : "")
        case .update(let version):
            Button(version == package.version ? "Update" : "Update to \(version)") {
                model.install(package)
            }
        case .downloading(let progress):
            Text("Downloading")
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .frame(width: 80)
            Button {
                if let id = package.taskID {
                    model.stopTask(id)
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(package.taskID == nil)
            .help("Stop the download")
        }
    }
}

private struct InstalledLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(Color.statusGreen)
            configuration.title
        }
    }
}
