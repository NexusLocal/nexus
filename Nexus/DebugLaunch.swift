#if DEBUG
import AppKit
import NexusCore
import NexusIPC

// Launch arguments of a debug build that open one screen. They let a check of the look work
// without clicks: --screen service:mysql --sheet port --appearance light --settings network. The
// Add Site sheet can read another folder: --sheet add-site --folder /path. The New site sheet can
// start at a template: --sheet new-site --template wordpress. --alert update-ready shows the window
// of an update that is ready to install. --agents-notice shows the notice of the coding agents on
// the Overview. --notification '<userInfo as JSON>' opens the screen of a click on a notification.
// --sheet old-workspaces --site shop.test opens the sheet of the old workspaces.
// --other-web-servers Local,Herd shows the notice about ports 80 and 443. With --sample, --tld local
// shows the screens with another domain. --waits-for-nexusd
// with --sample shows the banner of a nexusd that still runs an older build. The services of the
// sample data, such as the port problem of --sheet port, need --sample.
// --share-state none|download|build|open-link|build-open|failed changes the link of shop.test.
// --share-panel opens its panel. --public-links many gives 7 links. --sheet share --site shop.test
// --share-preview warnings|vite-build|own-domain opens the confirm sheet. --alert quit-links shows
// the question of a quit. --post-notification link-stopped posts the notification after a sleep.
// --own-domain connected|connecting|failed gives the own domain of 4h. --settings sharing
// --own-domain-sheet domain|not-on-cloudflare|connect|connected opens its setup at that step. Each
// of them needs --sample.
// --sheet move-from-herd --herd-move review|states|progress|quit-herd|done|failed opens a state of
// the move from Herd. --herd-notice move|moved shows its notice on the Overview. Both need --sample.
enum DebugLaunch {
    // A check of the look does not get the first run on top of the screen that it checks.
    static var checksTheLook: Bool {
        ["--sample", "--screen", "--sheet", "--settings", "--appearance", "--version", "--alert", "--agents-notice", "--notification", "--waits-for-nexusd"].contains(where: CommandLine.arguments.contains)
    }

    // --background keeps the app behind the other apps, for a check while the user works on this
    // Mac.
    static func apply(to model: AppModel, openSettings: () -> Void) {
        HangWatchdog.shared.start()

        if !CommandLine.arguments.contains("--background") {
            NSApplication.shared.activate()
        }

        if CommandLine.arguments.contains("--sample"), let tld = value(of: "--tld").flatMap({ try? HostName.validatedTLD($0) }) {
            model.settings.tld = tld
        }

        if let tab = value(of: "--settings") {
            UserDefaults.standard.set(tab, forKey: SettingsWindow.tabKey)
            openSettings()
        }

        if let appearance = value(of: "--appearance") {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        if let screen = value(of: "--screen") {
            model.selection = selection(screen)
        }

        if CommandLine.arguments.contains("--sample"), let names = value(of: "--other-web-servers") {
            model.setSampleWebPorts(http: OtherWebServers.webPorts.http, https: OtherWebServers.webPorts.https)
            model.otherWebServers = names.split(separator: ",").map(String.init)
            model.hiddenWebServerNotice = []
        }

        if CommandLine.arguments.contains("--waits-for-nexusd") {
            model.showNexusdUpdateForCheck()
        }

        if CommandLine.arguments.contains("--agents-notice") {
            model.agents.showsNoticeForCheck = true
        }

        if let state = value(of: "--dumps") {
            showDumps(state, in: model)
        }

        if let version = value(of: "--version"), let service = model.service(version) {
            model.selectedVersion[service.kind] = service.id
        }

        if CommandLine.arguments.contains("--sample") {
            showPublicLinks(in: model)
        }

        if CommandLine.arguments.contains("--sample"), let state = value(of: "--herd-notice") {
            model.showSampleHerdNotice(state)
        }

        if let json = value(of: "--notification"), let userInfo = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let target = NotificationTarget(userInfo: userInfo) {
            model.show(target)
        }

        switch value(of: "--sheet") {
        case "new-site":
            if let template = value(of: "--template") {
                UserDefaults.standard.set(template, forKey: NewSiteSheet.templateKey)
            }
            model.sheet = .newSite

            // --create shop --folder /path starts the site at once, for a check of the steps, the
            // failure and the password without clicks. A wrong --locale gives a failure.
            if let name = value(of: "--create"), let folder = value(of: "--folder") {
                let template = value(of: "--template").flatMap(SiteTemplate.init(rawValue:)) ?? .vite
                model.startNewSite(NewSite(template: template, name: name, parent: folder, database: value(of: "--database"), locale: value(of: "--locale") ?? WordPressLocale.english))
            }
        case "import-site":
            let backup = value(of: "--backup").map { URL(filePath: $0) }
            model.sheet = .importSite(backup: backup)

            // --import foo --folder /path starts the import at once, for a check without clicks.
            if let backup, let name = value(of: "--import"), let folder = value(of: "--folder") {
                model.startImport(SiteImport(backup: backup.path(percentEncoded: false), name: name, parent: folder, database: value(of: "--database")), format: nil)
            }
        case "add-site": model.sheet = .addSite(folder: value(of: "--folder").map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL(filePath: NSHomeDirectory()).appending(path: "Documents/clients/foo"), manyProjects: false)
        // --dump-file /path opens the sheet with a dump file and no file panel. --dump-into shop
        // opens it as "Import dump…" of the Site screen does.
        case "import":
            ImportDatabaseSheet.debugDumpFile = value(of: "--dump-file").map { URL(filePath: $0) }
            model.sheet = .importDatabase(instance: value(of: "--instance") ?? "mysql-8.0", dumpInto: value(of: "--dump-into"))
        case "port":
            if let blocked = model.blockedServices.first {
                model.sheet = .portInUse(service: blocked.service.id, holder: blocked.holder)
            }
        case "old-workspaces":
            model.sheet = .oldWorkspaces(host: value(of: "--site") ?? "shop.test")
        case "share":
            ShareSheet.debugPreview = value(of: "--share-preview")
            model.sheet = .share(host: value(of: "--site") ?? "shop.test")
        case "move-from-herd":
            if CommandLine.arguments.contains("--sample") {
                model.showSampleHerdMove(value(of: "--herd-move") ?? "review")
            }
            model.sheet = .moveFromHerd
        default: break
        }
    }

    // The frames of the public links in nexus.pen (group 4, 4g).
    private static func showPublicLinks(in model: AppModel) {
        if let state = value(of: "--share-state") {
            model.showSampleShareState(state)
        }

        if value(of: "--public-links") == "many" {
            model.addSampleLinks()
        }

        if let state = value(of: "--own-domain") {
            model.settings.ownDomain = AppModel.sampleOwnDomain(state)
        }

        OwnDomainSheet.debugStep = value(of: "--own-domain-sheet").flatMap(OwnDomainSheet.Step.init(rawValue:))

        // The popover needs the toolbar of the Site screen. So it opens a moment later.
        if CommandLine.arguments.contains("--share-panel") {
            model.selection = .site("shop.test")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                model.sharePanelHost = "shop.test"
            }
        }

        if value(of: "--post-notification") == "link-stopped" {
            Notifier.post(ShareText.stoppedTitle("shop.test"), ShareText.sleepNotification, target: .publicLink(host: "shop.test"), setting: AppPreference.notifyLinkStopped, category: PublicLinkNotification.categoryID)
        }

        if value(of: "--alert") == "quit-links" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                _ = QuitQuestion.confirm(linkCount: model.activePublicLinks.count)
            }
        }
    }

    // --dumps off|empty|filter|blocked|problem shows a state of "Dumps States" in the design. jobs
    // adds the job entries of "Dumps Jobs". link shows "Dumps · Public link" with the filter of the
    // link of shop.test (group 4, 4f). It needs --sample. The filter is the choice of the user, so
    // it is not part of the list.
    // --dump-request sample-order --dump-tab logs opens a request at a tab. --dump-groups-open opens
    // each group of the Queries tab.
    private static func showDumps(_ state: String, in model: AppModel) {
        model.show(AppModel.sampleDumpList(state))

        if state == "filter" {
            model.filterDumps(by: .place(DumpPlaceChoice(place: DumpPlace(site: "crm.test"), label: "crm.test")))
        }

        if state == "link" {
            model.filterDumps(by: .link(host: "shop.test", label: LinkRequestText.filterLabel(host: "shop.test", linkCount: 1)))
        }

        if let tab = value(of: "--dump-tab").flatMap(DumpEntryTab.init(rawValue:)) {
            model.chosenDumpTab = tab
        }

        if let id = value(of: "--dump-request") {
            model.openDumpRequest(id)
        }

        OpenQueries.debugOpensGroups = CommandLine.arguments.contains("--dump-groups-open")
    }

    private static func selection(_ screen: String) -> SidebarItem {
        let parts = screen.split(separator: ":", maxSplits: 1).map(String.init)

        switch (parts.first, parts.last) {
        case ("site", let host?): return .site(host)
        case ("service", let kind?): return ServiceKind(rawValue: kind).map(SidebarItem.service) ?? .overview
        case ("agents", _): return .agents
        case ("command-line", _): return .commandLine
        case ("dumps", _): return .dumps
        case ("logs", let host?):
            // --screen logs:shop.test opens the Logs screen on that site, when the site loads.
            if parts.count == 2 {
                UserDefaults.standard.set(host, forKey: LogsModel.chosenPlaceKey)
            }

            return .logs
        case ("packages", _): return .packages
        default: return .overview
        }
    }

    private static func value(of name: String) -> String? {
        let arguments = CommandLine.arguments

        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}
#endif
