import SwiftUI

struct PackagesScreen: View {
    enum Filter: String, CaseIterable {
        case all = "All"
        case installed = "Installed"
        case updates = "Updates available"
    }

    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    private var sections: [(title: String, packages: [PackageItem])] {
        let visible = model.packages.filter { package in
            switch filter {
            case .all: true
            case .installed: package.isInstalled
            case .updates: if case .update = package.state { true } else { false }
            }
        }

        return Dictionary(grouping: visible, by: \.section)
            .map { (title: $0.key, packages: $0.value) }
            .sorted { sectionOrder($0.title) < sectionOrder($1.title) }
    }

    var body: some View {
        Form {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.packages) { package in
                        PackageRow(package: package)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Packages", subtitle: subtitle)
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
                } label: {
                    Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .labelStyle(.titleAndIcon)
            }

            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    Button("Show packages folder", systemImage: "folder") {}
                }
            }
        }
    }

    private var subtitle: String {
        let installed = model.packages.filter(\.isInstalled).count
        return "\(installed) installed · \(model.updateCount) updates · checked \(model.packagesChecked)"
    }

    private func sectionOrder(_ title: String) -> Int {
        let order = ["Webservers", "PHP", "MySQL", "MariaDB", "PostgreSQL", "Redis", "Node and Composer"]
        return order.firstIndex(of: title) ?? order.count
    }
}

private struct PackageRow: View {
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
        } else if case .update(let version) = package.state {
            Text("\(version) is available.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch package.state {
        case .available:
            Button("Install") {}
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(InstalledLabelStyle())
            Button("Remove…") {}
                .disabled(package.required)
        case .update(let version):
            Button("Update to \(version)") {}
        case .downloading(let progress):
            Text("Downloading")
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .frame(width: 80)
            Button {
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
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
