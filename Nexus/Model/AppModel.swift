import AppKit
import NexusCore
import NexusIPC
import NexusSupervisor
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
    case portInUse(service: String, holder: PortHolder)

    var id: String {
        switch self {
        case .addSite: "add-site"
        case .importDatabase(let instance): "import-\(instance)"
        case .portInUse(let service, _): "port-\(service)"
        }
    }
}

// The port is the one in use. nginx has two ports. So it is not always the first port of the
// service.
struct PortHolder {
    let port: Int
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
    var databaseLists: [String: [DatabaseItem]] = [:]
    var databaseListProblems: [String: String] = [:]
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

    func databases(of service: ServiceVersion) -> [DatabaseItem] {
        client == nil ? service.databases : databaseLists[service.id] ?? []
    }

    // The list loads without a click of the user. So a failure shows in the list and not in an
    // alert. A failure of an instance that stopped in the meantime does not show. A stopped
    // instance shows no databases.
    func loadDatabases(of service: ServiceVersion) {
        let id = service.id

        guard let client, service.kind.isDatabase, service.isActive else {
            databaseLists[id] = nil
            databaseListProblems[id] = nil
            return
        }

        Task {
            let response: NexusResponse

            do {
                response = try await client.send(.databaseSizes(instance: id))
            } catch {
                response = .failure(message: String(describing: error))
            }

            switch response {
            case .databaseSizes(let sizes):
                databaseLists[id] = sizes.map { DatabaseItem(name: $0.name, usedBy: nil, size: $0.bytes.formatted(.byteCount(style: .file))) }
                databaseListProblems[id] = nil
            case .failure(let message):
                databaseListProblems[id] = self.service(id)?.isActive == true ? message : nil
            default:
                break
            }
        }
    }

    // A database or Redis gets its new port at a start. So a running one starts again. nginx,
    // Apache and DNS move at once.
    func changePort(_ port: ServicePort, of service: ServiceVersion, to number: Int) {
        Task {
            guard await perform(.setPort(service: port.key, port: number), failure: "\(service.name) did not get port \(number)", place: .window) != nil else {
                return
            }

            if service.isActive, service.kind.isDatabase || service.kind == .redis {
                await perform(.restart(service: service.id), failure: "\(service.name) did not restart", place: .window)
            }
        }
    }

    func changeAccount(of service: ServiceVersion, to account: DatabaseAccount) {
        let change = NexusCore.DatabaseAccount(user: account.user, password: account.password)

        Task {
            guard await perform(.setAccount(instance: service.id, account: change), failure: "The account of \(service.name) did not change", place: .window) != nil else {
                return
            }

            loadDatabases(of: service)
        }
    }

    func start(_ service: ServiceVersion, movingPortOf holder: PortHolder, to number: Int) {
        guard let key = (service.ports.first(where: { $0.number == holder.port }) ?? service.ports.first)?.key else {
            return
        }

        Task {
            guard await perform(.setPort(service: key, port: number), failure: "\(service.name) did not get port \(number)", place: .window) != nil else {
                return
            }

            await perform(.start(service: service.id), failure: "\(service.name) did not start", place: .window)
        }
    }

    // An app quits as a user would quit it. A program that is not an app, such as a mysqld of
    // Homebrew, gets SIGTERM. The start then waits up to 10 seconds for the port. A server that
    // an earlier nexusd left behind belongs to "Nexus". This app must not quit itself then.
    func quit(_ holder: PortHolder, andStart service: ServiceVersion) {
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == holder.app && $0.processIdentifier != ownProcess }

        if let app {
            app.terminate()
        } else if holder.processNumber > 0 {
            kill(pid_t(holder.processNumber), SIGTERM)
        }

        Task {
            let deadline = ContinuousClock.now + .seconds(10)
            while !PortInspector.isFree(holder.port), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }

            await perform(.start(service: service.id), failure: "\(service.name) did not start", place: .window)
        }
    }

    private func send(_ request: NexusRequest, failure title: String, place: ActionPlace, finished: ((Bool) -> Void)? = nil) {
        Task {
            let succeeded = await perform(request, failure: title, place: place) != nil
            finished?(succeeded)
        }
    }

    // Returns the answer, or nil when the request failed. A port in use opens its sheet in the
    // window. The menu bar panel shows it from the next event.
    @discardableResult
    private func perform(_ request: NexusRequest, failure title: String, place: ActionPlace) async -> NexusResponse? {
        guard let client else {
            return nil
        }

        let response: NexusResponse

        do {
            response = try await client.send(request)
        } catch {
            failure = ActionFailure(title: title, message: String(describing: error), place: place)
            return nil
        }

        switch response {
        case .failure(let message):
            failure = ActionFailure(title: title, message: message, place: place)
            return nil
        case .portInUse(let conflict):
            if place == .window {
                sheet = .portInUse(service: conflict.service, holder: PortHolder(conflict))
            }
            return nil
        default:
            return response
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
