import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var sitesExpanded = true
    @State private var servicesExpanded = true
    @State private var toolsExpanded = true
    @State private var collapsedEntries: Set<String> = []

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(SidebarItem.overview)

            Section("Sites", isExpanded: $sitesExpanded) {
                ForEach(model.filteredEntries()) { entry in
                    switch entry {
                    case .site(let site):
                        SiteRow(site: site)
                    case .group(let group):
                        DisclosureGroup(isExpanded: expansion(of: group.id)) {
                            ForEach(group.sites) { SiteRow(site: $0) }
                        } label: {
                            CountRow(title: group.name, systemImage: "folder", count: group.sites.count)
                        }
                    case .parked(let folder):
                        DisclosureGroup(isExpanded: expansion(of: folder.id)) {
                            ForEach(folder.sites) { SiteRow(site: $0) }
                        } label: {
                            CountRow(title: folder.name, systemImage: ParkedFolder.systemImage, count: folder.sites.count)
                                .help("\(folder.path)\nNexus makes a site of each project in this folder, also of new projects.")
                        }
                    }
                }
            }

            Section("Services", isExpanded: $servicesExpanded) {
                ForEach(ServiceKind.allCases) { kind in
                    ServiceKindRow(kind: kind)
                        .tag(SidebarItem.service(kind))
                }
            }

            Section("Tools", isExpanded: $toolsExpanded) {
                HStack {
                    Label("Packages", systemImage: "shippingbox")
                    Spacer()

                    if model.updateCount > 0 {
                        Text("\(model.updateCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: .capsule)
                            .help("\(model.updateCount) updates")
                    }
                }
                .tag(SidebarItem.packages)

                Label("Command line", systemImage: "apple.terminal")
                    .tag(SidebarItem.commandLine)
            }
        }
        .listStyle(.sidebar)
        .toolbar(removing: .sidebarToggle)
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search sites")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBottomBar(collapseAll: collapseAll, expandAll: expandAll)
        }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedEntries.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedEntries.remove(id)
                } else {
                    collapsedEntries.insert(id)
                }
            }
        )
    }

    private func collapseAll() {
        collapsedEntries = Set(model.siteEntries.map(\.id))
    }

    private func expandAll() {
        collapsedEntries = []
        sitesExpanded = true
        servicesExpanded = true
        toolsExpanded = true
    }
}

private struct SiteRow: View {
    let site: SiteItem

    var body: some View {
        HStack {
            Label(site.host, systemImage: "globe")
                .lineLimit(1)
            Spacer()
            StatusDot(health: site.health)
        }
        .tag(SidebarItem.site(site.host))
        .contextMenu {
            SiteActions(site: site)
        }
    }
}

private struct CountRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ServiceKindRow: View {
    @Environment(AppModel.self) private var model
    let kind: ServiceKind

    var body: some View {
        HStack {
            Label(kind.title, systemImage: kind.systemImage)
            Spacer()

            if let problem = model.problemVersion(of: kind) {
                Text(problem.version.split(separator: ".").prefix(2).joined(separator: "."))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.orangeText)
                    .help("\(problem.name): \(problem.problem?.detail ?? "needs attention")")
            }

            StatusDot(health: model.health(of: kind))
        }
    }
}

private struct SidebarBottomBar: View {
    @Environment(AppModel.self) private var model
    let collapseAll: () -> Void
    let expandAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Menu {
                    AddMenuItems()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add")

                Menu {
                    Button("Sort by name", systemImage: "arrow.up.arrow.down") {
                        model.sortByName()
                    }

                    Divider()

                    Button("Collapse all", systemImage: "arrow.down.right.and.arrow.up.left", action: collapseAll)
                    Button("Expand all", systemImage: "arrow.up.left.and.arrow.down.right", action: expandAll)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Sort")

                Spacer()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

// The File menu shows these items too, also when the main window is closed. Each item opens the
// main window, which shows the sheet or the screen.
struct AddMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Add site…", systemImage: "globe") {
            present(.addSite)
        }
        .keyboardShortcut("n")

        Button("Add folder of projects…", systemImage: ParkedFolder.systemImage) {
            present(.addSite)
        }

        Button("New group", systemImage: "folder.badge.plus") {}
            .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        Button("Import database…", systemImage: "cylinder.split.1x2") {
            present(.importDatabase(instance: model.databaseInstances.first?.id ?? ""))
        }

        Button("Install packages…", systemImage: "shippingbox") {
            model.selection = .packages
            openWindow(id: MainWindow.id)
        }
    }

    private func present(_ sheet: SheetKind) {
        model.sheet = sheet
        openWindow(id: MainWindow.id)
    }
}

struct SiteActions: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem
    var includeBrowser = true

    var body: some View {
        if includeBrowser {
            Button("Open in browser", systemImage: "safari") {}
        }

        Button("Show in Finder", systemImage: "folder") {}
        Button("Open in \(model.settings.terminal)", systemImage: "apple.terminal") {}
        Button("Open in \(model.settings.editor)", systemImage: "chevron.left.forwardslash.chevron.right") {}

        Button("Copy URL", systemImage: "link") {
            copyToPasteboard(site.url)
        }

        Divider()

        Menu("Move to group", systemImage: "folder.badge.plus") {
            ForEach(model.groupNames, id: \.self) { group in
                Button(group) {}
                    .disabled(site.group == group)
            }

            Divider()

            Button("No group") {}
                .disabled(site.group == nil)
            Button("New group…") {}
        }

        Divider()

        Button("Remove site…", systemImage: "trash", role: .destructive) {}
    }
}
