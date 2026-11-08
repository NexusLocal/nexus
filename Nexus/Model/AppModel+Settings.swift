import AppKit
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import ServiceManagement
import UserNotifications

// The lists of apps that the user can add to, because Nexus did not find an app (D36, D61).
enum AppRole {
    case terminal
    case editor
    case database

    var addedKey: String {
        switch self {
        case .terminal: AppPreference.addedTerminals
        case .editor: AppPreference.addedEditors
        case .database: AppPreference.addedDatabaseApps
        }
    }
}

// The database apps that macOS knows for the link of each kind. Nexus cannot ask an added app
// which links it opens. So an added app gets the links of every kind.
enum DatabaseApps {
    static let allKinds = "MySQL, MariaDB, PostgreSQL"

    static func found() -> [AppChoice] {
        let mysql = apps(opening: "mysql://127.0.0.1")
        let postgresql = apps(opening: "postgresql://127.0.0.1")
        var seen: Set<URL> = []

        return (mysql + postgresql).filter { seen.insert($0).inserted }.map { app in
            let kinds = (mysql.contains(app) ? ["MySQL", "MariaDB"] : []) + (postgresql.contains(app) ? ["PostgreSQL"] : [])
            return AppChoice(name: KnownApps.name(of: app), opens: kinds.joined(separator: ", "), location: app)
        }
    }

    static func defaultApp(for kind: ServiceKind) -> URL? {
        URL(string: kind == .postgresql ? "postgresql://127.0.0.1" : "mysql://127.0.0.1").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    private static func apps(opening link: String) -> [URL] {
        URL(string: link).map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
    }
}

// The app icon shows in the Dock, in the menu bar or in both (D5). Without the Dock icon, Nexus
// is an app of the menu bar only.
enum AppPresence {
    static func apply() {
        NSApplication.shared.setActivationPolicy(AppPreference.isOn(AppPreference.showInDock) ? .regular : .accessory)
    }
}

// macOS asks the user one time if Nexus may show notifications (D61). macOS shows no
// notification while Nexus is the active app. The window shows the same news then.
enum Notifier {
    static let settingsLink = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(NexusIdentifiers.app)")

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    // A user who missed the question of macOS or said no turns the notifications on in System
    // Settings.
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(_ title: String, _ body: String, setting key: String) {
        guard AppPreference.isOn(key) else {
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()

            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = ErrorDetails.split(body).text
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// The PATH setting (D39). The sample data never touches ~/.zshrc.
extension AppModel {
    static let nexusCommand = Bundle.main.bundleURL.resolvingSymlinksInPath().appending(path: "Contents/Helpers/nexus")

    func readPathSetting() {
        guard isLive else {
            return
        }

        pathSetting = ShellPathLine.standard.state()
        pathSettingProblem = nil
        checkShellCommands()
    }

    // Without the PATH setting the terminal does not use Nexus. That is no problem then.
    // The check starts the shell files of the user. So it runs again only after a change of the
    // setting or of a shell file, and not at each view of a screen. A new check stops the check
    // before it. So an older answer cannot replace a newer one.
    func checkShellCommands(again: Bool = false) {
        if again {
            shellCommandsStamp = nil
        }

        guard pathSetting != .off else {
            shellCommandsCheck?.cancel()
            shellCommandsStamp = nil
            otherShellCommands = []
            return
        }

        let stamp = ShellCommands.files(home: FileManager.default.homeDirectoryForCurrentUser).map { file in
            ((try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path(percentEncoded: false)))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }

        guard stamp != shellCommandsStamp else {
            return
        }

        shellCommandsCheck?.cancel()
        shellCommandsStamp = stamp
        shellCommandsCheck = Task {
            let others = await Self.otherShellCommands()

            guard !Task.isCancelled, pathSetting != .off else {
                return
            }

            if others == nil {
                shellCommandsStamp = nil
            }

            otherShellCommands = others ?? []
        }
    }

    // A new login shell of zsh reads the shell files as a new terminal window does. A shell file
    // that waits for input stops the check after 10 seconds. The check then shows nothing and
    // runs again at the next view of a screen. An interactive zsh ignores SIGTERM, so the stop
    // uses SIGKILL.
    nonisolated private static func otherShellCommands() async -> [OtherCommand]? {
        let command = Command(
            executable: URL(filePath: "/bin/zsh"),
            arguments: ["-l", "-i", "-c", ShellCommands.script],
            environment: ["USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": "/bin/zsh"],
            stopSignal: SIGKILL
        )

        let output = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await CommandRunner.run(command).standardOutput }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let output else {
            return nil
        }

        return ShellCommands.others(in: output, bin: NexusPaths.standard.bin)
    }

    var shellWarningTitle: String {
        let names = otherShellCommands.map(\.name)
        return "\(EnglishList.joined(names)) in your terminal \(names.count == 1 ? "does" : "do") not use Nexus"
    }

    // A command that is not found has another cause and another fix than an alias.
    var shellWarningReasons: [String] {
        let found = otherShellCommands.filter { !$0.isNotFound }
        var reasons: [String] = []

        if !found.isEmpty {
            reasons.append(found.allSatisfy { $0.description.hasPrefix("\($0.name) is an alias for ") }
                ? "An alias in your shell files wins over the PATH. Remove it to use the Nexus version."
                : "An alias, a function or a later change to the PATH in your shell files wins over the line of Nexus. Remove it to use the Nexus version.")
        }

        if otherShellCommands.contains(where: \.isNotFound) {
            reasons.append("A command that is not found has no working link in the bin folder of Nexus. Turn the setting off and on to make the links again.")
        }

        return reasons
    }

    // Returns false when ~/.zshrc did not change. The reason shows below the setting. nexusd
    // makes the links in bin/ at its start. The app makes them again when the setting turns on.
    // So the links of an app that moved work again without a new start of nexusd.
    @discardableResult
    func setAddToPath(_ on: Bool) -> Bool {
        guard isLive else {
            pathSetting = on ? .on : .off
            pathSettingProblem = nil
            return true
        }

        var problem: String?

        do {
            let line = ShellPathLine.standard
            try on ? line.turnOn() : line.turnOff()

            if on, CommandLinks.canPoint(to: Self.nexusCommand) {
                try CommandLinks.write(in: NexusPaths.standard.bin, command: Self.nexusCommand)
            }
        } catch {
            problem = "Nexus could not change ~/.zshrc or the links in its bin folder. \(error.localizedDescription)"
        }

        readPathSetting()
        pathSettingProblem = problem
        return problem == nil
    }
}

// Settings (step 6, part 6g).
extension AppModel {
    // The found apps come first, then the added apps that still exist. A name shows once. A
    // database app that the user removed does not show. Nexus runs this each time it becomes the
    // active app. So a value changes only when it is different, and the views do not draw again.
    func findApps() {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: AppPreference.hiddenDatabaseApps) ?? [])
        let foundDatabaseApps = DatabaseApps.found().filter { app in
            app.location.map { !hidden.contains(Self.appPath($0)) } ?? true
        }

        update(\.terminals, to: Self.withAdded(KnownApps.installed(KnownApps.terminals), role: .terminal))
        update(\.editors, to: Self.withAdded(KnownApps.installed(KnownApps.editors), role: .editor))
        update(\.databaseApps, to: Self.withAdded(foundDatabaseApps, role: .database))

        update(\.terminal, to: Self.chosenName(AppPreference.terminalApp, in: settings.terminals))
        update(\.editor, to: Self.chosenName(AppPreference.editorApp, in: settings.editors))
        update(\.mysqlApp, to: chosenDatabaseApp(AppPreference.mysqlApp, for: .mysql))
        update(\.postgresqlApp, to: chosenDatabaseApp(AppPreference.postgresqlApp, for: .postgresql))
    }

    private func update<Value: Equatable>(_ path: WritableKeyPath<AppSettings, Value>, to value: Value) {
        if settings[keyPath: path] != value {
            settings[keyPath: path] = value
        }
    }

    private static func withAdded(_ found: [AppChoice], role: AppRole) -> [AppChoice] {
        let added = (UserDefaults.standard.stringArray(forKey: role.addedKey) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            .map { AppChoice(name: KnownApps.name(of: $0), opens: role == .database ? DatabaseApps.allKinds : "", location: $0, added: true) }
        var names: Set<String> = []

        return (found + added).filter { names.insert($0.name).inserted }
    }

    // An empty setting is the choice "None". A chosen app that is not installed anymore gives the
    // standard app, or else the first app of the list.
    private static func chosenName(_ key: String, in apps: [AppChoice], standard: String? = nil) -> String {
        let path = UserDefaults.standard.string(forKey: key)

        if path?.isEmpty == true {
            return ""
        }

        if let path, let chosen = apps.first(where: { $0.location?.path(percentEncoded: false) == path }) {
            return chosen.name
        }

        return apps.first { $0.name == standard }?.name ?? apps.first?.name ?? ""
    }

    // Without a choice of the user, "Open" uses the app that macOS opens the link with.
    private func chosenDatabaseApp(_ key: String, for kind: ServiceKind) -> String {
        Self.chosenName(key, in: databaseApps(for: kind), standard: DatabaseApps.defaultApp(for: kind).map(KnownApps.name))
    }

    func databaseApps(for kind: ServiceKind) -> [AppChoice] {
        settings.databaseApps.filter { $0.canOpen(kind) }
    }

    // An empty name is the choice "None".
    func chooseTerminal(_ name: String) {
        settings.terminal = name
        remember(name, in: settings.terminals, as: AppPreference.terminalApp)
    }

    func chooseEditor(_ name: String) {
        settings.editor = name
        remember(name, in: settings.editors, as: AppPreference.editorApp)
    }

    func chooseDatabaseApp(_ name: String, for kind: ServiceKind) {
        if kind == .postgresql {
            settings.postgresqlApp = name
            remember(name, in: databaseApps(for: kind), as: AppPreference.postgresqlApp)
        } else {
            settings.mysqlApp = name
            remember(name, in: databaseApps(for: kind), as: AppPreference.mysqlApp)
        }
    }

    private func remember(_ name: String, in apps: [AppChoice], as key: String) {
        if name.isEmpty {
            UserDefaults.standard.set("", forKey: key)
            return
        }

        guard let path = apps.first(where: { $0.name == name })?.location?.path(percentEncoded: false) else {
            return
        }

        UserDefaults.standard.set(path, forKey: key)
    }

    // A path of an app always ends in a slash. So a found app and a chosen app compare.
    private static func appPath(_ app: URL) -> String {
        URL(filePath: app.path(percentEncoded: false), directoryHint: .isDirectory).path(percentEncoded: false)
    }

    // An added terminal app or code editor becomes the chosen one. An app with the name of a
    // found app is that app. An added database app that the user removed shows again.
    func addApp(_ app: URL, as role: AppRole) {
        let path = Self.appPath(app)
        var paths = UserDefaults.standard.stringArray(forKey: role.addedKey) ?? []

        if !paths.contains(path) {
            paths.append(path)
            UserDefaults.standard.set(paths, forKey: role.addedKey)
        }

        if role == .database {
            let hidden = (UserDefaults.standard.stringArray(forKey: AppPreference.hiddenDatabaseApps) ?? []).filter { $0 != path }
            UserDefaults.standard.set(hidden, forKey: AppPreference.hiddenDatabaseApps)
        }

        findApps()

        switch role {
        case .terminal: chooseTerminal(KnownApps.name(of: app))
        case .editor: chooseEditor(KnownApps.name(of: app))
        case .database: break
        }
    }

    // An added app leaves the added apps. A found app stays hidden until "Add app…" adds it again.
    // A chosen app that goes gives the default again.
    func removeDatabaseApp(_ app: AppChoice) {
        guard let location = app.location else {
            return
        }

        let path = Self.appPath(location)
        let added = (UserDefaults.standard.stringArray(forKey: AppPreference.addedDatabaseApps) ?? []).filter { $0 != path }
        UserDefaults.standard.set(added, forKey: AppPreference.addedDatabaseApps)

        if !app.added {
            let hidden = UserDefaults.standard.stringArray(forKey: AppPreference.hiddenDatabaseApps) ?? []
            UserDefaults.standard.set(hidden + [path], forKey: AppPreference.hiddenDatabaseApps)
        }

        for key in [AppPreference.mysqlApp, AppPreference.postgresqlApp] {
            if let chosen = UserDefaults.standard.string(forKey: key), !chosen.isEmpty, Self.appPath(URL(filePath: chosen)) == path {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        findApps()
    }

    // git worktree add makes a workspace without a click in Nexus. So a notification tells when its
    // site works: when a workspace leaves "preparing", or when a workspace that was not in the last
    // list is ready at once. The caller gives no previous list after a launch or a new connection,
    // and a new site with the workspaces that it has already gives none either.
    func notifyReadyWorkspaces(from previous: SiteList?, to list: SiteList) {
        guard let previous else {
            return
        }

        let oldHosts = Set(previous.sites.compactMap(\.hosts.first))
        let oldWorkspaces = Dictionary(previous.sites.flatMap { site in
            (site.workspaces ?? []).map { workspace in ("\(site.hosts.first ?? "") \(workspace.name)", workspace.state) }
        }, uniquingKeysWith: { first, _ in first })

        for site in list.sites {
            guard let host = site.hosts.first, oldHosts.contains(host) else {
                continue
            }

            for workspace in site.workspaces ?? [] {
                let key = "\(host) \(workspace.name)"

                guard oldWorkspaces[key].map({ $0 == nil || $0 == .preparing }) ?? true else {
                    continue
                }

                switch workspace.state {
                case .ready:
                    Notifier.post("\(workspace.name) is ready", "\(workspace.hosts?.first ?? workspace.name) is the workspace of \(host).", setting: AppPreference.notifyWorkspaceReady)
                case .notIsolated(let reason):
                    Notifier.post("\(workspace.name) is ready without its own data", reason, setting: AppPreference.notifyWorkspaceReady)
                case .preparing, nil:
                    break
                }
            }
        }
    }

    // The first event after a launch or after a new connection to nexusd shows no
    // notification. The user did not see the services before it.
    func notifyUnexpectedStops(from previous: [ServiceVersion]) {
        guard !previous.isEmpty else {
            return
        }

        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for service in services where service.stoppedUnexpectedly {
            guard let old = before[service.id] else {
                continue
            }

            if service.health == .failed, old.health != .failed {
                Notifier.post("\(service.name) failed", service.problem?.detail ?? "", setting: AppPreference.notifyServiceStops)
            } else if !old.stoppedUnexpectedly {
                Notifier.post("\(service.name) stopped", "\(service.name) stopped without a request. Nexus starts it again.", setting: AppPreference.notifyServiceStops)
            }
        }
    }

    // Every site gets a name in the new dev TLD (D28). The picker shows the new TLD while
    // nexusd works.
    func changeTLD(to tld: String, from place: ActionPlace = .settings) {
        guard isLive else {
            useTLD(tld)
            return
        }

        changingTLD = tld

        Task {
            let response = await perform(.tld(tld), failure: "The sites did not get the domain .\(tld)", place: place)

            guard case .done(let message) = response else {
                changingTLD = nil
                return
            }

            useTLD(tld)
            changingTLD = nil
            let warnings = message.split(separator: "\n").dropFirst()

            if !warnings.isEmpty {
                failure = ActionFailure(title: "The domain is .\(tld) now, but not every part works yet", message: warnings.joined(separator: "\n"), place: place)
            }
        }
    }

    func tldChangeMessage(to tld: String) -> String {
        let example = allSites.map(\.host).first { $0.hasSuffix(".\(settings.tld)") }
            .map { "\($0) becomes \(HostName.movingTLD($0, from: settings.tld, to: tld))" }
            ?? "shop.\(settings.tld) becomes shop.\(tld)"

        return "Every site gets a new name: \(example). The old names stop working. Change APP_URL in the .env file of each site yourself."
    }

    func checkNotificationPermission() async {
        let status = await Notifier.status()
        notificationsBlocked = status == .denied
        notificationsAllowed = status == .authorized || status == .provisional
    }

    func requestNotificationPermission() async {
        await Notifier.requestPermission()
        await checkNotificationPermission()
    }

    func setNewInstanceAccount(_ account: DatabaseAccount) {
        guard isLive else {
            settings.newInstanceAccount = account
            return
        }

        Task {
            if await perform(.setNewInstanceAccount(account), failure: "The account for new instances did not change", place: .settings) != nil {
                settings.newInstanceAccount = account
            }
        }
    }

    // A request that fails counts as not set up. So the first run then shows.
    func isSetUp(helperAllowed: Bool) async -> Bool {
        guard helperAllowed else {
            return false
        }

        await loadRootCertificate()
        await loadInstalledRuntimes()

        let installed = Set(installedRuntimes.map(\.name))
        return rootCertificate?.trusted == true && installedLoaded && installed.isSuperset(of: FirstRunPackages.required)
    }

    func loadRootCertificate() async {
        guard case .answer(.rootCertificate(let info)) = await outcome(of: .rootCertificate) else {
            return
        }

        rootCertificate = info
    }

    // macOS asks for the password of the user.
    func trustRootCertificate(from place: ActionPlace = .settings) async {
        await perform(.trust, failure: "macOS does not trust the Nexus root CA", place: place)
        await loadRootCertificate()
    }

    func openKeychainAccess() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else {
            return
        }

        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func showInFinder(_ path: String) {
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // nexusd removes the system files, the root CA and its background items. The login item of
    // the app goes too. The packages and the databases stay.
    func uninstall() {
        Task {
            guard case .done(let message) = await perform(.uninstall, failure: "Nexus was not removed", place: .settings) else {
                return
            }

            try? await SMAppService.mainApp.unregister()
            uninstalled = message
        }
    }

    // The stored settings go last, because the open windows still read them. Without them the
    // Settings window goes back to its first tab. A debug build runs from the build folder, and
    // that folder must stay.
    func moveToTrashAndQuit() {
        UserDefaults.standard.removePersistentDomain(forName: NexusIdentifiers.app)

        #if !DEBUG
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Nexus cannot move to the Trash"
            alert.informativeText = "\(error.localizedDescription) Move Nexus to the Trash yourself."
            alert.runModal()
        }
        #endif

        NSApplication.shared.terminate(nil)
    }
}
