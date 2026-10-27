import Foundation
import NexusIPC
import Observation

enum SidebarItem: Hashable {
    case overview
    case site(String)
    case service(ServiceKind)
    case packages
    case commandLine
}

enum SheetKind: Identifiable {
    case addSite
    case importDatabase(instance: String)
    case portInUse(service: String)

    var id: String {
        switch self {
        case .addSite: "add-site"
        case .importDatabase(let instance): "import-\(instance)"
        case .portInUse(let service): "port-\(service)"
        }
    }
}

struct PortHolder {
    let app: String
    let process: String
    let processNumber: Int
    let path: String
    let suggestedPort: Int
}

enum AppPreference {
    static let showInMenuBar = "showInMenuBar"
    static let showInDock = "showInDock"
}

enum ActionPlace {
    case window
    case menuBar
}

// A request to nexusd that failed. The place decides where the app shows it: an alert in the
// window, or a row in the menu bar panel.
struct ActionFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let place: ActionPlace
}

struct AppSettings {
    // The only endings that are safe for the dev domain (D28).
    static let devDomains = ["test", "internal", "localhost"]

    var startAtLogin = true
    var terminals: [AppChoice] = []
    var terminal = ""
    var editors: [AppChoice] = []
    var editor = ""
    var notifyServiceStops = true
    var notifyImportDone = true
    var defaultServer = "nginx"
    var defaultPHP = "newest"
    var newInstanceAccount = DatabaseAccount(user: "root", password: "")
    var databaseApps: [AppChoice] = []
    var mysqlApp = ""
    var postgresqlApp = ""
    var tld = "test"
    var lanAccess = false
    var caTrusted = true
    var caValidUntil = ""
    var checkPackageUpdates = true
    var installPackageUpdates = false
}

// Everything that the screens show. Sample data fills it until each area is connected to nexusd.
// The services come from nexusd since part 6b. Without a client, the model only holds sample data.
@Observable
final class AppModel {
    var selection: SidebarItem? = .overview
    var selectedVersion: [ServiceKind: String] = [:]
    var sheet: SheetKind?
    var search = ""
    var siteEntries: [SiteEntry] = []
    var services: [ServiceVersion] = []
    var stoppedByStopAll: [String] = []
    var nexusdProblem: String?
    var failure: ActionFailure?
    // The state that a switch shows while nexusd starts or stops its service.
    var switching: [String: Bool] = [:]
    var packages: [PackageItem] = []
    var activities: [ActivityItem] = []
    var packagesChecked = ""
    var commandSections: [CommandSection] = []
    var settings = AppSettings()

    @ObservationIgnored private var client: NexusClient?
    @ObservationIgnored private var feed: NexusEventFeed?
    @ObservationIgnored private var finishedSwitches: Set<String> = []

    // A debug build with the launch argument --sample shows only sample data, for a check of
    // the screens against the design.
    static func forLaunch() -> AppModel {
        #if DEBUG
        if CommandLine.arguments.contains("--sample") {
            return sample()
        }
        #endif

        let model = sample()
        model.services = []
        model.watchNexusd()
        return model
    }

    var allSites: [SiteItem] {
        siteEntries.flatMap(\.sites)
    }

    var groupNames: [String] {
        siteEntries.compactMap { entry in
            guard case .group(let group) = entry else {
                return nil
            }

            return group.name
        }
    }

    var blockedService: (service: ServiceVersion, holder: PortHolder)? {
        services.lazy.compactMap { service in service.problem?.portHolder.map { (service, $0) } }.first
    }

    var hasActiveService: Bool {
        services.contains(where: \.isActive)
    }

    var runningSummary: String {
        let running = services.filter(\.isRunning).count
        let problems = services.filter { $0.problem != nil }.count
        let summary = "\(running) of \(services.count) services running"

        return problems == 0 ? summary : "\(summary) · \(problems) problem\(problems == 1 ? "" : "s")"
    }

    var updateCount: Int {
        packages.filter { if case .update = $0.state { true } else { false } }.count
    }

    var installedPHPVersions: [String] {
        services.filter { $0.kind == .php }.map { $0.name.replacingOccurrences(of: "PHP ", with: "") }
    }

    var databaseInstances: [ServiceVersion] {
        services.filter(\.kind.isDatabase)
    }

    func versions(of kind: ServiceKind) -> [ServiceVersion] {
        services.filter { $0.kind == kind }
    }

    func site(_ host: String) -> SiteItem? {
        allSites.first { $0.host == host }
    }

    func service(_ id: String) -> ServiceVersion? {
        services.first { $0.id == id }
    }

    func health(of kind: ServiceKind) -> Health {
        let healths = versions(of: kind).map(\.health)

        if healths.contains(.failed) {
            return .failed
        }

        if healths.contains(.attention) {
            return .attention
        }

        return healths.contains(.running) ? .running : .stopped
    }

    func problemVersion(of kind: ServiceKind) -> ServiceVersion? {
        versions(of: kind).first { $0.health == .attention || $0.health == .failed }
    }

    func show(_ service: ServiceVersion) {
        selectedVersion[service.kind] = service.id
        selection = .service(service.kind)
    }

    func isSwitchedOn(_ service: ServiceVersion) -> Bool {
        switching[service.id] ?? service.isActive
    }

    func setRunning(_ running: Bool, service: ServiceVersion, from place: ActionPlace = .window) {
        guard client != nil else {
            setSampleRunning(running, service: service.id)
            return
        }

        let id = service.id
        switching[id] = running
        finishedSwitches.remove(id)

        send(
            running ? .start(service: id) : .stop(service: id),
            failure: running ? "\(service.name) did not start" : "\(service.name) did not stop",
            place: place
        ) { [weak self] succeeded in
            self?.finishSwitch(id, succeeded: succeeded)
        }
    }

    func restart(_ service: ServiceVersion) {
        send(.restart(service: service.id), failure: "\(service.name) did not restart", place: .window)
    }

    func stopAllServices() {
        send(.stopAll, failure: "Nexus did not stop all services", place: .window)
    }

    func startStoppedServices() {
        send(.startStopped, failure: "Nexus did not start the stopped services", place: .window)
    }

    private func setSampleRunning(_ running: Bool, service id: String) {
        guard let index = services.firstIndex(where: { $0.id == id }) else {
            return
        }

        services[index].health = running ? .running : .stopped
        services[index].since = running ? Date.now.formatted(date: .omitted, time: .shortened) : nil
        services[index].problem = nil
    }

    private func send(_ request: NexusRequest, failure title: String, place: ActionPlace, finished: ((Bool) -> Void)? = nil) {
        guard let client else {
            return
        }

        Task {
            let message: String?

            do {
                if case .failure(let text) = try await client.send(request) {
                    message = text
                } else {
                    message = nil
                }
            } catch {
                message = String(describing: error)
            }

            finished?(message == nil)

            if let message {
                failure = ActionFailure(title: title, message: message, place: place)
            }
        }
    }

    // The answer and the event of nexusd can arrive in either order. After a success the switch
    // keeps the asked state until the next event, so it does not jump back for a moment. nexusd
    // sends no event when the list stays the same, for example after a start of a DNS server
    // that macOS does not use yet. The switch then shows the real state after a short wait.
    private func finishSwitch(_ id: String, succeeded: Bool) {
        guard succeeded, service(id)?.isActive != switching[id] else {
            switching[id] = nil
            return
        }

        finishedSwitches.insert(id)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.dropFinishedSwitch(id)
        }
    }

    private func dropFinishedSwitch(_ id: String) {
        guard finishedSwitches.remove(id) != nil else {
            return
        }

        switching[id] = nil
    }

    private func watchNexusd() {
        let feed = NexusEventFeed()
        self.client = NexusClient()
        self.feed = feed

        Task { [weak self] in
            for await update in feed.updates {
                self?.apply(update)
            }
        }

        feed.start()
    }

    private func apply(_ update: NexusFeedUpdate) {
        switch update {
        case .event(.services(let list)):
            nexusdProblem = nil
            services = list.services.compactMap(ServiceVersion.init).sorted(by: ServiceVersion.showsBefore)
            stoppedByStopAll = list.stoppedByStopAll

            for id in finishedSwitches {
                switching[id] = nil
            }
            finishedSwitches = []
        case .unreachable(let reason):
            nexusdProblem = reason
        }
    }

    // Groups first, then the sites outside a group, then the folders of projects (D58).
    func sortByName() {
        let sorted = siteEntries.map { entry -> SiteEntry in
            switch entry {
            case .site:
                return entry
            case .group(var group):
                group.sites.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
                return .group(group)
            case .parked(var folder):
                folder.sites.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
                return .parked(folder)
            }
        }

        siteEntries = sorted.sorted { first, second in
            if first.sortRank != second.sortRank {
                return first.sortRank < second.sortRank
            }

            return first.sortName.localizedStandardCompare(second.sortName) == .orderedAscending
        }
    }

    func filteredEntries() -> [SiteEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()

        guard !query.isEmpty else {
            return siteEntries
        }

        return siteEntries.compactMap { entry in
            let matches = entry.sites.filter { $0.host.lowercased().contains(query) }

            switch entry {
            case .site:
                return matches.isEmpty ? nil : entry
            case .group(var group):
                group.sites = matches
                return matches.isEmpty ? nil : .group(group)
            case .parked(var folder):
                folder.sites = matches
                return matches.isEmpty ? nil : .parked(folder)
            }
        }
    }
}
