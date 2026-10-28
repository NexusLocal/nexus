import Darwin
import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTLS

public protocol ManifestSource: Sendable {
    func manifest(from url: URL) async throws -> Manifest
}

public struct HTTPManifestSource: ManifestSource {
    public init() {}

    public func manifest(from url: URL) async throws -> Manifest {
        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.httpStatus(http.statusCode, url)
        }

        return try Manifest.decode(from: data)
    }
}

// The work of nexusd: it answers each request from the app or the CLI. It has no XPC code, so
// tests call it directly. The helper and the root CA have no default, so a test can never
// change /etc or the login keychain by accident.
public actor NexusEngine {
    public static let dnsServiceID = NexusServiceID.dns

    let paths: NexusPaths
    let supervisor: ProcessSupervisor
    let installer: RuntimeInstaller
    let catalog: ServiceCatalog
    let stateStore: EngineStateStore
    private let manifestSource: any ManifestSource
    private let helper: any PrivilegedHelper
    let certificateAuthority: CertificateAuthority
    private let systemFiles: SystemDNSFiles
    private let unregister: @Sendable () -> Void
    private let helperRetryDelay: Duration

    private var dnsServer: DNSServer?
    private var dnsState: ServiceState = .stopped
    var systemFilesProblem: String?
    var writtenHosts: [String]?
    private var systemFilesQueue: Task<Void, Never>?
    // The new dev TLD while setTLD runs. Its resolver file exists before the state names it, so
    // a write of the system files in that time must not remove it.
    private var tldInChange: String?
    private var helperRetry: Task<Void, Never>?
    private(set) var uninstalling = false
    private var webQueue: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<NexusEvent>.Continuation] = [:]
    private var publishedServices: ServiceList?
    private var publishedSites: SiteList?
    // The site list reads the parked folders and the runtimes on disk. So nexusd makes it again
    // only after a request that changes something, a change in a parked folder or a new watcher,
    // and not after each change of a process.
    private var sitesMayHaveChanged = true
    private var publishing = false
    private var publishAgain = false
    private var observesSupervisor = false
    // The last start of each service that failed on a port in use (D31).
    private var portConflicts: [String: PortConflict] = [:]
    // The extensions and modules of each runtime, with the modification dates of their folders.
    // The service list needs them after each change of a service.
    var toggleNameCache: [String: (stamp: [String], names: Set<String>)] = [:]
    // The watch of the parked folders, and the sites of the last configuration that nginx and
    // Apache accepted (D62).
    var parkedWatcher: FolderWatcher?
    var appliedSites: [String]?
    // The downloads and database copies that run now, and the last task list of the watchers.
    private(set) var runningTasks: [String: RunningTask] = [:]
    // The databases that a copy writes now, as "<instance> <name>". nexusd refuses a second copy
    // into one of them. It also refuses a second install of a package that it installs now. And
    // it refuses a copy into an instance that an update stops now.
    var copyTargets: Set<String> = []
    private var installTargets: Set<String> = []
    var updatingServices: Set<String> = []
    private var publishedTasks: TaskList?
    private var tasksTicker: Task<Void, Never>?

    public init(
        paths: NexusPaths,
        helper: any PrivilegedHelper,
        certificateAuthority: CertificateAuthority,
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        downloader: any PackageDownloader = URLSessionDownloader(),
        manifestSource: any ManifestSource = HTTPManifestSource(),
        systemFiles: SystemDNSFiles = SystemDNSFiles(),
        helperRetryDelay: Duration = .seconds(5),
        unregister: @escaping @Sendable () -> Void = {}
    ) {
        self.paths = paths
        self.supervisor = supervisor
        self.installer = RuntimeInstaller(paths: paths, downloader: downloader)
        self.catalog = ServiceCatalog(paths: paths)
        self.stateStore = EngineStateStore(paths: paths)
        self.manifestSource = manifestSource
        self.helper = helper
        self.certificateAuthority = certificateAuthority
        self.systemFiles = systemFiles
        self.helperRetryDelay = helperRetryDelay
        self.unregister = unregister
    }

    public func handle(_ request: NexusRequest) async -> NexusResponse {
        defer {
            if !request.onlyReads {
                sitesChanged()
            }
        }

        do {
            switch request {
            case .status:
                return .services(try await serviceStatus())
            case .start(let id):
                return .done(message: try await serialWeb { try await self.start(id) })
            case .stop(let id):
                return .done(message: try await serialWeb { try await self.stop(id) })
            case .restart(let id):
                return .done(message: try await serialWeb { try await self.restart(id) })
            case .stopAll:
                return .done(message: try await serialWeb { try await self.stopAll() })
            case .startStopped:
                return .done(message: try await serialWeb { try await self.startStopped() })
            case .setPort(let id, let port):
                return .done(message: try await serialWeb { try await self.setPort(id, port) })
            case .available:
                return .available(try await manifest().packages)
            case .installed:
                return .installed(await installer.installedRuntimes())
            case .install(let name, let line):
                return .done(message: try await install(name: name, line: line))
            case .remove(let name, let line):
                return .done(message: try await remove(name: name, line: line))
            case .trust:
                return .done(message: try await trust())
            case .rootCertificate:
                return .rootCertificate(rootCertificateInfo())
            case .certificate(let hosts):
                return .done(message: try certificate(for: hosts))
            case .hosts:
                return .hosts(await stateStore.current().hosts.sorted())
            case .addHost(let host):
                return .done(message: try await addHost(host))
            case .removeHost(let host):
                return .done(message: try await removeHost(host))
            case .uninstall:
                return .done(message: try await uninstall())
            case .sites:
                return .sites(await siteInfo())
            case .addSite(let folder, let host, let aliases, let php, let server, let group):
                return .done(message: try await serialWeb { try await self.addSite(folder: folder, host: host, aliases: aliases, php: php, server: server, group: group) })
            case .removeSite(let host):
                return .done(message: try await serialWeb { try await self.removeSite(host) })
            case .editSite(let host, let change):
                return .done(message: try await serialWeb { try await self.editSite(host, change: change) })
            case .park(let folder, let php, let server):
                return .done(message: try await serialWeb { try await self.park(folder: folder, php: php, server: server) })
            case .unpark(let folder):
                return .done(message: try await serialWeb { try await self.unpark(folder: folder) })
            case .setSiteLayout(let layout):
                return .done(message: try await serialWeb { try await self.setSiteLayout(layout) })
            case .siteDefaults:
                return .siteDefaults(await stateStore.current().siteDefaults)
            case .setSiteDefaults(let defaults):
                return .done(message: try await setSiteDefaults(defaults))
            case .extensions(let php):
                return .toggles(try await extensionToggles(line: php))
            case .setExtension(let php, let name, let enabled):
                return .done(message: try await serialWeb { try await self.setExtension(line: php, name: name, enabled: enabled) })
            case .modules(let server):
                return .toggles(try await moduleToggles(server))
            case .setModule(let server, let name, let enabled):
                return .done(message: try await serialWeb { try await self.setModule(server, name: name, enabled: enabled) })
            case .customSettings(let php):
                return .lines(try await customSettings(line: php))
            case .setCustomSettings(let php, let lines):
                return .done(message: try await serialWeb { try await self.setCustomSettings(line: php, lines: lines) })
            case .lan(let enabled):
                return .done(message: try await serialWeb { try await self.lan(enabled) })
            case .tld(nil):
                return .done(message: "The dev TLD is .\(await stateStore.current().tld).")
            case .tld(let tld?):
                return .done(message: try await serialWeb { try await self.setTLD(tld) })
            case .databases:
                return .databases(try await databaseInstances())
            case .databaseSizes(let instance):
                return .databaseSizes(try await databaseSizes(instance))
            case .setAccount(let instance, let account):
                return .done(message: try await serialWeb { try await self.setAccount(instance, account) })
            case .setNewInstanceAccount(let account):
                return .done(message: try await setNewInstanceAccount(account))
            case .copyDatabase(let copy):
                // A copy can take minutes, so it does not wait in the queue of the changes.
                return .done(message: try await copyDatabase(copy))
            case .sourceDatabases(let source, let instance):
                return .databaseSizes(try await sourceDatabases(source, instance: instance))
            case .stopTask(let id):
                return .done(message: stopTask(id))
            }
        } catch let conflict as PortConflict {
            return .portInUse(conflict)
        } catch let settings as PHPSettingsError {
            return .invalidSettings(settings)
        } catch let stopped as TaskStopped {
            return .stopped(message: stopped.description)
        } catch {
            return .failure(message: String(describing: error))
        }
    }

    // Runs the requests that change services or sites one at a time. The actor answers other
    // requests while one waits for a process. Without the queue, a second change could run in
    // that time and a rollback of the first change could undo it.
    func serialWeb<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        let previous = webQueue
        let turn = Task {
            await previous?.value
            return try await operation()
        }

        webQueue = Task { _ = try? await turn.value }
        return try await turn.value
    }

    // Starts the DNS server, the web services that the sites need, and every other service that
    // ran when nexusd stopped the last time. The services that "Stop all services" stopped wait
    // for "Start stopped services" (D63).
    public func startEnabledServices() async {
        _ = try? await startDNS()
        _ = try? await serialWeb { await self.watchParkedFolders() }
        _ = try? await serialWeb { try await self.applyWeb(.automatic) }

        let state = await stateStore.current()
        for id in state.enabledServices.subtracting(state.stoppedByStopAll).sorted() {
            _ = try? await start(id)
        }

        sitesChanged()
    }

    public func shutdown() async {
        parkedWatcher?.stop()
        parkedWatcher = nil
        helperRetry?.cancel()
        await supervisor.stopAll()
        stopDNS()

        for watcher in watchers.values {
            watcher.finish()
        }
        watchers = [:]
    }

    // nexus status shows a running DNS server as failed while macOS does not send it the names,
    // because the names of the sites do not work then.
    private func serviceStatus() async throws -> [ServiceStatus] {
        let dnsProblem = await dnsNamesProblem()

        return try await services().map { runtime, status in
            guard runtime == nil, let dnsProblem else {
                return status
            }

            return ServiceStatus(id: status.id, displayName: status.displayName, ports: status.ports, state: .failed(reason: dnsProblem))
        }
    }

    // DNS has no runtime. Each service has its real state here.
    private func services() async throws -> [(runtime: InstalledRuntime?, status: ServiceStatus)] {
        let supervised = Dictionary(uniqueKeysWithValues: await supervisor.status().map { ($0.id, $0) })
        var all: [(runtime: InstalledRuntime?, status: ServiceStatus)] = [(nil, await dnsStatus())]

        for runtime in await serviceRuntimes() {
            guard let id = catalog.serviceID(for: runtime) else {
                continue
            }

            if let status = supervised[id], status.state.isActive {
                all.append((runtime, status))
                continue
            }

            // A service that does not run shows the ports of its next start, not those of its
            // last run.
            let ports = try await self.ports(for: runtime)
            let definition = catalog.definition(for: runtime, ports: ports)
            let state = supervised[id]?.state ?? .stopped
            all.append((runtime, ServiceStatus(id: id, displayName: definition?.displayName ?? id, ports: definition?.ports ?? [], state: state)))
        }

        return all.sorted { $0.status.id < $1.status.id }
    }

    private func serviceList() async throws -> ServiceList {
        let all = try await services()
        let dnsProblem = await dnsNamesProblem()
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)
        var services: [ServiceInfo] = []

        for (runtime, status) in all {
            guard let runtime else {
                let note = "The DNS server answers 127.0.0.1 for every name that ends in .\(state.tld). /etc/resolver/\(state.tld) sends these names to this port."
                services.append(ServiceInfo(id: status.id, name: Self.dnsServiceID, line: "", version: "", ports: status.ports, state: status.state, problem: dnsProblem, note: note))
                continue
            }

            let tools = ServiceCatalog.databaseKind(of: runtime).map { DatabaseTools(id: status.id, kind: $0, runtime: runtime) }
            let ownsData = tools != nil || runtime.name == "redis"
            var account: DatabaseAccount?
            if let tools {
                account = try await self.account(of: tools)
            }

            let details = webDetails(of: runtime, state: state, sites: sites)
            services.append(ServiceInfo(
                id: status.id,
                name: runtime.name,
                line: runtime.line,
                version: runtime.version,
                ports: status.ports,
                state: status.state,
                portConflict: status.state.isActive ? nil : portConflicts[status.id],
                logFile: paths.log(status.id).path(percentEncoded: false),
                dataFolder: ownsData ? catalog.dataFolder(for: runtime).path(percentEncoded: false) : nil,
                account: account,
                toggles: details.toggles,
                customSettings: details.customSettings,
                usedBy: details.usedBy,
                note: details.note
            ))
        }

        let stopped = all.map(\.status).filter { !$0.state.isActive && state.stoppedByStopAll.contains($0.id) }.map(\.id)
        return ServiceList(services: services, stoppedByStopAll: stopped, lanAccess: state.lanAccess, newInstanceAccount: state.newInstanceAccount)
    }

    // One runtime for each service. nginx and Apache use the newest installed version line.
    func serviceRuntimes() async -> [InstalledRuntime] {
        var byID: [String: InstalledRuntime] = [:]

        for runtime in await installer.installedRuntimes() {
            guard let id = catalog.serviceID(for: runtime) else {
                continue
            }

            if let current = byID[id], VersionLine.isOlder(runtime.line, than: current.line) {
                continue
            }
            byID[id] = runtime
        }

        return byID.values.sorted { $0.name < $1.name }
    }

    func ports(for runtime: InstalledRuntime) async throws -> [String: Int] {
        var ports: [String: Int] = [:]

        for requirement in catalog.portRequirements(for: runtime) {
            ports[requirement.key] = try await stateStore.port(for: requirement.key, standard: requirement.standard)
        }

        return ports
    }

    // A service that the user starts runs again at the next start of nexusd. A restart and
    // "Start stopped services" keep that choice as it was, so a web service that only a site
    // needs stops again with the last site.
    func start(_ id: String, enable: Bool = true) async throws -> String {
        if id == Self.dnsServiceID {
            let message = try await startDNS()
            try await stateStore.update { $0.stoppedByStopAll.remove(id) }
            return message
        }

        if isWebService(id) {
            _ = try await writeWebConfig()
        }

        if id.hasPrefix("php-") {
            _ = try await writePHPConfig(line: String(id.dropFirst(4)), state: await stateStore.current())
        }

        if let database = await databaseRuntime(id), await supervisor.state(of: id)?.isActive != true {
            try await prepareDatabase(database)
        }

        let message = try await startService(id)
        try await stateStore.update {
            if enable {
                $0.enabledServices.insert(id)
            }
            $0.stoppedByStopAll.remove(id)
        }
        return message
    }

    func startService(_ id: String) async throws -> String {
        guard let definition = try await serviceDefinition(id) else {
            throw SupervisorError.unknownService(id)
        }

        do {
            try await supervisor.start(definition)
        } catch SupervisorError.portInUse(let port, let owner) {
            let conflict = PortConflict(service: id, port: port, owner: owner, suggestedPort: await suggestedPort(after: port))
            portConflicts[id] = conflict
            throw conflict
        }

        portConflicts[id] = nil

        if definition.ports.isEmpty {
            return "\(definition.displayName) runs."
        }

        try await waitForConnections(definition)
        return "\(definition.displayName) runs on port \(definition.ports.map(String.init).joined(separator: " and "))."
    }

    // The definition for the next start of a service, with the ports of the state.
    func serviceDefinition(_ id: String) async throws -> ServiceDefinition? {
        guard let runtime = await serviceRuntimes().first(where: { catalog.serviceID(for: $0) == id }) else {
            return nil
        }

        return catalog.definition(for: runtime, ports: try await ports(for: runtime))
    }

    // The answer goes back only when the service accepts connections. So a request right after
    // the command does not fail.
    func waitForConnections(_ definition: ServiceDefinition) async throws {
        guard let port = definition.ports.first else {
            return
        }

        let deadline = ContinuousClock.now + definition.startTimeout
        var accepting = PortInspector.acceptsConnections(port)
        while !accepting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            accepting = PortInspector.acceptsConnections(port)
        }

        guard accepting, case .running = await supervisor.state(of: definition.id) else {
            throw SupervisorError.launchFailed("\(definition.displayName) does not accept connections on port \(port). See \(definition.logFile.path(percentEncoded: false)).")
        }
    }

    private func stop(_ id: String, disable: Bool = true) async throws -> String {
        if id == Self.dnsServiceID {
            stopDNS()
            try await stateStore.update { $0.stoppedByStopAll.remove(id) }
            return "The DNS server stopped. It starts again with nexusd, or with: nexus start dns"
        }

        portConflicts[id] = nil
        try await supervisor.stop(id)
        try await stateStore.update {
            if disable {
                $0.enabledServices.remove(id)
            }
            $0.stoppedByStopAll.remove(id)
        }
        return "\(id) stopped."
    }

    // The next port above the one in use that is free and that no other Nexus service has.
    private func suggestedPort(after port: Int) async -> Int {
        let taken = Set(await stateStore.current().ports.values)
        var candidate = port + 1

        while candidate < 65535, taken.contains(candidate) || !PortInspector.isFree(candidate) {
            candidate += 1
        }

        return candidate
    }

    private func restart(_ id: String) async throws -> String {
        let running = id == Self.dnsServiceID
            ? dnsState.isActive
            : await supervisor.state(of: id)?.isActive == true

        guard running else {
            return try await start(id)
        }

        _ = try await stop(id, disable: false)
        return try await start(id, enable: false)
    }

    // The services stop at the same time, so a database that writes its data to disk does not
    // make the others wait. The services that an earlier "Stop all services" stopped stay in the
    // list (D63). Each one stays in enabledServices or out of it. So "Start stopped services" does
    // not change which services nexusd starts at its next start. Until then, nexusd skips them.
    private func stopAll() async throws -> String {
        let running = try await services().map(\.status).filter(\.state.isActive).map(\.id)

        guard !running.isEmpty else {
            return "No service runs."
        }

        let results = await withTaskGroup(of: (id: String, failure: String?).self) { group in
            for id in running {
                group.addTask {
                    do {
                        _ = try await self.stop(id, disable: false)
                        return (id, nil)
                    } catch {
                        return (id, "\(id): \(error)")
                    }
                }
            }

            var results: [(id: String, failure: String?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let stopped = results.filter { $0.failure == nil }.map(\.id)
        let failures = results.compactMap(\.failure).sorted()
        try await stateStore.update { $0.stoppedByStopAll.formUnion(stopped) }

        guard failures.isEmpty else {
            throw RuntimeError.unsupported("Nexus stopped \(Self.count(stopped.count, "service")). These did not stop:\n\(failures.joined(separator: "\n"))")
        }

        return "Nexus stopped \(Self.count(stopped.count, "service")). Start the stopped services again with: nexus start --stopped"
    }

    // A remembered service that runs again, for example DNS after a new start of nexusd, needs
    // no start.
    private func startStopped() async throws -> String {
        let stopped = Set(try await services().map(\.status).filter { !$0.state.isActive }.map(\.id))
        try await stateStore.update { $0.stoppedByStopAll.formIntersection(stopped) }
        let waiting = await stateStore.current().stoppedByStopAll.sorted()

        guard !waiting.isEmpty else {
            return "No service to start. This starts only the services that \"Stop all services\" stopped."
        }

        var failures: [String] = []
        for id in waiting {
            do {
                _ = try await start(id, enable: false)
            } catch {
                failures.append("\(id): \(error)")
            }
        }

        guard failures.isEmpty else {
            let started = waiting.count - failures.count
            throw RuntimeError.unsupported("Nexus started \(Self.count(started, "service")). These did not start:\n\(failures.joined(separator: "\n"))")
        }

        return "Nexus started \(Self.count(waiting.count, "service"))."
    }

    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private func setPort(_ id: String, _ port: Int) async throws -> String {
        guard (1...65535).contains(port) else {
            throw RuntimeError.unsupported("\(port) is not a valid port.")
        }

        let state = await stateStore.current()
        if let other = state.ports.first(where: { $0.key != id && $0.value == port })?.key {
            throw RuntimeError.unsupported("Port \(port) belongs to \(other) already.")
        }

        let names = await portNames()
        guard names.contains(id) else {
            if id == ServiceCatalog.nginxID {
                throw RuntimeError.unsupported("nginx has two ports. Run: nexus port http <port>, or: nexus port https <port>")
            }
            if id.hasPrefix("php-") {
                throw RuntimeError.unsupported("PHP has no port. nginx and Apache reach it through a socket.")
            }
            throw RuntimeError.unsupported("Nexus has no port named \(id). The ports are: \(names.sorted().joined(separator: ", ")).")
        }

        let nginxPortKeys = [ServiceCatalog.httpPortKey, ServiceCatalog.httpsPortKey]
        portConflicts[nginxPortKeys.contains(id) ? ServiceCatalog.nginxID : id] = nil

        if id == Self.dnsServiceID {
            return try await setDNSPort(port)
        }

        if Self.webPortKeys.contains(id) {
            return try await setWebPort(id, port)
        }

        try await stateStore.update { $0.ports[id] = port }

        if await supervisor.state(of: id)?.isActive == true {
            return "\(id) gets port \(port) at its next start. Run: nexus restart \(id)"
        }

        return "\(id) uses port \(port)."
    }

    // The names that nexus port accepts: dns and the port keys of the installed services.
    private func portNames() async -> Set<String> {
        let keys = await installer.installedRuntimes().flatMap { catalog.portRequirements(for: $0).map(\.key) }
        return Set(keys).union([Self.dnsServiceID])
    }

    // The download is a task that the user can stop (part 6f). An update of a version line that
    // runs stops its service only for the change of the folder, and starts it again. The task
    // ends after that change. So the app shows the download until the new folder is in place.
    private func install(name: String, line: String) async throws -> String {
        guard let package = try await manifest().package(named: name, line: line) else {
            throw RuntimeError.unsupported("The manifest has no \(name) \(line).")
        }

        let current = await installer.installed(name: name, line: line)
        if let current, current.isSameBuild(as: package) {
            return "\(name) \(current.version) is installed already in \(current.folder.path(percentEncoded: false))"
        }

        // The check and the insert have no wait between them. So two requests on the actor
        // cannot both pass.
        let target = "\(name)-\(line)"
        guard !installTargets.contains(target) else {
            throw RuntimeError.unsupported("Nexus installs \(name) \(line) already. Wait until it ends, or stop it.")
        }

        if let current, let id = catalog.serviceID(for: current) {
            try refuseUpdateDuringCopy(of: id, package: "\(name) \(line)")
        }

        installTargets.insert(target)
        defer { installTargets.remove(target) }

        let installer = installer
        let work = TaskWork.install(name: name, line: line, version: package.version, update: current != nil)
        let stopped = current.map { "The update of \(name) \(line) stopped. \(name) \($0.version) stays." } ?? "The download of \(name) \(line) stopped. Nexus installed nothing."
        let runtime = try await runTask(work, stopped: { stopped }) { progress in
            progress.update { $0.total = package.size.map(Int64.init) }

            let prepared = try await installer.prepare(package) { download in
                progress.update { values in
                    values.completed = download.received
                    values.total = download.expected ?? values.total
                }
            }

            // The change of the folder runs in a task of its own. A stop that comes now does
            // not stop it. So a service never stays stopped halfway through an update.
            return try await Task { try await self.serialWeb { try await self.replaceRuntime(with: prepared) } }.value
        }

        let folder = runtime.folder.path(percentEncoded: false)

        guard let current else {
            return "\(runtime.name) \(runtime.version) is installed in \(folder)"
        }

        return "\(runtime.name) \(runtime.line) is updated from \(current.version) to \(runtime.version) in \(folder)"
    }

    private func replaceRuntime(with prepared: PreparedRuntime) async throws -> InstalledRuntime {
        let id = catalog.serviceID(for: prepared.runtime)
        let running = if let id { await supervisor.state(of: id)?.isActive == true } else { false }

        guard let id, running else {
            return try await installer.commit(prepared)
        }

        do {
            try refuseUpdateDuringCopy(of: id, package: "\(prepared.runtime.name) \(prepared.runtime.line)")
        } catch {
            await installer.discard(prepared)
            throw error
        }

        updatingServices.insert(id)
        defer { updatingServices.remove(id) }

        do {
            _ = try await stop(id, disable: false)
        } catch {
            await installer.discard(prepared)
            throw RuntimeError.unsupported("Nexus did not update \(prepared.runtime.name) \(prepared.runtime.line), because \(id) did not stop. \(error)")
        }

        let runtime: InstalledRuntime
        do {
            runtime = try await installer.commit(prepared)
        } catch {
            _ = try? await start(id, enable: false)
            throw error
        }

        do {
            _ = try await start(id, enable: false)
        } catch {
            throw RuntimeError.unsupported("\(runtime.name) \(runtime.line) is updated to \(runtime.version), but \(id) did not start again. \(error)")
        }

        return runtime
    }

    // An update stops the instance. A copy into that instance would then fail with an error
    // that does not say why.
    private func refuseUpdateDuringCopy(of id: String, package: String) throws {
        guard copyTargets.contains(where: { $0.hasPrefix("\(id) ") }) else {
            return
        }

        throw RuntimeError.unsupported("Nexus did not update \(package), because a database copy into \(id) runs. Update it after the copy, or stop the copy first.")
    }

    private func remove(name: String, line: String) async throws -> String {
        guard let runtime = await installer.installed(name: name, line: line) else {
            throw RuntimeError.unsupported("\(name) \(line) is not installed.")
        }

        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)

        if name == "php", let site = sites.first(where: { $0.php == line }) {
            throw RuntimeError.unsupported("\(site.host) uses PHP \(line). Give it another PHP version first: nexus site edit \(site.host) --php <version>")
        }

        // A new project in a parked folder gets the settings of that folder.
        if name == "php", let parked = state.parked.first(where: { $0.php == line }) {
            throw RuntimeError.unsupported("The new projects in \(parked.folder.path(percentEncoded: false)) get PHP \(line). Park the folder again with another PHP version first: nexus unpark, then nexus park --php <version>")
        }

        let otherLines = await installer.installedRuntimes().filter { $0.name == name && $0.line != line }
        if name == "nginx", otherLines.isEmpty, let site = sites.first {
            throw RuntimeError.unsupported("Every site needs nginx, for example \(site.host). Remove the sites first.")
        }

        if name == "httpd", otherLines.isEmpty, let site = sites.first(where: { $0.server == .apache }) {
            throw RuntimeError.unsupported("\(site.host) uses Apache. Move it to nginx first: nexus site edit \(site.host) --server nginx")
        }

        if name == "httpd", otherLines.isEmpty, let parked = state.parked.first(where: { $0.server == .apache }) {
            throw RuntimeError.unsupported("The new projects in \(parked.folder.path(percentEncoded: false)) get Apache. Park the folder again with nginx first: nexus unpark, then nexus park --server nginx")
        }

        if let id = catalog.serviceID(for: runtime), await supervisor.state(of: id)?.isActive == true {
            throw RuntimeError.unsupported("Stop \(id) first. It uses \(name) \(line).")
        }

        try await installer.remove(name: name, line: line)

        if ServiceCatalog.databaseKind(of: runtime) != nil {
            return "\(name) \(line) is removed. Its data folder stays: \(catalog.dataFolder(for: runtime).path(percentEncoded: false))"
        }

        return "\(name) \(line) is removed."
    }

    private func manifest() async throws -> Manifest {
        try await manifestSource.manifest(from: stateStore.current().manifestURL)
    }
}

// The events that nexusd sends to the app without a request.
extension NexusEngine {
    // The stream starts with the current services and sites. A new watcher makes every watcher
    // get the lists again. That does no harm.
    public func events() async -> AsyncStream<NexusEvent> {
        if !observesSupervisor {
            observesSupervisor = true
            await supervisor.onChange { [weak self] in
                Task { await self?.servicesChanged() }
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: NexusEvent.self)
        let id = UUID()
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWatcher(id) }
        }

        // A new watcher gets the task list only while a task runs. An app that connects again
        // forgets its old tasks itself.
        publishedServices = nil
        publishedSites = nil
        publishedTasks = TaskList(tasks: [])
        sitesChanged()
        publishTasks()
        return stream
    }

    // A task shows at once when it starts and when it ends. While tasks run, a ticker sends
    // their progress four times each second.
    func addTask(_ task: RunningTask) {
        runningTasks[task.id] = task
        publishTasks()

        guard tasksTicker == nil else {
            return
        }

        tasksTicker = Task {
            while self.hasRunningTasks() {
                try? await Task.sleep(for: .milliseconds(250))
                self.publishTasks()
            }
        }
    }

    func removeTask(_ id: String) {
        runningTasks[id] = nil
        publishTasks()
    }

    private func hasRunningTasks() -> Bool {
        guard runningTasks.isEmpty else {
            return true
        }

        tasksTicker = nil
        return false
    }

    private func publishTasks() {
        let list = TaskList(tasks: runningTasks.values.map(\.info).sorted { ($0.started, $0.id) < ($1.started, $1.id) })

        guard list != publishedTasks, !watchers.isEmpty else {
            return
        }

        publishedTasks = list
        for watcher in watchers.values {
            watcher.yield(.tasks(list))
        }
    }

    private func removeWatcher(_ id: UUID) {
        watchers[id] = nil
    }

    // A change during a publish makes the loop run once more. So many changes in a short time
    // give few events, and the last event always has the newest state.
    func servicesChanged() {
        guard !watchers.isEmpty else {
            return
        }

        guard !publishing else {
            publishAgain = true
            return
        }

        publishing = true
        Task { await publishServices() }
    }

    func sitesChanged() {
        sitesMayHaveChanged = true
        servicesChanged()
    }

    private func publishServices() async {
        repeat {
            publishAgain = false

            if let list = try? await serviceList(), list != publishedServices {
                publishedServices = list
                for watcher in watchers.values {
                    watcher.yield(.services(list))
                }
            }

            if sitesMayHaveChanged {
                sitesMayHaveChanged = false
                let sites = await siteList()

                if sites != publishedSites {
                    publishedSites = sites
                    for watcher in watchers.values {
                        watcher.yield(.sites(sites))
                    }
                }
            }
        } while publishAgain

        publishing = false
    }
}

private extension NexusRequest {
    var onlyReads: Bool {
        switch self {
        case .status, .available, .installed, .rootCertificate, .hosts, .sites, .siteDefaults, .extensions, .modules, .customSettings, .tld(nil), .databases, .databaseSizes, .sourceDatabases, .stopTask: true
        default: false
        }
    }
}

// DNS, /etc/hosts and the system files that the helper writes.
extension NexusEngine {
    private func dnsPort() async throws -> Int {
        if let port = await stateStore.current().ports[Self.dnsServiceID] {
            return port
        }

        try await stateStore.update { $0.ports[Self.dnsServiceID] = DNSServer.defaultPort }
        return DNSServer.defaultPort
    }

    private func startDNS() async throws -> String {
        let port = try await dnsPort()
        try await bindDNS(port: port)
        await applySystemFiles()

        let tld = await stateStore.current().tld
        return systemFilesProblem.map { "The DNS server runs on port \(port), but macOS does not send .\(tld) names to it yet. \($0)" }
            ?? "The DNS server answers every .\(tld) name on port \(port)."
    }

    // Binds a new server before it stops the old one. So a port that is in use leaves the
    // running server as it is.
    private func bindDNS(port: Int) async throws {
        let server = DNSServer(responder: DNSResponder(tld: await stateStore.current().tld))

        do {
            if dnsServer?.port == port {
                dnsServer?.stop()
            }
            try server.start(port: port)
        } catch {
            if dnsServer?.port == nil {
                dnsState = .failed(reason: String(describing: error))
            }
            throw error
        }

        dnsServer?.stop()
        dnsServer = server
        dnsState = .running(pid: getpid(), since: .now)
    }

    private func stopDNS() {
        dnsServer?.stop()
        dnsServer = nil
        dnsState = .stopped
    }

    private func setDNSPort(_ port: Int) async throws -> String {
        guard port >= 1024 else {
            throw RuntimeError.unsupported("The DNS server needs a port from 1024 to 65535, because it runs without root.")
        }

        guard dnsState != .stopped else {
            try await stateStore.update { $0.ports[Self.dnsServiceID] = port }
            return "The DNS server uses port \(port) at its next start."
        }

        try await bindDNS(port: port)
        try await stateStore.update { $0.ports[Self.dnsServiceID] = port }
        await applySystemFiles()

        return systemFilesProblem.map { "The DNS server runs on port \(port), but /etc/resolver does not name it yet. \($0)" }
            ?? "The DNS server runs on port \(port), and /etc/resolver names it."
    }

    private func dnsStatus() async -> ServiceStatus {
        let state = await stateStore.current()
        let port = state.ports[Self.dnsServiceID] ?? DNSServer.defaultPort

        return ServiceStatus(id: Self.dnsServiceID, displayName: "DNS for .\(state.tld)", ports: [port], state: dnsState)
    }

    // A missing resolver file means that .test names do not work, also while the DNS server runs.
    private func dnsNamesProblem() async -> String? {
        guard let systemFilesProblem, dnsState.isActive else {
            return nil
        }

        return "macOS does not send .\(await stateStore.current().tld) names to Nexus yet. \(systemFilesProblem)"
    }

    // Each call waits for the call before it, and reads the state only when its turn comes. So
    // the helper always gets the newest host list last.
    func applySystemFiles() async {
        _ = try? await inSystemFilesTurn { await self.writeSystemFiles() }
    }

    // Every request to the helper waits for the request before it.
    private func inSystemFilesTurn<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        let previous = systemFilesQueue
        let turn = Task {
            await previous?.value
            return try await operation()
        }

        systemFilesQueue = Task { _ = try? await turn.value }
        return try await turn.value
    }

    // The resolver file names the port of the DNS server, so it is only written while the server
    // runs. The /etc/hosts lines do not need the DNS server, so a refused resolver file does not
    // stop them. The helper does not answer before the user approves it. nexusd then asks it
    // again every few seconds. A resolver file of an old dev TLD goes, because its names do not
    // work anymore.
    private func writeSystemFiles() async {
        guard !uninstalling else {
            return
        }

        let state = await stateStore.current()
        var problems: [any Error] = []

        if let port = dnsServer?.port {
            do {
                try await helper.send(.setResolver(tld: state.tld, port: port))
            } catch {
                problems.append(error)
            }
        }

        for tld in systemFiles.nexusResolvers where tld != state.tld && tld != tldInChange {
            do {
                try await helper.send(.removeResolver(tld: tld))
            } catch {
                problems.append(error)
            }
        }

        do {
            let hosts = etcHosts(state)
            try await helper.send(.setHosts(hosts))
            writtenHosts = hosts
        } catch {
            problems.append(error)
        }

        let messages = problems.map { String(describing: $0) }
        systemFilesProblem = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: " ")
        servicesChanged()

        if problems.contains(where: { ($0 as? HelperError)?.isNotReachable == true }) {
            scheduleHelperRetry()
        }
    }

    private func scheduleHelperRetry() {
        guard helperRetry == nil else {
            return
        }

        let delay = helperRetryDelay
        helperRetry = Task {
            try? await Task.sleep(for: delay)
            await self.retryHelper()
        }
    }

    private func retryHelper() async {
        helperRetry = nil
        await applySystemFiles()
    }

    private func addHost(_ name: String) async throws -> String {
        let host = try HostName.validated(name)
        let state = await stateStore.current()

        if DNSResponder(tld: state.tld).contains(host) {
            throw RuntimeError.unsupported("\(host) needs no line in /etc/hosts. The DNS server of Nexus answers every .\(state.tld) name.")
        }

        try await stateStore.update { $0.hosts.insert(host) }
        await applySystemFiles()

        return systemFilesProblem.map { "Nexus keeps \(host), but /etc/hosts does not have it yet. \($0)" }
            ?? "/etc/hosts sends \(host) to 127.0.0.1 and ::1."
    }

    private func removeHost(_ name: String) async throws -> String {
        let host = try HostName.validated(name)

        guard await stateStore.current().hosts.contains(host) else {
            throw RuntimeError.unsupported("Nexus has no /etc/hosts line for \(host).")
        }

        try await stateStore.update { $0.hosts.remove(host) }
        await applySystemFiles()

        return systemFilesProblem.map { "Nexus forgot \(host), but its /etc/hosts line stays until the helper answers. \($0)" }
            ?? "/etc/hosts has no line for \(host) now."
    }

    // The dev TLD can change after the first run (D28). Every name in the old TLD gets the new
    // one: the added sites, their aliases and the order of the sidebar. The sites of the parked
    // folders get it from the state. The helper writes the resolver file of the new TLD first.
    // So a helper that refuses it, or that does not answer, changes nothing. The resolver file of
    // the old TLD goes at the next write of the system files.
    func setTLD(_ requested: String) async throws -> String {
        let tld = try HostName.validatedTLD(requested)
        let state = await stateStore.current()
        let old = state.tld

        guard tld != old else {
            return "The dev TLD is .\(tld) already."
        }

        let sites = state.sites.map { $0.movingTLD(from: old, to: tld) }
        let layout = state.siteLayout.map { $0.movingTLD(from: old, to: tld) }
        var names: Set<String> = []

        for host in sites.flatMap(\.hosts) where !names.insert(host).inserted {
            throw RuntimeError.unsupported("Nexus did not change the dev TLD, because two names would become \(host). Remove one of them from its site first.")
        }

        // An added site that takes the name of a parked site hides that site. Only a name that
        // did not hide a parked site before the change counts.
        let parkedBefore = Set(state.parked.flatMap { $0.sites(tld: old) }.map(\.host))
        let parkedAfter = Set(state.parked.flatMap { $0.sites(tld: tld) }.map(\.host))

        for (site, moved) in zip(state.sites, sites) {
            for (before, after) in zip(site.hosts, moved.hosts) where parkedAfter.contains(after) && !parkedBefore.contains(before) {
                throw RuntimeError.unsupported("Nexus did not change the dev TLD, because \(after) would be the name of an added site and of a site in a parked folder. Remove the name from the added site first.")
            }
        }

        guard !uninstalling else {
            throw RuntimeError.unsupported("Nexus did not change the dev TLD, because Nexus is being removed.")
        }

        tldInChange = tld
        defer { tldInChange = nil }

        if let port = dnsServer?.port {
            do {
                try await inSystemFilesTurn { try await self.helper.send(.setResolver(tld: tld, port: port)) }
            } catch {
                throw RuntimeError.unsupported("Nexus did not change the dev TLD, because /etc/resolver/\(tld) was not written. Nothing changed. \(error)")
            }
        }

        var warnings: [String]
        do {
            warnings = try await changeWeb(.setting) { state in
                state.tld = tld
                state.sites = sites
                state.siteLayout = layout
            }
        } catch {
            tldInChange = nil
            await applySystemFiles()
            throw error
        }

        if let port = dnsServer?.port {
            do {
                try await bindDNS(port: port)
            } catch {
                warnings.append("The DNS server did not start again for .\(tld). Run: nexus restart dns. \(error)")
            }
        }

        await applySystemFiles()

        if let systemFilesProblem {
            warnings.append(systemFilesProblem)
        }

        let renamed = resolvedSites(await stateStore.current()).map(\.site.host).first { $0.hasSuffix(".\(tld)") }
        let summary = renamed.map { "Every site has a new name, for example \($0). Change APP_URL in the .env file of each site too." }
            ?? "A new site gets a name that ends in .\(tld)."
        return (["The dev TLD is .\(tld) now. \(summary)"] + warnings).joined(separator: "\n")
    }
}

// The root CA and the certificates.
extension NexusEngine {
    private func trust() async throws -> String {
        let authority = certificateAuthority

        if authority.isTrusted() {
            return "The Nexus root CA is trusted already."
        }

        // The root exists before the password dialog opens. The actor answers other requests
        // while the dialog is open, and a certificate request must not make a second root.
        _ = try authority.root()
        try await Task.detached { try authority.trust() }.value

        guard authority.isTrusted() else {
            throw RuntimeError.unsupported("macOS saved the trust setting, but it does not trust the Nexus root CA. Check \"Nexus Root CA\" in Keychain Access.")
        }

        return """
            Safari and Chrome trust the certificates of Nexus now.
            Firefox has its own certificate store. Import \(authority.rootCertificateFile.path(percentEncoded: false)) in Firefox: Settings > Privacy & Security > View Certificates > Authorities.
            """
    }

    private func rootCertificateInfo() -> RootCertificateInfo {
        let root = try? certificateAuthority.existingRoot()

        return RootCertificateInfo(
            trusted: root.map { certificateAuthority.isTrusted($0) } ?? false,
            validUntil: root?.certificate.notValidAfter,
            file: certificateAuthority.rootCertificateFile.path(percentEncoded: false)
        )
    }

    private func certificate(for hosts: [String]) throws -> String {
        let issued = try certificateAuthority.hostCertificate(for: hosts)
        var lines = [
            "Hosts:       \(issued.hosts.joined(separator: ", "))",
            "Certificate: \(issued.certificateFile.path(percentEncoded: false))",
            "Key:         \(issued.keyFile.path(percentEncoded: false))",
            "Valid until: \(issued.notValidAfter.formatted(date: .long, time: .omitted))",
        ]

        if !certificateAuthority.isTrusted() {
            lines.append("Browsers do not trust this certificate until you run: nexus trust")
        }

        return lines.joined(separator: "\n")
    }
}

// Removing Nexus.
extension NexusEngine {
    // Stops at the first step that fails. The system files go first. So nothing has changed yet
    // when the helper does not answer. The helper stays registered while its files exist. A
    // resolver file of an old dev TLD goes too.
    private func uninstall() async throws -> String {
        uninstalling = true
        helperRetry?.cancel()
        await systemFilesQueue?.value

        let resolvers = systemFiles.nexusResolvers
        let systemFileNames = resolvers.map { "/etc/resolver/\($0)" } + ["its /etc/hosts lines"]
        let removedFiles = Self.list(systemFileNames)

        if !resolvers.isEmpty || systemFiles.hasNexusHosts {
            do {
                for resolver in resolvers {
                    try await helper.send(.removeResolver(tld: resolver))
                }
                try await helper.send(.setHosts([]))
            } catch {
                uninstalling = false
                throw RuntimeError.unsupported("Nexus did not remove \(removedFiles), so it stopped the removal. Nothing else changed. \(error)")
            }
        }

        let authority = certificateAuthority
        do {
            try await Task.detached { try authority.remove() }.value
        } catch {
            throw RuntimeError.unsupported("Nexus removed \(removedFiles), but not its root CA. Run nexus uninstall again. \(error)")
        }

        parkedWatcher?.stop()
        parkedWatcher = nil
        await supervisor.stopAll()
        stopDNS()

        let unregister = unregister
        Task {
            try? await Task.sleep(for: .seconds(1))
            unregister()
        }

        return """
            Nexus removed \(Self.list(systemFileNames + ["its root CA", "its background services"])).
            The packages and the databases stay in \(paths.root.path(percentEncoded: false)). Remove that folder to remove them too.
            Quit Nexus and move it to the Trash.
            """
    }

    // "a", "a and b", or "a, b and c".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else {
            return ""
        }

        return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) and \(last)"
    }
}
