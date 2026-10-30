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
    static func isBlocked() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
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
            content.body = body
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
    // chosen app that is not installed anymore gives the first app of its list.
    func findApps() {
        settings.terminals = Self.withAdded(KnownApps.installed(KnownApps.terminals), role: .terminal)
        settings.editors = Self.withAdded(KnownApps.installed(KnownApps.editors), role: .editor)
        settings.databaseApps = Self.withAdded(DatabaseApps.found(), role: .database)

        settings.terminal = Self.chosen(AppPreference.terminalApp, in: settings.terminals)?.name ?? settings.terminals.first?.name ?? ""
        settings.editor = Self.chosen(AppPreference.editorApp, in: settings.editors)?.name ?? settings.editors.first?.name ?? ""
        settings.mysqlApp = chosenDatabaseApp(AppPreference.mysqlApp, for: .mysql)
        settings.postgresqlApp = chosenDatabaseApp(AppPreference.postgresqlApp, for: .postgresql)
    }

    private static func withAdded(_ found: [AppChoice], role: AppRole) -> [AppChoice] {
        let added = (UserDefaults.standard.stringArray(forKey: role.addedKey) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            .map { AppChoice(name: KnownApps.name(of: $0), opens: role == .database ? DatabaseApps.allKinds : "", location: $0, added: true) }
        var names: Set<String> = []

        return (found + added).filter { names.insert($0.name).inserted }
    }

    private static func chosen(_ key: String, in apps: [AppChoice]) -> AppChoice? {
        guard let path = UserDefaults.standard.string(forKey: key) else {
            return nil
        }

        return apps.first { $0.location?.path(percentEncoded: false) == path }
    }

    // Without a choice of the user, "Open" uses the app that macOS opens the link with.
    private func chosenDatabaseApp(_ key: String, for kind: ServiceKind) -> String {
        let apps = databaseApps(for: kind)

        if let chosen = Self.chosen(key, in: apps) {
            return chosen.name
        }

        let standard = DatabaseApps.defaultApp(for: kind).map(KnownApps.name)
        return apps.first { $0.name == standard }?.name ?? apps.first?.name ?? ""
    }

    func databaseApps(for kind: ServiceKind) -> [AppChoice] {
        settings.databaseApps.filter { $0.canOpen(kind) }
    }

    func chooseTerminal(_ name: String) {
        settings.terminal = name
        remember(settings.terminals.first { $0.name == name }, as: AppPreference.terminalApp)
    }

    func chooseEditor(_ name: String) {
        settings.editor = name
        remember(settings.editors.first { $0.name == name }, as: AppPreference.editorApp)
    }

    func chooseDatabaseApp(_ name: String, for kind: ServiceKind) {
        let app = databaseApps(for: kind).first { $0.name == name }

        if kind == .postgresql {
            settings.postgresqlApp = name
            remember(app, as: AppPreference.postgresqlApp)
        } else {
            settings.mysqlApp = name
            remember(app, as: AppPreference.mysqlApp)
        }
    }

    private func remember(_ app: AppChoice?, as key: String) {
        guard let path = app?.location?.path(percentEncoded: false) else {
            return
        }

        UserDefaults.standard.set(path, forKey: key)
    }

    // An added terminal app or code editor becomes the chosen one. An app with the name of a
    // found app is that app.
    func addApp(_ app: URL, as role: AppRole) {
        let path = URL(filePath: app.path(percentEncoded: false), directoryHint: .isDirectory).path(percentEncoded: false)
        var paths = UserDefaults.standard.stringArray(forKey: role.addedKey) ?? []

        if !paths.contains(path) {
            paths.append(path)
            UserDefaults.standard.set(paths, forKey: role.addedKey)
        }

        findApps()

        switch role {
        case .terminal: chooseTerminal(KnownApps.name(of: app))
        case .editor: chooseEditor(KnownApps.name(of: app))
        case .database: break
        }
    }

    // Only an app that the user added can go. A chosen app that goes gives the default again.
    func removeDatabaseApp(_ app: AppChoice) {
        guard app.added, let path = app.location?.path(percentEncoded: false) else {
            return
        }

        let paths = (UserDefaults.standard.stringArray(forKey: AppPreference.addedDatabaseApps) ?? []).filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: AppPreference.addedDatabaseApps)

        for key in [AppPreference.mysqlApp, AppPreference.postgresqlApp] where UserDefaults.standard.string(forKey: key) == path {
            UserDefaults.standard.removeObject(forKey: key)
        }

        findApps()
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
        notificationsBlocked = await Notifier.isBlocked()
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
}
