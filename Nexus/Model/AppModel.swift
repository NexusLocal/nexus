import Foundation
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
@Observable
final class AppModel {
    var selection: SidebarItem? = .overview
    var selectedVersion: [ServiceKind: String] = [:]
    var sheet: SheetKind?
    var search = ""
    var siteEntries: [SiteEntry] = []
    var services: [ServiceVersion] = []
    var packages: [PackageItem] = []
    var activities: [ActivityItem] = []
    var portHolder: PortHolder?
    var packagesChecked = ""
    var commandSections: [CommandSection] = []
    var settings = AppSettings()

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

    var problemService: ServiceVersion? {
        services.first { $0.problem != nil }
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

    func setRunning(_ running: Bool, service id: String) {
        guard let index = services.firstIndex(where: { $0.id == id }) else {
            return
        }

        services[index].health = running ? .running : .stopped
        services[index].since = running ? Date.now.formatted(date: .omitted, time: .shortened) : nil
        services[index].problem = nil
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
