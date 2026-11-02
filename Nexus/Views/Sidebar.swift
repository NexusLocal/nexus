import AppKit
import SwiftUI

// The closed groups and folders of projects, by their id, also after a new launch. A renamed group
// stays closed. The id of a group that is gone leaves the list.
enum CollapsedEntries {
    static let key = "sidebarCollapsedEntries"

    static func decode(_ list: String) -> Set<String> {
        Set(list.split(separator: "\n").map(String.init))
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }

    static func rename(_ id: String, to newID: String) {
        var ids = decode(UserDefaults.standard.string(forKey: key) ?? "")

        if ids.remove(id) != nil {
            ids.insert(newID)
            UserDefaults.standard.set(encode(ids), forKey: key)
        }
    }
}

// The sidebar keeps which sections and groups are closed, also after a new launch. The id of a
// site row names its group or folder too. Without that, the list of macOS 27 kept an old row on
// the screen when a site moved into a group or out of one.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarSitesExpanded") private var sitesExpanded = true
    @AppStorage("sidebarServicesExpanded") private var servicesExpanded = true
    @AppStorage("sidebarToolsExpanded") private var toolsExpanded = true
    @AppStorage(CollapsedEntries.key) private var collapsedList = ""

    private var collapsedEntries: Set<String> {
        get { CollapsedEntries.decode(collapsedList) }
        nonmutating set { collapsedList = CollapsedEntries.encode(newValue) }
    }

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
                            ForEach(group.sites) { SiteRow(site: $0).id("\(group.id) \($0.host)") }
                        } label: {
                            CountRow(title: group.name, systemImage: "folder", count: group.sites.count)
                                .contextMenu {
                                    Button("Rename group…", systemImage: "pencil") {
                                        model.groupNaming = .rename(group.name)
                                    }
                                    Button("Remove group", systemImage: "folder.badge.minus") {
                                        model.removeGroup(group.name)
                                    }
                                    .help("The sites stay. They leave the group.")
                                }
                        }
                    case .parked(let folder):
                        DisclosureGroup(isExpanded: expansion(of: folder.id)) {
                            ForEach(folder.sites) { SiteRow(site: $0).id("\(folder.id) \($0.host)") }
                        } label: {
                            CountRow(title: folder.name, systemImage: ParkedFolder.systemImage, count: folder.sites.count)
                                .help("\(folder.path)\nNexus makes a site of each project in this folder, also of new projects.")
                                .contextMenu {
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: (folder.path as NSString).expandingTildeInPath)])
                                    }

                                    Divider()

                                    Button("Remove folder of projects…", systemImage: "trash", role: .destructive) {
                                        model.removal = .parkedFolder(folder)
                                    }
                                }
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
        .onChange(of: model.siteEntries.map(\.id)) { _, ids in
            let kept = collapsedEntries.intersection(ids)

            if kept != collapsedEntries {
                collapsedEntries = kept
            }
        }
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
        collapsedEntries = Set(model.siteEntries.filter { if case .site = $0 { false } else { true } }.map(\.id))
    }

    private func expandAll() {
        collapsedEntries = []
        sitesExpanded = true
        servicesExpanded = true
        toolsExpanded = true
    }
}

private struct SiteRow: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    var body: some View {
        HStack {
            Label(site.host, systemImage: "globe")
                .lineLimit(1)
            Spacer()
            StatusDot(health: model.health(of: site))
        }
        .help(site.problem.map { "\(site.host) does not run. \($0)" } ?? "")
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
            present(.addSite(folder: nil, manyProjects: false))
        }
        .keyboardShortcut("n")

        Button("Add folder of projects…", systemImage: ParkedFolder.systemImage) {
            present(.addSite(folder: nil, manyProjects: true))
        }

        Button("New group", systemImage: "folder.badge.plus") {
            model.groupNaming = .new(movingSite: nil)
            openWindow(id: MainWindow.id)
        }
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

// A site of a parked folder goes away with its folder. So it has no "Remove site", unless it has
// settings of its own. Then "Remove site" removes those settings.
struct SiteActions: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem
    var includeBrowser = true

    var body: some View {
        if includeBrowser {
            Button("Open in browser", systemImage: "safari") {
                model.openInBrowser(site)
            }
        }

        Button("Show in Finder", systemImage: "folder") {
            model.showInFinder(site)
        }

        if let terminal = model.terminalApp {
            Button("Open in \(terminal.name)", systemImage: "apple.terminal") {
                model.open(site, in: terminal)
            }
        }

        if let editor = model.editorApp {
            Button("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") {
                model.open(site, in: editor)
            }
        }

        Button("Copy URL", systemImage: "link") {
            copyToPasteboard(site.url)
        }

        Divider()

        Menu("Move to group", systemImage: "folder.badge.plus") {
            ForEach(model.groupNames, id: \.self) { group in
                Button(group) {
                    model.move(site, toGroup: group)
                }
                .disabled(site.group == group)
            }

            Divider()

            Button("No group") {
                model.move(site, toGroup: nil)
            }
            .disabled(site.group == nil)

            Button("New group…") {
                model.groupNaming = .new(movingSite: site.host)
            }
        }

        if site.parkedFolder == nil || site.hasOwnSettings {
            Divider()

            Button("Remove site…", systemImage: "trash", role: .destructive) {
                model.removal = .site(site)
            }
        }
    }
}
