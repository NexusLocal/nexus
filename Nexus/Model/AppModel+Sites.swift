import AppKit
import NexusCore
import NexusIPC

extension SiteItem {
    init(_ info: SiteInfo, group: String?) {
        self.init(
            host: info.hosts.first ?? "",
            aliases: Array(info.hosts.dropFirst()),
            group: group,
            folder: (info.folder as NSString).abbreviatingWithTildeInPath,
            documentRoot: (info.documentRoot as NSString).abbreviatingWithTildeInPath,
            server: info.server.rawValue,
            php: info.php,
            health: info.problem == nil ? .stopped : .failed,
            url: info.url,
            parkedFolder: info.parkedFolder.map { ($0 as NSString).abbreviatingWithTildeInPath },
            problem: info.problem,
            hasOwnSettings: !info.parked,
            nodeSetting: info.nodeSetting,
            projectNode: info.projectNode,
            automaticWorkspaces: info.automaticWorkspaces ?? true,
            workspaces: info.workspaces ?? [],
            workspaceProblem: info.workspaceProblem,
            workspaceKeys: info.workspaceKeys ?? [],
            workspaceCommands: info.workspaceCommands ?? [],
            backgroundCommands: info.backgroundCommands,
            workspaceProcesses: info.workspaceProcesses ?? true,
            mainProcesses: info.mainProcesses ?? false,
            processProblems: info.processProblems ?? []
        )
    }
}

// The terminal apps and code editors that a site can open in (D61). Nexus suggests the first one
// that it finds. Other apps come before the apps of Apple, because a user who installed one
// probably uses it.
enum KnownApps {
    static let terminals = [
        "com.thdxg.macterm", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.apple.Terminal",
    ]

    static let editors = [
        "com.jetbrains.PhpStorm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.sublimetext.4", "com.panic.Nova", "com.jetbrains.WebStorm", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.barebones.bbedit", "com.macromates.TextMate",
    ]

    static func installed(_ bundleIdentifiers: [String]) -> [AppChoice] {
        bundleIdentifiers.compactMap { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map {
                AppChoice(name: name(of: $0), location: $0)
            }
        }
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }
}

// The sites, the groups and the folders of projects (step 6, part 6e).
extension AppModel {
    var terminalApp: AppChoice? {
        settings.terminals.first { $0.name == settings.terminal }
    }

    var editorApp: AppChoice? {
        settings.editors.first { $0.name == settings.editor }
    }

    // The sample data keeps the defaults in the settings. "newest" is the newest installed PHP
    // version.
    var siteDefaults: SiteDefaults {
        siteList?.defaults ?? SiteDefaults(
            server: WebServer(rawValue: settings.defaultServer) ?? .nginx,
            php: settings.defaultPHP == "newest" ? nil : settings.defaultPHP,
            node: settings.defaultNode
        )
    }

    // A change does not change the sites that exist (D59).
    func setSiteDefaults(_ defaults: SiteDefaults) {
        guard isLive else {
            settings.defaultServer = defaults.server.rawValue
            settings.defaultPHP = defaults.php ?? "newest"
            settings.defaultNode = defaults.node
            return
        }

        send(.setSiteDefaults(defaults), failure: "The defaults for new sites did not change", place: .window)
    }

    // A PHP version of nil in the defaults is the newest installed version. A default that is not
    // installed anymore also gives the newest version, as in nexusd.
    var defaultPHP: String {
        if let php = siteDefaults.php, installedPHPVersions.contains(php) {
            return php
        }

        return installedPHPVersions.last ?? ""
    }

    // The groups and the sites outside a group in the order of the layout, with the rules of
    // nexusd. Then the folders of projects with their sites outside a group.
    func show(_ list: SiteList, layout: [SiteLayoutEntry]? = nil) {
        let infos = Dictionary(list.sites.map { ($0.hosts.first ?? "", $0) }) { first, _ in first }
        let outside = list.sites.filter { $0.parkedFolder == nil }.compactMap(\.hosts.first)
        let layout = (layout ?? list.layout).normalized(hosts: Set(infos.keys), outside: outside)
        var grouped: Set<String> = []

        var entries: [SiteEntry] = layout.compactMap { entry in
            switch entry {
            case .site(let host):
                return infos[host].map { .site(SiteItem($0, group: nil)) }
            case .group(let name, let hosts):
                grouped.formUnion(hosts)
                return .group(SiteGroup(name: name, sites: hosts.compactMap { infos[$0].map { SiteItem($0, group: name) } }))
            }
        }

        for path in list.parkedFolders {
            let sites = list.sites.filter { $0.parkedFolder == path && !grouped.contains($0.hosts.first ?? "") }
            entries.append(.parked(ParkedFolder(path: (path as NSString).abbreviatingWithTildeInPath, sites: sites.map { SiteItem($0, group: nil) })))
        }

        siteLayout = layout
        useTLD(list.tld)
        siteEntries = entries
    }

    // A new dev TLD renames the open site too, so its screen stays open.
    func useTLD(_ tld: String) {
        if case .site(let host) = selection, tld != settings.tld {
            selection = .site(HostName.movingTLD(host, from: settings.tld, to: tld))
        }

        settings.tld = tld
    }

    // A site runs when nginx, its PHP version and for an Apache site Apache run.
    func health(of site: SiteItem) -> Health {
        guard isLive else {
            return site.health
        }

        if site.problem != nil {
            return .failed
        }

        let needed = ["nginx", "php-\(site.php)"] + (site.server == WebServer.apache.rawValue ? ["apache"] : [])
        let healths = needed.map { service($0)?.health ?? .stopped }

        if healths.allSatisfy({ $0 == .running }) {
            return .running
        }

        if healths.contains(.failed) {
            return .failed
        }

        return healths.contains(.attention) ? .attention : .stopped
    }

    func openInBrowser(_ site: SiteItem) {
        openInBrowser(site.url)
    }

    func openInBrowser(_ link: String) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func showInFinder(_ site: SiteItem) {
        NSWorkspace.shared.activateFileViewerSelecting([site.folderURL])
    }

    func open(_ site: SiteItem, in app: AppChoice) {
        guard let location = app.location else {
            return
        }

        Task {
            do {
                try await NSWorkspace.shared.open([site.folderURL], withApplicationAt: location, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                failure = ActionFailure(title: "\(app.name) did not open \(site.host)", message: error.localizedDescription, place: .window)
            }
        }
    }

    // The sheet shows the failure itself, so the user can change the values. The answer is nil
    // when nexusd added the site or the folder.
    func addSite(folder: URL, host: String, aliases: [String], group: String?, server: WebServer, php: String) async -> String? {
        let request = NexusRequest.addSite(folder: folder.path(percentEncoded: false), host: host, aliases: aliases, php: php, server: server, group: group)
        let failure = await failureMessage(of: request)

        if failure == nil {
            selection = .site(host)
        }

        return failure
    }

    func park(folder: URL, server: WebServer, php: String) async -> String? {
        await failureMessage(of: .park(folder: folder.path(percentEncoded: false), php: php, server: server))
    }

    // The record of a workspace names its running copies. A name rule would also match the copy of
    // another site with the same workspace name.
    func copyProgress(of workspace: WorkspaceInfo) -> Int? {
        let tasks = (workspace.startedCopies ?? []).compactMap { copy in
            importTask(instance: copy.instance, name: copy.name)
        }

        return workspace.copyPercent(runningPercent: tasks.first.map { task in
            guard let total = task.total, total > 0 else {
                return 0
            }

            return min(Int(task.completed * 100 / total), 100)
        })
    }

    func retry(_ workspace: WorkspaceInfo, of site: SiteItem) async {
        _ = await perform(.retryWorkspace(host: site.host, name: workspace.name), failure: "\(workspace.name) did not start again", place: .window)
    }

    // The keys that Nexus sets in the .env of each workspace. A site that is no Laravel application,
    // or an application that the probe cannot read, gives no list.
    func workspaceEnv(of site: SiteItem) async -> [WorkspaceEnvKey] {
        guard case .answer(.workspaceEnv(let keys)) = await outcome(of: .workspaceEnv(host: site.host)) else {
            return []
        }

        return keys
    }

    // A site that is no Laravel application, or an application that the probe cannot read, gives no
    // list.
    func backgroundPreset(of site: SiteItem) async -> [String] {
        guard case .answer(.backgroundPreset(let commands)) = await outcome(of: .backgroundPreset(host: site.host)) else {
            return []
        }

        return commands
    }

    func failureOfEdit(_ site: SiteItem, _ change: SiteChange) async -> String? {
        await failureMessage(of: .editSite(host: site.host, change: change))
    }

    private func failureMessage(of request: NexusRequest) async -> String? {
        switch await outcome(of: request) {
        case .failure(let message):
            message
        case .portInUse(let conflict):
            conflict.description
        case .answer, nil:
            nil
        }
    }

    // The screen keeps the new value while nexusd works. The answer is false when nexusd
    // refused the change, so the screen can show the old value again.
    func editSite(_ site: SiteItem, _ change: SiteChange) async -> Bool {
        guard isLive else {
            return true
        }

        return await perform(.editSite(host: site.host, change: change), failure: "\(site.host) did not change", place: .window) != nil
    }

    func confirm(_ removal: Removal) {
        switch removal {
        case .site(let site):
            send(.removeSite(host: site.host), failure: "\(site.host) was not removed", place: .window) { [weak self] removed in
                if removed, site.parkedFolder == nil, self?.selection == .site(site.host) {
                    self?.selection = .overview
                }
            }
        case .parkedFolder(let folder):
            let path = (folder.path as NSString).expandingTildeInPath
            send(.unpark(folder: path), failure: "Nexus still uses \(folder.name)", place: .window)
        case .package(let package):
            remove(package)
        }
    }

    // A site out of a group goes to the end of the sites outside a group, because the layout
    // does not name it. A site of a parked folder goes back into that folder.
    func move(_ site: SiteItem, toGroup group: String?) {
        changeLayout(siteLayout.moving(site.host, toGroup: group), failure: "\(site.host) did not move")
    }

    func hasGroup(named name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return siteLayout.contains { $0.groupName?.lowercased() == name }
    }

    func createGroup(_ name: String, moving host: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let host, let site = site(host) {
            changeLayout(siteLayout.moving(site.host, toGroup: name), failure: "Nexus did not make the group \(name)")
            return
        }

        changeLayout(siteLayout + [.group(name: name, hosts: [])], failure: "Nexus did not make the group \(name)")
    }

    func renameGroup(_ name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = siteLayout.map { entry in
            entry.groupName == name ? entry.renamed(to: newName) : entry
        }

        CollapsedEntries.rename(SiteGroup.id(named: name), to: SiteGroup.id(named: newName))
        changeLayout(layout, failure: "\(name) did not get the name \(newName)")
    }

    // The sites of the group stay where the group was. A site of a parked folder goes back into
    // that folder, because the layout keeps it only in a group.
    func removeGroup(_ name: String) {
        let layout = siteLayout.flatMap { entry -> [SiteLayoutEntry] in
            guard entry.groupName == name, case .group(_, let hosts) = entry else {
                return [entry]
            }

            return hosts.map(SiteLayoutEntry.site)
        }

        changeLayout(layout, failure: "Nexus did not remove the group \(name)")
    }

    func changeLayout(_ layout: [SiteLayoutEntry], failure title: String) {
        guard let siteList else {
            return
        }

        show(siteList, layout: layout)

        send(.setSiteLayout(layout), failure: title, place: .window) { [weak self] changed in
            if !changed, let list = self?.siteList {
                self?.show(list)
            }
        }
    }
}

private extension SiteLayoutEntry {
    func renamed(to name: String) -> SiteLayoutEntry {
        guard case .group(_, let hosts) = self else {
            return self
        }

        return .group(name: name, hosts: hosts)
    }
}
