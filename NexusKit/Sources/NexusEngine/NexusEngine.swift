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
    private var helperRetry: Task<Void, Never>?
    private var uninstalling = false
    private var webQueue: Task<Void, Never>?

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
        do {
            switch request {
            case .status:
                return .services(try await serviceStatus())
            case .start(let id):
                return .done(message: try await serialWeb { try await self.start(id) })
            case .stop(let id):
                return .done(message: try await serialWeb { try await self.stop(id) })
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
            case .addSite(let folder, let host, let aliases, let php, let server):
                return .done(message: try await serialWeb { try await self.addSite(folder: folder, host: host, aliases: aliases, php: php, server: server) })
            case .removeSite(let host):
                return .done(message: try await serialWeb { try await self.removeSite(host) })
            case .editSite(let host, let change):
                return .done(message: try await serialWeb { try await self.editSite(host, change: change) })
            case .park(let folder, let php, let server):
                return .done(message: try await serialWeb { try await self.park(folder: folder, php: php, server: server) })
            case .unpark(let folder):
                return .done(message: try await serialWeb { try await self.unpark(folder: folder) })
            case .extensions(let php):
                return .toggles(try await extensionToggles(line: php))
            case .setExtension(let php, let name, let enabled):
                return .done(message: try await serialWeb { try await self.setExtension(line: php, name: name, enabled: enabled) })
            case .modules(let server):
                return .toggles(try await moduleToggles(server))
            case .setModule(let server, let name, let enabled):
                return .done(message: try await serialWeb { try await self.setModule(server, name: name, enabled: enabled) })
            case .lan(let enabled):
                return .done(message: try await serialWeb { try await self.lan(enabled) })
            }
        } catch {
            return .failure(message: String(describing: error))
        }
    }

    // Runs the requests that change services or sites one at a time. The actor answers other
    // requests while one waits for a process. Without the queue, a second change could run in
    // that time and a rollback of the first change could undo it.
    private func serialWeb<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        let previous = webQueue
        let turn = Task {
            await previous?.value
            return try await operation()
        }

        webQueue = Task { _ = try? await turn.value }
        return try await turn.value
    }

    // Starts the DNS server, the web services that the sites need, and every other service that
    // ran when nexusd stopped the last time.
    public func startEnabledServices() async {
        _ = try? await startDNS()
        _ = try? await applyWeb()

        for id in await stateStore.current().enabledServices.sorted() {
            _ = try? await start(id)
        }
    }

    public func shutdown() async {
        helperRetry?.cancel()
        await supervisor.stopAll()
        stopDNS()
    }

    private func serviceStatus() async throws -> [ServiceStatus] {
        let supervised = Dictionary(uniqueKeysWithValues: await supervisor.status().map { ($0.id, $0) })
        var all = [await dnsStatus()]

        for runtime in await serviceRuntimes() {
            guard let id = catalog.serviceID(for: runtime) else {
                continue
            }

            if let status = supervised[id] {
                all.append(status)
                continue
            }

            let ports = try await self.ports(for: runtime)
            let definition = catalog.definition(for: runtime, ports: ports)
            all.append(ServiceStatus(id: id, displayName: definition?.displayName ?? id, ports: definition?.ports ?? [], state: .stopped))
        }

        return all.sorted { $0.id < $1.id }
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

    private func start(_ id: String) async throws -> String {
        if id == Self.dnsServiceID {
            return try await startDNS()
        }

        if isWebService(id) {
            _ = try await writeWebConfig()
        }

        if id.hasPrefix("php-") {
            _ = try await writePHPConfig(line: String(id.dropFirst(4)), state: await stateStore.current())
        }

        let message = try await startService(id)
        try await stateStore.update { $0.enabledServices.insert(id) }
        return message
    }

    func startService(_ id: String) async throws -> String {
        guard let runtime = await serviceRuntimes().first(where: { catalog.serviceID(for: $0) == id }),
              let definition = catalog.definition(for: runtime, ports: try await ports(for: runtime)) else {
            throw SupervisorError.unknownService(id)
        }

        try await supervisor.start(definition)

        if definition.ports.isEmpty {
            return "\(definition.displayName) runs."
        }

        // The answer goes back only when the service accepts connections, so a request right
        // after the command does not fail.
        let deadline = ContinuousClock.now + .seconds(3)
        while !PortInspector.acceptsConnections(definition.ports[0]), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard case .running = await supervisor.state(of: id), PortInspector.acceptsConnections(definition.ports[0]) else {
            throw SupervisorError.launchFailed("\(definition.displayName) does not accept connections on port \(definition.ports[0]). See \(definition.logFile.path(percentEncoded: false)).")
        }

        return "\(definition.displayName) runs on port \(definition.ports.map(String.init).joined(separator: " and "))."
    }

    private func stop(_ id: String) async throws -> String {
        if id == Self.dnsServiceID {
            stopDNS()
            return "The DNS server stopped. It starts again with nexusd, or with: nexus start dns"
        }

        try await supervisor.stop(id)
        try await stateStore.update { $0.enabledServices.remove(id) }
        return "\(id) stopped."
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

        if id == Self.dnsServiceID {
            return try await setDNSPort(port)
        }

        if Self.webPortKeys.contains(id) {
            return try await setWebPort(id, port)
        }

        try await stateStore.update { $0.ports[id] = port }

        if await supervisor.state(of: id)?.isActive == true {
            return "\(id) gets port \(port) at its next start. Run: nexus stop \(id) && nexus start \(id)"
        }

        return "\(id) uses port \(port)."
    }

    // The names that nexus port accepts: dns and the port keys of the installed services.
    private func portNames() async -> Set<String> {
        let keys = await installer.installedRuntimes().flatMap { catalog.portRequirements(for: $0).map(\.key) }
        return Set(keys).union([Self.dnsServiceID])
    }

    private func install(name: String, line: String) async throws -> String {
        guard let package = try await manifest().package(named: name, line: line) else {
            throw RuntimeError.unsupported("The manifest has no \(name) \(line).")
        }

        let runtime = try await installer.install(package)
        return "\(runtime.name) \(runtime.version) is installed in \(runtime.folder.path(percentEncoded: false))"
    }

    private func remove(name: String, line: String) async throws -> String {
        guard let runtime = await installer.installed(name: name, line: line) else {
            throw RuntimeError.unsupported("\(name) \(line) is not installed.")
        }

        let sites = resolvedSites(await stateStore.current()).map(\.site)

        if name == "php", let site = sites.first(where: { $0.php == line }) {
            throw RuntimeError.unsupported("\(site.host) uses PHP \(line). Give it another PHP version first: nexus site edit \(site.host) --php <version>")
        }

        let otherLines = await installer.installedRuntimes().filter { $0.name == name && $0.line != line }
        if name == "nginx", otherLines.isEmpty, let site = sites.first {
            throw RuntimeError.unsupported("Every site needs nginx, for example \(site.host). Remove the sites first.")
        }

        if name == "httpd", otherLines.isEmpty, let site = sites.first(where: { $0.server == .apache }) {
            throw RuntimeError.unsupported("\(site.host) uses Apache. Move it to nginx first: nexus site edit \(site.host) --server nginx")
        }

        if let id = catalog.serviceID(for: runtime), await supervisor.state(of: id)?.isActive == true {
            throw RuntimeError.unsupported("Stop \(id) first. It uses \(name) \(line).")
        }

        try await installer.remove(name: name, line: line)
        return "\(name) \(line) is removed."
    }

    private func manifest() async throws -> Manifest {
        try await manifestSource.manifest(from: stateStore.current().manifestURL)
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

    // A failed DNS server or a missing resolver file both mean that .test names do not work.
    private func dnsStatus() async -> ServiceStatus {
        let state = await stateStore.current()
        let port = state.ports[Self.dnsServiceID] ?? DNSServer.defaultPort
        var current = dnsState

        if let systemFilesProblem, dnsState.isActive {
            current = .failed(reason: "macOS does not send .\(state.tld) names to Nexus yet. \(systemFilesProblem)")
        }

        return ServiceStatus(id: Self.dnsServiceID, displayName: "DNS for .\(state.tld)", ports: [port], state: current)
    }

    // Each call waits for the call before it, and reads the state only when its turn comes. So
    // the helper always gets the newest host list last.
    func applySystemFiles() async {
        let previous = systemFilesQueue
        let turn = Task {
            await previous?.value
            await self.writeSystemFiles()
        }

        systemFilesQueue = turn
        await turn.value
    }

    // The resolver file names the port of the DNS server, so it is only written while the server
    // runs. The /etc/hosts lines do not need the DNS server, so a refused resolver file does not
    // stop them. The helper does not answer before the user approves it. nexusd then asks it
    // again every few seconds.
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

        do {
            let hosts = etcHosts(state)
            try await helper.send(.setHosts(hosts))
            writtenHosts = hosts
        } catch {
            problems.append(error)
        }

        let messages = problems.map { String(describing: $0) }
        systemFilesProblem = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: " ")

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
    // when the helper does not answer. The helper stays registered while its files exist.
    private func uninstall() async throws -> String {
        let tld = await stateStore.current().tld
        uninstalling = true
        helperRetry?.cancel()
        await systemFilesQueue?.value

        if systemFiles.hasNexusChanges(tld: tld) {
            do {
                try await helper.send(.removeResolver(tld: tld))
                try await helper.send(.setHosts([]))
            } catch {
                uninstalling = false
                throw RuntimeError.unsupported("Nexus did not remove /etc/resolver/\(tld) and its /etc/hosts lines, so it stopped the removal. Nothing else changed. \(error)")
            }
        }

        let authority = certificateAuthority
        do {
            try await Task.detached { try authority.remove() }.value
        } catch {
            throw RuntimeError.unsupported("Nexus removed /etc/resolver/\(tld) and its /etc/hosts lines, but not its root CA. Run nexus uninstall again. \(error)")
        }

        await supervisor.stopAll()
        stopDNS()

        let unregister = unregister
        Task {
            try? await Task.sleep(for: .seconds(1))
            unregister()
        }

        return """
            Nexus removed /etc/resolver/\(tld), its /etc/hosts lines, its root CA and its background services.
            The packages and the databases stay in \(paths.root.path(percentEncoded: false)). Remove that folder to remove them too.
            Quit Nexus and move it to the Trash.
            """
    }
}
