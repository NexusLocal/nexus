import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTLS
import NexusWorkspaces

struct WebPlan {
    var sites: [WebSite] = []
    var phpLines: Set<String> = []
    var changedPHPLines: Set<String> = []
    var needsApache = false
    var warnings: [String] = []
    var siteSignature: [String] = []
}

// What a change of the web configuration starts and stops.
enum WebChange {
    // The user changed the sites. nexusd starts what the sites need and stops what no site needs.
    case sites
    // nexusd changed the sites itself, for a new project in a parked folder or at its own start.
    // While "Stop all services" is in effect, a web service that does not run waits for "Start
    // stopped services" (D63). A service that the user started after "Stop all services" does
    // not wait.
    case automatic
    // A port, a module or the LAN switch changed. nexusd only reloads the running servers. So
    // the services that "Stop all services" stopped stay stopped.
    case setting
}

// Sites, PHP, nginx and Apache (step 4).
extension NexusEngine {
    static let webPortKeys: Set<String> = [ServiceCatalog.httpPortKey, ServiceCatalog.httpsPortKey, ServiceCatalog.apacheID]

    func isWebService(_ id: String) -> Bool {
        id == ServiceCatalog.nginxID || id == ServiceCatalog.apacheID || id.hasPrefix("php-")
    }

    func resolvedSites(_ state: EngineState) -> [(site: Site, parked: Bool)] {
        resolveSites(state).sites
    }

    // The added sites and the sites of the parked folders. The added sites claim their hosts
    // first, so a parked site can get its own settings as an added site. A parked site whose host
    // another site has already is left out with a warning, because two server blocks with one
    // name make nginx use only one of them.
    func resolveSites(_ state: EngineState) -> (sites: [(site: Site, parked: Bool)], conflicts: [String]) {
        var claimed = Set(state.sites.flatMap(\.hosts))
        var sites = state.sites.map { (site: $0, parked: false) }
        var conflicts: [String] = []

        for folder in state.parked {
            for site in folder.sites(tld: state.tld) {
                if state.sites.contains(where: { $0.host == site.host }) {
                    continue
                }

                guard !claimed.contains(site.host) else {
                    conflicts.append("\(site.folder.path(percentEncoded: false)) does not run, because another site has the host \(site.host) already.")
                    continue
                }

                claimed.insert(site.host)
                sites.append((site, true))
            }
        }

        return (sites.sorted { $0.site.host < $1.site.host }, conflicts)
    }

    // Why a site does not run, or nil when it can run.
    static func problem(of site: Site, installed: [InstalledRuntime], checksNginx: Bool = true) -> String? {
        if checksNginx, !installed.contains(where: { $0.name == "nginx" }) {
            return "Every site needs nginx, and nginx is not installed. Run: nexus install nginx 1.30"
        }

        guard installed.contains(where: { $0.name == "php" && $0.line == site.php }) else {
            return "PHP \(site.php) is not installed. Run: nexus install php \(site.php)"
        }

        guard site.server == .nginx || installed.contains(where: { $0.name == "httpd" }) else {
            return "It uses Apache, and Apache is not installed. Run: nexus install httpd 2.4"
        }

        do {
            try WebConfigPath.validate(site.documentRoot)
        } catch {
            return String(describing: error)
        }

        return nil
    }

    // What the configuration of nginx and Apache takes from the sites. A new public folder in a
    // project changes its document root.
    static func signature(of sites: [Site]) -> [String] {
        sites.map { "\($0.hosts.joined(separator: " ")) \($0.documentRoot.path(percentEncoded: false)) \($0.php) \($0.server.rawValue)" }
    }

    // The hosts outside the dev TLD need a line in /etc/hosts. The DNS server answers the others.
    func etcHosts(_ state: EngineState) -> [String] {
        let tld = DNSResponder(tld: state.tld)
        let siteHosts = resolvedSites(state).flatMap(\.site.hosts).filter { !tld.contains($0) }
        return Set(state.hosts).union(siteHosts).sorted()
    }

    func runtime(named name: String, line: String) async -> InstalledRuntime? {
        await installer.installedRuntimes().first { $0.name == name && $0.line == line }
    }

    func newestRuntime(named name: String) async -> InstalledRuntime? {
        Self.newest(name, in: await installer.installedRuntimes())
    }

    static func newest(_ name: String, in installed: [InstalledRuntime]) -> InstalledRuntime? {
        installed.filter { $0.name == name }.max { VersionLine.isOlder($0.line, than: $1.line) }
    }

    func url(for host: String) async -> String {
        Self.url(for: host, in: await stateStore.current())
    }

    static func url(for host: String, in state: EngineState) -> String {
        let port = state.ports[ServiceCatalog.httpsPortKey] ?? 443
        return port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    // Writes every configuration file and checks it with the program that reads it. A file
    // that the check refuses goes back to its old content, so a running server keeps working.
    func writeWebConfig() async throws -> WebPlan {
        let state = await stateStore.current()
        let resolved = resolveSites(state)
        let installed = await installer.installedRuntimes()
        let apache = await newestRuntime(named: "httpd")
        var plan = WebPlan(warnings: resolved.conflicts, siteSignature: Self.signature(of: resolved.sites.map(\.site)))
        let root = resolved.sites.isEmpty ? nil : try certificateAuthority.root()

        // A site that cannot run is left out with a warning, so it does not stop the others.
        // Without nginx no site runs. The check below the loop says that.
        for (site, _) in resolved.sites {
            if let problem = Self.problem(of: site, installed: installed, checksNginx: false) {
                plan.warnings.append("\(site.host) does not run. \(problem)")
                continue
            }

            guard let root else {
                continue
            }

            let certificate = try certificateAuthority.hostCertificate(for: site.hosts, root: root)
            plan.sites.append(WebSite(
                hosts: site.hosts,
                documentRoot: site.documentRoot,
                server: site.server,
                phpSocket: paths.phpSocket(line: site.php),
                certificate: certificate.certificateFile,
                key: certificate.keyFile,
                accessLog: paths.siteLog(site.host)
            ))
            plan.phpLines.insert(site.php)
        }

        plan.needsApache = plan.sites.contains { $0.server == .apache }
        try FileManager.default.createDirectory(at: paths.siteLogs, withIntermediateDirectories: true)

        for line in plan.phpLines.sorted() where try await writePHPConfig(line: line, state: state) {
            plan.changedPHPLines.insert(line)
        }

        guard let nginx = await newestRuntime(named: "nginx") else {
            if plan.sites.isEmpty {
                return plan
            }
            throw RuntimeError.unsupported("The sites need nginx. Run: nexus install nginx 1.30")
        }

        let nginxPorts = try await ports(for: nginx)
        var apachePort = 0

        // Apache gets its file also without Apache sites, so nexus start apache always works.
        if let apache {
            apachePort = try await ports(for: apache)[ServiceCatalog.apacheID] ?? 0
            let modules = ApacheConfig.dependencies.loadOrder(state.apacheModules ?? ApacheConfig.defaultModules, available: Self.apacheModules(of: apache))
            let settings = ApacheSettings(port: apachePort, runtime: apache.folder, runFolder: paths.run, modules: modules)
            try FileManager.default.createDirectory(at: paths.run.appending(path: "apache"), withIntermediateDirectories: true)
            try writeChecked(try ApacheConfig.render(sites: plan.sites, settings: settings), to: paths.apacheConfig) {
                try Self.check(apache.folder.appending(path: "bin/httpd"), ["-t", "-f", paths.apacheConfig.path(percentEncoded: false)])
            }
        }

        let settings = NginxSettings(
            httpPort: nginxPorts[ServiceCatalog.httpPortKey] ?? 80,
            httpsPort: nginxPorts[ServiceCatalog.httpsPortKey] ?? 443,
            apachePort: apachePort,
            lanAccess: state.lanAccess,
            runtime: nginx.folder,
            runFolder: paths.run,
            modules: NginxConfig.dependencies.loadOrder(state.nginxModules, available: Self.nginxModules(of: nginx))
        )

        for folder in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"] {
            try FileManager.default.createDirectory(at: paths.run.appending(path: "nginx/\(folder)"), withIntermediateDirectories: true)
        }

        let nginxFolder = paths.nginxConfig.deletingLastPathComponent()
        try writeChecked(try NginxConfig.render(sites: plan.sites, settings: settings), to: paths.nginxConfig) {
            try Self.check(nginx.folder.appending(path: "sbin/nginx"), ["-t", "-p", nginxFolder.path(percentEncoded: false), "-c", paths.nginxConfig.path(percentEncoded: false), "-e", "stderr"])
        }

        return plan
    }

    // Returns true when the configuration of this PHP version changed.
    func writePHPConfig(line: String, state: EngineState) async throws -> Bool {
        guard let runtime = await runtime(named: "php", line: line) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed. Run: nexus install php \(line)")
        }

        let folder = paths.phpConfigFolder(line: line)
        let confD = folder.appending(path: "conf.d", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        let ini = folder.appending(path: "php.ini")
        if !FileManager.default.fileExists(atPath: ini.path(percentEncoded: false)) {
            let template = (try? String(contentsOf: runtime.folder.appending(path: "share/php.ini-development"), encoding: .utf8)) ?? ""
            try Data(PHPConfig.initialIni(template: template, timezone: TimeZone.current.identifier).utf8).write(to: ini)
        }

        let fpm = try PHPConfig.fpmConfig(socket: paths.phpSocket(line: line), pidFile: paths.run.appending(path: "php-\(line).pid"))
        let enabled = state.phpExtensions[line] ?? PHPConfig.defaultExtensions
        let (directory, available) = Self.phpExtensions(of: runtime)
        let nexusIni = try PHPConfig.nexusIni(extensionDirectory: directory, extensions: PHPConfig.extensionsToLoad(enabled: enabled, available: available))

        let customIni = PHPConfig.customIni(lines: state.phpCustomSettings[line] ?? [])

        let fpmChanged = try Self.writeIfChanged(fpm, to: folder.appending(path: "php-fpm.conf"))
        let iniChanged = try Self.writeIfChanged(nexusIni, to: confD.appending(path: PHPConfig.nexusIniName))
        let customChanged = try Self.writeIfChanged(customIni, to: confD.appending(path: PHPConfig.customIniName))
        return fpmChanged || iniChanged || customChanged
    }

    // The extension folder has a name with the API version, for example
    // no-debug-non-zts-20250925. It is the folder that holds .so files.
    static func phpExtensions(of runtime: InstalledRuntime) -> (directory: URL, available: Set<String>) {
        let root = runtime.folder.appending(path: "lib/php/extensions", directoryHint: .isDirectory)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for folder in folders {
            let available = Set(files(in: folder, suffix: ".so").map { String($0.dropLast(3)) })
            if !available.isEmpty {
                return (folder, available)
            }
        }

        return (root, [])
    }

    // The folders that hold the .so files of a runtime. PHP has a folder with the API version in
    // its name.
    static func toggleFolders(of runtime: InstalledRuntime) -> [URL] {
        switch runtime.name {
        case "php":
            let root = runtime.folder.appending(path: "lib/php/extensions", directoryHint: .isDirectory)
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return [root] + folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
        case "httpd", "nginx":
            return [runtime.folder.appending(path: "modules", directoryHint: .isDirectory)]
        default:
            return []
        }
    }

    static func apacheModules(of runtime: InstalledRuntime) -> Set<String> {
        Set(files(in: runtime.folder.appending(path: "modules"), suffix: ".so").filter { $0.hasPrefix("mod_") }.map { String($0.dropFirst(4).dropLast(3)) })
            .subtracting(ApacheConfig.otherMPMs)
    }

    static func nginxModules(of runtime: InstalledRuntime) -> Set<String> {
        Set(files(in: runtime.folder.appending(path: "modules"), suffix: ".so").map { String($0.dropLast(3)) })
    }

    private static func files(in folder: URL, suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(suffix) }
    }

    // Starts what the sites need and makes the running servers read their new configuration. A
    // web service that no site needs stops, unless the user started it with nexus start. See
    // WebChange for what each kind of change starts and stops.
    @discardableResult
    func applyWeb(_ change: WebChange = .sites) async throws -> [String] {
        let plan = try await writeWebConfig()
        let state = await stateStore.current()
        let enabled = state.enabledServices

        switch change {
        case .sites, .automatic:
            var needed: Set<String> = []
            var waiting: Set<String> = []
            let stopAllInEffect = change == .automatic && !state.stoppedByStopAll.isEmpty
            let waits = { (id: String) in
                stopAllInEffect && (state.stoppedByStopAll.contains(id) || !enabled.contains(id))
            }

            for line in plan.phpLines.sorted() {
                let id = ServiceCatalog.phpID(line: line)
                needed.insert(id)

                if try await !ensureRunning(id, reload: plan.changedPHPLines.contains(line) ? SIGUSR2 : nil, waits: waits(id)) {
                    waiting.insert(id)
                }
            }

            for status in await supervisor.status() where status.id.hasPrefix("php-") && status.state.isActive {
                if !plan.phpLines.contains(String(status.id.dropFirst(4))), !enabled.contains(status.id) {
                    try await supervisor.stop(status.id)
                }
            }

            for (id, isNeeded, signal) in [(ServiceCatalog.apacheID, plan.needsApache, SIGUSR1), (ServiceCatalog.nginxID, !plan.sites.isEmpty, SIGHUP)] {
                if isNeeded {
                    needed.insert(id)
                }

                if try await !apply(id, needed: isNeeded, enabled: enabled, reload: signal, waits: waits(id)) {
                    waiting.insert(id)
                }
            }

            // A needed service that runs leaves the list of "Stop all services", as after nexus
            // start. Otherwise it waits again at the next start of nexusd, although it ran.
            let running = needed.subtracting(waiting)

            if !waiting.isEmpty || !running.isDisjoint(with: state.stoppedByStopAll) {
                try await stateStore.update {
                    $0.stoppedByStopAll.formUnion(waiting)
                    $0.stoppedByStopAll.subtract(running)
                }
            }
        case .setting:
            for line in plan.changedPHPLines.sorted() where await supervisor.state(of: ServiceCatalog.phpID(line: line))?.isActive == true {
                try await reload(ServiceCatalog.phpID(line: line), SIGUSR2)
            }

            for (id, signal) in [(ServiceCatalog.apacheID, SIGUSR1), (ServiceCatalog.nginxID, SIGHUP)] where await supervisor.state(of: id)?.isActive == true {
                try await reload(id, signal)
            }
        }

        // Only a change that the servers took counts. After a failure, the next change in a
        // parked folder tries again.
        appliedSites = plan.siteSignature

        if etcHosts(await stateStore.current()) != writtenHosts ?? [] {
            await applySystemFiles()
        }

        return plan.warnings
    }

    // Returns false when a needed service waits for "Start stopped services".
    private func apply(_ id: String, needed: Bool, enabled: Set<String>, reload: Int32, waits: Bool) async throws -> Bool {
        let running = await supervisor.state(of: id)?.isActive == true

        if needed {
            return try await ensureRunning(id, reload: reload, waits: waits)
        }

        if running, enabled.contains(id) {
            try await self.reload(id, reload)
        } else if running {
            try await supervisor.stop(id)
        }

        return true
    }

    // A service that does not run stays stopped when it waits for "Start stopped services". The
    // answer is false then.
    private func ensureRunning(_ id: String, reload: Int32?, waits: Bool) async throws -> Bool {
        if await supervisor.state(of: id)?.isActive == true {
            if let reload {
                try await self.reload(id, reload)
            }
            return true
        }

        if waits {
            return false
        }

        _ = try await startService(id)
        return true
    }

    // The process stays. The supervisor gets the definition of the new configuration. So a new
    // port of Apache shows at once, without a stop of Apache. A reload that moves a service to
    // a new port waits until that port accepts connections. When it does not, the change fails.
    private func reload(_ id: String, _ signal: Int32) async throws {
        guard let definition = try? await serviceDefinition(id) else {
            await supervisor.signal(id, signal)
            return
        }

        let previousPorts = await supervisor.status().first { $0.id == id }?.ports
        await supervisor.reload(definition, signal: signal)

        if previousPorts != definition.ports {
            try await waitForConnections(definition)
        }
    }

    private func writeChecked(_ contents: String, to file: URL, check: () throws -> Void) throws {
        let previous = try? Data(contentsOf: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file, options: .atomic)

        do {
            try check()
        } catch {
            if let previous {
                try? previous.write(to: file, options: .atomic)
            }
            throw error
        }
    }

    private static func writeIfChanged(_ contents: String, to file: URL) throws -> Bool {
        if (try? String(contentsOf: file, encoding: .utf8)) == contents {
            return false
        }

        try Data(contents.utf8).write(to: file, options: .atomic)
        return true
    }

    private static func check(_ program: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RuntimeError.unsupported("\(program.lastPathComponent) refused the new configuration: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// The commands for sites and parked folders.
extension NexusEngine {
    func siteInfo() async -> [SiteInfo] {
        await siteList().sites
    }

    func siteList() async -> SiteList {
        let state = await stateStore.current()
        let resolved = resolvedSites(state)
        let installed = await installer.installedRuntimes()
        let nodeLines = installed.filter { $0.name == "node" }.map(\.line)
        let layout = Self.layout(state.siteLayout, sites: resolved.map(\.site), state: state)
        var groups: [String: String] = [:]

        for case .group(let name, let hosts) in layout {
            for host in hosts {
                groups[host] = name
            }
        }

        let hasRepositories = resolved.contains { ProjectFolder.repository(of: $0.site) != nil }
        let git = hasRepositories ? await GitTool.executable() : nil
        var sites: [SiteInfo] = []

        for (site, parked) in resolved {
            sites.append(SiteInfo(
                hosts: site.hosts,
                folder: Self.displayPath(site.folder),
                documentRoot: Self.displayPath(site.documentRoot),
                php: site.php,
                server: site.server,
                parked: parked,
                url: Self.url(for: site.host, in: state),
                group: groups[site.host],
                parkedFolder: Self.parkedFolder(of: site, in: state.parked).map { Self.displayPath($0.folder) },
                problem: Self.problem(of: site, installed: installed),
                projectNode: site.node == nil ? NodeLines.choose(hint: nodeHint(of: site.folder), installed: nodeLines) : nil,
                nodeSetting: site.node,
                automaticWorkspaces: site.createsWorkspaces,
                workspaces: state.worktrees[ProjectFolder.workspaceKey(of: site)]?.workspaces ?? [],
                workspaceProblem: ProjectFolder.repository(of: site) != nil && git == nil ? GitTool.missing : nil
            ))
        }

        return SiteList(sites: sites, layout: layout, parkedFolders: state.parked.map { Self.displayPath($0.folder) }, defaults: state.siteDefaults, tld: state.tld)
    }

    // A site that the layout does not name yet comes at the end, in the order that the user added
    // it. A site of a parked folder shows in that folder, so it is in the layout only in a group.
    static func layout(_ stored: [SiteLayoutEntry], sites: [Site], state: EngineState) -> [SiteLayoutEntry] {
        let outside = state.sites.filter { parkedFolder(of: $0, in: state.parked) == nil }.map(\.host)
        return stored.normalized(hosts: Set(sites.map(\.host)), outside: outside)
    }

    static func parkedFolder(of site: Site, in parked: [ParkedFolder]) -> ParkedFolder? {
        let parent = displayPath(site.folder.deletingLastPathComponent())
        return parked.first { displayPath($0.folder) == parent }
    }

    // The path of a folder without the / at the end, so that two names of one folder compare as
    // equal.
    static func displayPath(_ folder: URL) -> String {
        RealPath.trimmed(folder.standardizedFileURL.path(percentEncoded: false))
    }

    // A group needs a name, and a host can be in one place only. The app sends the whole layout
    // after each change, so nexusd only checks it.
    func setSiteLayout(_ layout: [SiteLayoutEntry]) async throws -> String {
        var groups: Set<String> = []
        var hosts: Set<String> = []
        var checked: [SiteLayoutEntry] = []

        for entry in layout {
            switch entry {
            case .site(let host):
                guard hosts.insert(host).inserted else {
                    throw RuntimeError.unsupported("\(host) is in the order of the sites two times.")
                }
                checked.append(entry)
            case .group(let rawName, let members):
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !name.isEmpty else {
                    throw RuntimeError.unsupported("A group needs a name.")
                }

                guard groups.insert(name.lowercased()).inserted else {
                    throw RuntimeError.unsupported("There is a group \(name) already.")
                }

                for host in members where !hosts.insert(host).inserted {
                    throw RuntimeError.unsupported("\(host) is in the order of the sites two times.")
                }

                checked.append(.group(name: name, hosts: members))
            }
        }

        try await stateStore.update { $0.siteLayout = checked }
        return "Nexus keeps the new order of the sites."
    }

    // The defaults apply to the sites that come after the change (D59). Only a changed version
    // must be installed. The app and nexus site defaults send the stored versions back with each
    // change. A stored version can be removed later.
    func setSiteDefaults(_ requested: SiteDefaults) async throws -> String {
        let current = await stateStore.current().siteDefaults
        var defaults = requested

        if let php = defaults.php, php != current.php {
            guard await runtime(named: "php", line: php) != nil else {
                throw RuntimeError.unsupported("PHP \(php) is not installed. Run: nexus install php \(php)")
            }
        }

        if let node = defaults.node, node != current.node {
            defaults.node = try await nodeLine(node)
        }

        try await stateStore.update { $0.siteDefaults = defaults }
        return "\(defaults.summary) The sites that exist do not change."
    }

    func addSite(folder path: String, host: String?, aliases: [String], php: String?, server: WebServer?, group: String? = nil) async throws -> String {
        let folder = try Self.validatedFolder(path)
        let state = await stateStore.current()
        let host = try HostName.validated(host ?? "\(HostName.label(from: folder.lastPathComponent)).\(state.tld)")
        let group = group?.trimmingCharacters(in: .whitespacesAndNewlines)

        if state.sites.contains(where: { $0.host == host }) {
            throw RuntimeError.unsupported("\(host) exists already. Change it with: nexus site edit \(host)")
        }

        let site = Site(host: host, folder: folder, aliases: try aliases.map(HostName.validated), php: try await phpLine(php), server: server ?? state.siteDefaults.server, node: await defaultNodeLine())
        try checkUnique(site, in: state)

        return try await siteMessage(site, warnings: changeWeb { state in
            state.sites.append(site)

            if let group, !group.isEmpty {
                state.siteLayout = state.siteLayout.moving(host, toGroup: group)
            }
        })
    }

    // Changes the state and applies it to the web servers. When that fails, the sites and the
    // web settings go back to what they were, so a site that cannot run does not stay behind. A
    // change of a setting starts and stops no service (see WebChange).
    func changeWeb(_ kind: WebChange = .sites, _ change: @Sendable (inout EngineState) -> Void) async throws -> [String] {
        let previous = await stateStore.current()
        try await stateStore.update(change)

        do {
            return try await applyWeb(kind)
        } catch {
            try? await stateStore.update { state in
                state.tld = previous.tld
                state.sites = previous.sites
                state.parked = previous.parked
                state.siteLayout = previous.siteLayout
                state.lanAccess = previous.lanAccess
                state.apacheModules = previous.apacheModules
                state.nginxModules = previous.nginxModules
                state.ports = previous.ports
            }
            _ = try? await applyWeb(kind)
            throw error
        }
    }

    func removeSite(_ host: String) async throws -> String {
        let state = await stateStore.current()

        guard state.sites.contains(where: { $0.host == host }) else {
            if let parked = resolvedSites(state).first(where: { $0.site.host == host && $0.parked }) {
                throw RuntimeError.unsupported("\(host) comes from the parked folder \(parked.site.folder.deletingLastPathComponent().path(percentEncoded: false)). Remove the subfolder, or run: nexus unpark")
            }
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        // A project in a parked folder stays a site with the settings of the folder. So it keeps its
        // place in a group.
        var withoutSite = state
        withoutSite.sites.removeAll { $0.host == host }
        let staysParked = resolvedSites(withoutSite).contains { $0.site.host == host }

        let warnings = try await changeWeb { state in
            state.sites.removeAll { $0.host == host }

            if !staysParked {
                state.siteLayout = state.siteLayout.moving(host, toGroup: nil)
            }
        }
        return (["\(host) is removed."] + warnings).joined(separator: "\n")
    }

    // A parked site gets an added site with the same host, so its new settings stay. An added
    // site keeps its place in the list, so its place in the sidebar does not change.
    func editSite(_ host: String, change: SiteChange) async throws -> String {
        let state = await stateStore.current()

        guard var site = resolvedSites(state).first(where: { $0.site.host == host })?.site else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        if let php = change.php {
            site.php = try await phpLine(php)
        }
        if let server = change.server {
            site.server = server
        }
        if let aliases = change.aliases {
            site.aliases = try aliases.map(HostName.validated)
        }
        if let node = change.node {
            site.node = try await nodeLine(node)
        }
        if let automaticWorkspaces = change.automaticWorkspaces {
            site.automaticWorkspaces = automaticWorkspaces
        }

        try checkUnique(site, in: state)

        let edited = site
        let store: @Sendable (inout EngineState) -> Void = { state in
            if let index = state.sites.firstIndex(where: { $0.host == host }) {
                state.sites[index] = edited
            } else {
                state.sites.append(edited)
            }
        }

        // The Node line and the workspace setting change no server. So they need no new web
        // configuration.
        let onlySettings = (change.node != nil || change.automaticWorkspaces != nil) && change.php == nil && change.server == nil && change.aliases == nil
        var notes = onlySettings ? [] : try await changeWeb(.sites, store)

        if onlySettings {
            try await stateStore.update(store)
        }

        if let node = change.node {
            let used = node == NodeLines.fromProject ? "the Node version of the project" : "Node \(node)"
            notes.insert("nexus node and nexus npm use \(used) in its folder.", at: 0)
        }

        if change.automaticWorkspaces != nil {
            let key = ProjectFolder.workspaceKey(of: edited)
            let sites = resolvedSites(await stateStore.current()).map(\.site)
            let createsWorkspaces = sites.contains { ProjectFolder.workspaceKey(of: $0) == key && $0.createsWorkspaces }
            notes.append(createsWorkspaces ? "A new worktree gets a workspace." : "A new worktree gets no workspace.")
        }

        return await siteMessage(edited, warnings: notes)
    }

    func park(folder path: String, php: String?, server: WebServer?) async throws -> String {
        let folder = try Self.validatedFolder(path)
        let state = await stateStore.current()

        if state.parked.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            throw RuntimeError.unsupported("\(folder.path(percentEncoded: false)) is parked already.")
        }

        let parked = ParkedFolder(folder: folder, php: try await phpLine(php), server: server ?? state.siteDefaults.server, node: await defaultNodeLine())
        let warnings = try await changeWeb { $0.parked.append(parked) }
        await watchParkedFolders()
        let hosts = parked.sites(tld: state.tld).map(\.host)
        return (["\(folder.path(percentEncoded: false)) is parked. Its \(hosts.count) sites: \(hosts.joined(separator: ", ")). A new folder in it becomes a site too."] + warnings).joined(separator: "\n")
    }

    func unpark(folder path: String) async throws -> String {
        let folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL

        guard await stateStore.current().parked.contains(where: { $0.folder.standardizedFileURL == folder }) else {
            throw RuntimeError.unsupported("\(folder.path(percentEncoded: false)) is not parked.")
        }

        let warnings = try await changeWeb { $0.parked.removeAll { $0.folder.standardizedFileURL == folder } }
        await watchParkedFolders()
        return (["\(folder.path(percentEncoded: false)) is not parked now."] + warnings).joined(separator: "\n")
    }

    // nexusd watches each parked folder, also without the app (D62). A new, removed or renamed
    // project, or a new public folder in a project, changes the sites. A change deeper in a
    // project, for example in vendor, does not.
    func watchParkedFolders() async {
        let folders = await stateStore.current().parked.map(\.folder)
        let watched = Set(folders.map(RealPath.of))

        parkedWatcher?.stop()
        parkedWatcher = FolderWatcher(folders: folders) { [weak self] changed in
            let matters = changed.contains { path in
                let folder = RealPath.trimmed(path)
                return watched.contains(folder) || watched.contains((folder as NSString).deletingLastPathComponent)
            }

            if matters {
                Task { await self?.parkedFoldersChanged() }
            }
        }
    }

    // FSEvents also reports a change that gives the same sites, for example a new file in a
    // project. Then nothing happens. A change that waits for its turn while nexusd shuts down or
    // uninstalls starts nothing. Shutdown removes the watch first, and uninstall sets its flag
    // first.
    private func parkedFoldersChanged() async {
        let changed = (try? await serialWeb { try await self.applyParkedSites() }) ?? true

        if changed {
            sitesChanged()
        }
    }

    // Returns false when the sites stay the same.
    private func applyParkedSites() async throws -> Bool {
        guard parkedWatcher != nil, !uninstalling else {
            return false
        }

        let sites = Self.signature(of: resolvedSites(await stateStore.current()).map(\.site))

        guard sites != appliedSites else {
            return false
        }

        try await applyWeb(.automatic)
        return true
    }

    func lan(_ enabled: Bool?) async throws -> String {
        if let enabled {
            _ = try await changeWeb(.setting) { $0.lanAccess = enabled }
        }

        return await stateStore.current().lanAccess
            ? "Other devices on the network can open the sites."
            : "Only this Mac can open the sites. Other devices get a 403."
    }

    private func siteMessage(_ site: Site, warnings: [String]) async -> String {
        (["\(await url(for: site.host)) runs on \(site.server.displayName) with PHP \(site.php). Folder: \(site.documentRoot.path(percentEncoded: false))"] + warnings).joined(separator: "\n")
    }

    // Without a request, a new site gets the PHP version of the defaults (D59). A default that is
    // not installed anymore gives the newest version, so a new project in a parked folder still
    // becomes a site.
    func phpLine(_ requested: String?) async throws -> String {
        try Self.phpLine(requested, installed: await installer.installedRuntimes(), defaults: await stateStore.current().siteDefaults)
    }

    static func phpLine(_ requested: String?, installed runtimes: [InstalledRuntime], defaults: SiteDefaults) throws -> String {
        let installed = runtimes.filter { $0.name == "php" }.map(\.line)

        if let requested {
            guard installed.contains(requested) else {
                throw RuntimeError.unsupported("PHP \(requested) is not installed. Run: nexus install php \(requested)")
            }
            return requested
        }

        if let preferred = defaults.php, installed.contains(preferred) {
            return preferred
        }

        guard let newest = VersionLine.newest(installed) else {
            throw RuntimeError.unsupported("No PHP version is installed. Run: nexus install php 8.5")
        }

        return newest
    }

    private func checkUnique(_ site: Site, in state: EngineState) throws {
        let others = resolvedSites(state).filter { $0.site.host != site.host }.flatMap(\.site.hosts)

        if let taken = site.hosts.first(where: others.contains) {
            throw RuntimeError.unsupported("\(taken) belongs to another site already.")
        }
    }

    private static func validatedFolder(_ path: String) throws -> URL {
        let folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false

        guard folder.path(percentEncoded: false).hasPrefix("/"),
              FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RuntimeError.unsupported("\(path) is not a folder.")
        }

        try WebConfigPath.validate(folder)
        return folder
    }
}

// The extension and module toggles (D25, D27).
extension NexusEngine {
    func extensionToggles(line: String) async throws -> [Toggle] {
        guard let runtime = await runtime(named: "php", line: line) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed.")
        }

        return Self.extensionToggles(line: line, available: toggleNames(of: runtime), state: await stateStore.current())
    }

    // A switch shows what loads. An extension that another one needs loads also when the state
    // does not name it, for example igbinary in a state from before the dependencies.
    static func extensionToggles(line: String, available: Set<String>, state: EngineState) -> [Toggle] {
        let loaded = Set(PHPConfig.extensionsToLoad(enabled: state.phpExtensions[line] ?? PHPConfig.defaultExtensions, available: available))

        return available.sorted().map {
            Toggle(name: $0, enabled: loaded.contains($0), required: false, help: ToggleHelp.phpExtension($0))
        }
    }

    // A change of a version file changes its modification date. So nexusd reads the files of a
    // site again only after such a change. A missing file has the date 0.
    func nodeHint(of folder: URL) -> NodeVersionHint? {
        let key = folder.path(percentEncoded: false)
        let stamp = NodeVersionFiles.names.map { name in
            let date = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path(percentEncoded: false)))?[.modificationDate] as? Date
            return date?.timeIntervalSince1970 ?? 0
        }

        if let cached = nodeHintCache[key], cached.stamp == stamp {
            return cached.hint
        }

        let hint = NodeVersionFiles.hint(from: folder, upTo: folder)
        nodeHintCache[key] = (stamp, hint)
        return hint
    }

    // An install, a removal and a manual copy of a .so file all change the modification date of
    // its folder. So the names stay in the cache until that date changes. New names send the
    // service list again, also after a request that only reads.
    func toggleNames(of runtime: InstalledRuntime) -> Set<String> {
        let key = "\(runtime.folder.path(percentEncoded: false)) \(runtime.version)"
        let stamp = Self.toggleFolders(of: runtime).map { folder in
            let date = (try? FileManager.default.attributesOfItem(atPath: folder.path(percentEncoded: false)))?[.modificationDate] as? Date
            return "\(folder.lastPathComponent) \(date?.timeIntervalSince1970 ?? 0)"
        }
        let cached = toggleNameCache[key]

        if let cached, cached.stamp == stamp {
            return cached.names
        }

        let names: Set<String> = switch runtime.name {
        case "php": Self.phpExtensions(of: runtime).available
        case "httpd": Self.apacheModules(of: runtime)
        case "nginx": Self.nginxModules(of: runtime)
        default: []
        }

        toggleNameCache[key] = (stamp, names)

        if let cached, cached.names != names {
            servicesChanged()
        }

        return names
    }

    // A switch shows a name as on also when it loads because another name needs it. A change
    // keeps such a name on, as its switch shows.
    private static func shownOn(_ enabled: Set<String>, dependencies: ToggleDependencies, available: Set<String>) -> Set<String> {
        enabled.union(dependencies.loadOrder(enabled, available: available))
    }

    func setExtension(line: String, name: String, enabled: Bool) async throws -> String {
        guard let runtime = await runtime(named: "php", line: line) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed.")
        }

        let available = toggleNames(of: runtime)

        guard available.contains(name) else {
            throw RuntimeError.unsupported("PHP \(line) has no shared extension \(name). See: nexus ext \(line)")
        }

        if enabled, let missing = PHPConfig.dependencies.missing(for: name, available: available).first {
            throw RuntimeError.unsupported("\(name) needs \(missing). PHP \(line) has no shared extension \(missing).")
        }

        let current = Self.shownOn(await stateStore.current().phpExtensions[line] ?? PHPConfig.defaultExtensions, dependencies: PHPConfig.dependencies, available: available)
        let (updated, changed) = PHPConfig.dependencies.set(name, on: enabled, in: current)
        try await stateStore.update { $0.phpExtensions[line] = updated }

        if try await writePHPConfig(line: line, state: await stateStore.current()) {
            await supervisor.signal(ServiceCatalog.phpID(line: line), SIGUSR2)
        }

        return "\(EnglishList.joined(changed.sorted())) \(enabled ? "on" : "off") for PHP \(line). Other PHP versions do not change."
    }

    func moduleToggles(_ server: WebServer) async throws -> [Toggle] {
        let runtime = try await webRuntime(server)
        return Self.moduleToggles(server, available: toggleNames(of: runtime), state: await stateStore.current())
    }

    // A switch shows what loads, as for the extensions. nginx shows its built-in modules first.
    // They are always on.
    static func moduleToggles(_ server: WebServer, available: Set<String>, state: EngineState) -> [Toggle] {
        switch server {
        case .apache:
            let loaded = Set(ApacheConfig.dependencies.loadOrder(state.apacheModules ?? ApacheConfig.defaultModules, available: available))
            return available.sorted().map {
                let required = ApacheConfig.requiredModules.contains($0)
                return Toggle(name: $0, enabled: required || loaded.contains($0), required: required, help: ToggleHelp.apacheModule($0))
            }
        case .nginx:
            let loaded = Set(NginxConfig.dependencies.loadOrder(state.nginxModules, available: available))
            let builtIn = NginxConfig.builtInModules.map { Toggle(name: $0, enabled: true, required: true, help: ToggleHelp.nginxModule($0)) }
            return builtIn + available.sorted().map {
                Toggle(name: $0, enabled: loaded.contains($0), required: false, help: ToggleHelp.nginxModule($0))
            }
        }
    }

    // A module that another module needs changes with it. So the answer can name more modules.
    func setModule(_ server: WebServer, name: String, enabled: Bool) async throws -> String {
        let runtime = try await webRuntime(server)
        let changed: [String]

        switch server {
        case .apache:
            guard !ApacheConfig.otherMPMs.contains(name) else {
                throw RuntimeError.unsupported("Apache loads only one MPM. Nexus uses mpm_event. So \(name) stays off.")
            }

            let available = toggleNames(of: runtime)

            guard available.contains(name) else {
                throw RuntimeError.unsupported("Apache has no module \(name). See: nexus module apache")
            }

            guard !ApacheConfig.requiredModules.contains(name) else {
                throw RuntimeError.unsupported("Apache needs \(name) behind nginx. So it cannot be turned off.")
            }

            if enabled, let missing = ApacheConfig.dependencies.missing(for: name, available: available).first {
                throw RuntimeError.unsupported("\(name) needs \(missing). Apache has no module \(missing).")
            }

            let current = Self.shownOn(await stateStore.current().apacheModules ?? ApacheConfig.defaultModules, dependencies: ApacheConfig.dependencies, available: available)
            let change = ApacheConfig.dependencies.set(name, on: enabled, in: current)
            changed = change.changed
            _ = try await changeWeb(.setting) { $0.apacheModules = change.enabled }
        case .nginx:
            guard !NginxConfig.builtInModules.contains(name) else {
                throw RuntimeError.unsupported("\(name) is part of nginx. Every site needs it. So it is always on.")
            }

            let available = toggleNames(of: runtime)

            guard available.contains(name) else {
                throw RuntimeError.unsupported("nginx has no module \(name). See: nexus module nginx")
            }

            if enabled, let missing = NginxConfig.dependencies.missing(for: name, available: available).first {
                throw RuntimeError.unsupported("\(name) needs \(missing). nginx has no module \(missing).")
            }

            let current = Self.shownOn(await stateStore.current().nginxModules, dependencies: NginxConfig.dependencies, available: available)
            let change = NginxConfig.dependencies.set(name, on: enabled, in: current)
            changed = change.changed
            try await changeAndRestartNginx { $0.nginxModules = change.enabled }
        }

        let names = EnglishList.joined(changed.sorted())
        return "\(names) \(changed.count == 1 ? "is" : "are") \(enabled ? "on" : "off") for \(server.displayName)."
    }

    private func webRuntime(_ server: WebServer) async throws -> InstalledRuntime {
        switch server {
        case .apache:
            guard let apache = await newestRuntime(named: "httpd") else {
                throw RuntimeError.unsupported("Apache is not installed. Run: nexus install httpd 2.4")
            }
            return apache
        case .nginx:
            guard let nginx = await newestRuntime(named: "nginx") else {
                throw RuntimeError.unsupported("nginx is not installed. Run: nexus install nginx 1.30")
            }
            return nginx
        }
    }

    func setWebPort(_ key: String, _ port: Int) async throws -> String {
        let current = await stateStore.current().ports[key]

        if current != port, !PortInspector.isFree(port) {
            throw SupervisorError.portInUse(port: port, owner: PortInspector.owner(of: port))
        }

        // A graceful restart moves Apache to the new port. nginx then reads the new port of Apache.
        if key == ServiceCatalog.apacheID {
            _ = try await changeWeb(.setting) { $0.ports[key] = port }
            return "Apache uses port \(port) on 127.0.0.1."
        }

        try await changeAndRestartNginx { $0.ports[key] = port }
        return "nginx uses port \(port) for \(key.uppercased())."
    }

    // nginx opens a new port and loads a dynamic module only at a start, not when it reads its
    // configuration again. When the change fails, the old ports and modules come back. nginx then
    // starts again with them when it ran before the change. This is also true when the failed
    // start stopped it.
    private func changeAndRestartNginx(_ change: @Sendable (inout EngineState) -> Void) async throws {
        let previous = await stateStore.current()
        let running = await supervisor.state(of: ServiceCatalog.nginxID)?.isActive == true
        try await stateStore.update(change)

        do {
            try await restartNginx(running: running)
        } catch {
            try? await stateStore.update { state in
                state.ports = previous.ports
                state.nginxModules = previous.nginxModules
            }
            try? await restartNginx(running: running)
            throw error
        }
    }

    private func restartNginx(running: Bool) async throws {
        _ = try await writeWebConfig()

        if running {
            try await supervisor.stop(ServiceCatalog.nginxID)
            _ = try await startService(ServiceCatalog.nginxID)
        }
    }
}
