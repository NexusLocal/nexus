import AppKit
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    // The task below runs again each time the window opens. The launch arguments apply one time.
    private static var launchArgumentsApplied = false

    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var groupName = ""

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            background.registerIfNeeded()

            guard !Self.launchArgumentsApplied else {
                return
            }

            Self.launchArgumentsApplied = true

            if CommandLine.arguments.contains("--first-run") {
                openWindow(id: FirstRunWindow.id)
            }

            #if DEBUG
            DebugLaunch.apply(to: model) { openSettings() }
            #endif
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .addSite(let folder, let manyProjects):
                AddSiteSheet(folder: folder, manyProjects: manyProjects)
            case .editAliases(let host):
                if let site = model.site(host) {
                    EditAliasesSheet(site: site)
                } else {
                    Color.clear
                        .onAppear { model.sheet = nil }
                }
            case .importDatabase(let instance):
                ImportDatabaseSheet(instance: instance)
            case .portInUse(let id, let holder):
                if let service = model.service(id) {
                    PortInUseSheet(service: service, holder: holder)
                } else {
                    Color.clear
                        .onAppear { model.sheet = nil }
                }
            }
        }
        .alert(windowFailure?.title ?? "", isPresented: showsFailure, presenting: windowFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .alert(groupNamingTitle, isPresented: showsGroupNaming, presenting: model.groupNaming) { naming in
            TextField("Name", text: $groupName)
            Button(namingButton(naming)) {
                name(naming)
            }
            .disabled(!isValidGroupName(for: naming))
            Button("Cancel", role: .cancel) {}
        }
        .alert(removalTitle, isPresented: showsRemoval, presenting: model.removal) { removal in
            Button("Remove", role: .destructive) {
                model.confirm(removal)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            switch removal {
            case .site(let site):
                if let parkedFolder = site.parkedFolder {
                    Text("Nexus removes the settings of \(site.host). The folder of projects \(parkedFolder) then makes a site of this project again, with the settings of that folder.")
                } else {
                    Text("The folder and its files stay. Nexus removes only the site.")
                }
            case .parkedFolder(let folder):
                Text(parkedFolderRemoval(folder))
            }
        }
        .onChange(of: model.groupNaming?.id) {
            if case .rename(let name) = model.groupNaming {
                groupName = name
            } else {
                groupName = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            background.refresh()
        }
    }

    private var windowFailure: ActionFailure? {
        model.failure.flatMap { $0.place == .window ? $0 : nil }
    }

    private var groupNamingTitle: String {
        if case .rename(let name) = model.groupNaming {
            return "Rename \(name)"
        }

        return "New group"
    }

    private var showsGroupNaming: Binding<Bool> {
        Binding(
            get: { model.groupNaming != nil },
            set: { shown in
                if !shown {
                    model.groupNaming = nil
                }
            }
        )
    }

    private func namingButton(_ naming: GroupNaming) -> String {
        if case .rename = naming {
            return "Rename"
        }

        return "Create"
    }

    // A rename to the same name with other capitals is a valid change.
    private func isValidGroupName(for naming: GroupNaming) -> Bool {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)

        if case .rename(let old) = naming, old.lowercased() == name.lowercased() {
            return old != name
        }

        return !name.isEmpty && !model.hasGroup(named: name)
    }

    private func name(_ naming: GroupNaming) {
        switch naming {
        case .new(let host):
            model.createGroup(groupName, moving: host)
        case .rename(let old):
            model.renameGroup(old, to: groupName)
        }
    }

    private var removalTitle: String {
        switch model.removal {
        case .site(let site): "Remove \(site.host)?"
        case .parkedFolder(let folder): "Remove the folder of projects \(folder.name)?"
        case nil: ""
        }
    }

    // A project with settings of its own is an added site for nexusd. It stays when its folder of
    // projects goes.
    private func parkedFolderRemoval(_ folder: ParkedFolder) -> String {
        let message = "Its projects are not sites anymore. The folders and their files stay."
        let kept = model.allSites.filter { $0.parkedFolder == folder.path && $0.hasOwnSettings }.map(\.host)

        guard let last = kept.last else {
            return message
        }

        let names = kept.count == 1 ? last : "\(kept.dropLast().joined(separator: ", ")) and \(last)"
        let settings = kept.count == 1 ? "has settings of its own, so it stays a site" : "have settings of their own, so they stay sites"
        return "\(message) \(names) \(settings)."
    }

    private var showsRemoval: Binding<Bool> {
        Binding(
            get: { model.removal != nil },
            set: { shown in
                if !shown {
                    model.removal = nil
                }
            }
        )
    }

    private var showsFailure: Binding<Bool> {
        Binding(
            get: { windowFailure != nil },
            set: { shown in
                if !shown {
                    model.failure = nil
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .site(let host):
            if let site = model.site(host) {
                SiteScreen(site: site)
                    .id(host)
            } else {
                OverviewScreen()
            }
        case .service(let kind):
            ServiceScreen(kind: kind)
                .id(kind)
        case .packages:
            PackagesScreen()
        case .commandLine:
            CommandLineScreen()
        case .overview, nil:
            OverviewScreen()
        }
    }
}

#Preview {
    MainWindow()
        .environment(AppModel.sample())
        .environment(BackgroundServices())
}
