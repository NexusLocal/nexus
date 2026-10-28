import AppKit
import NexusCore
import NexusIPC
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
    static func requestPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
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
    func changeTLD(to tld: String) {
        guard isLive else {
            useTLD(tld)
            return
        }

        changingTLD = tld

        Task {
            let response = await perform(.tld(tld), failure: "The sites did not get the domain .\(tld)", place: .settings)

            guard case .done(let message) = response else {
                changingTLD = nil
                return
            }

            useTLD(tld)
            changingTLD = nil
            let warnings = message.split(separator: "\n").dropFirst()

            if !warnings.isEmpty {
                failure = ActionFailure(title: "The domain is .\(tld) now, but not every part works yet", message: warnings.joined(separator: "\n"), place: .settings)
            }
        }
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

    func loadRootCertificate() async {
        guard case .answer(.rootCertificate(let info)) = await outcome(of: .rootCertificate) else {
            return
        }

        rootCertificate = info
    }

    // macOS asks for the password of the user.
    func trustRootCertificate() {
        Task {
            await perform(.trust, failure: "macOS does not trust the Nexus root CA", place: .settings)
            await loadRootCertificate()
        }
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
