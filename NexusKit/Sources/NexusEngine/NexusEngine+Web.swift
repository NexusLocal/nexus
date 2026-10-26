import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTLS

struct WebPlan {
    var sites: [WebSite] = []
    var phpLines: Set<String> = []
    var changedPHPLines: Set<String> = []
    var needsApache = false
    var warnings: [String] = []
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
        await installer.installedRuntimes().filter { $0.name == name }.max { VersionLine.isOlder($0.line, than: $1.line) }
    }

    func url(for host: String) async -> String {
        let port = await stateStore.current().ports[ServiceCatalog.httpsPortKey] ?? 443
        return port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    // Writes every configuration file and checks it with the program that reads it. A file
    // that the check refuses goes back to its old content, so a running server keeps working.
    func writeWebConfig() async throws -> WebPlan {
        let state = await stateStore.current()
        let resolved = resolveSites(state)
        let apache = await newestRuntime(named: "httpd")
        var plan = WebPlan(warnings: resolved.conflicts)
        let root = resolved.sites.isEmpty ? nil : try certificateAuthority.root()

        // A site that cannot run is left out with a warning, so it does not stop the others.
        for (site, _) in resolved.sites {
            guard await runtime(named: "php", line: site.php) != nil else {
                plan.warnings.append("\(site.host) does not run, because PHP \(site.php) is not installed. Run: nexus install php \(site.php)")
                continue
            }

            guard site.server == .nginx || apache != nil else {
                plan.warnings.append("\(site.host) does not run, because it uses Apache and Apache is not installed. Run: nexus install httpd 2.4")
                continue
            }

            do {
                try WebConfigPath.validate(site.documentRoot)
            } catch {
                plan.warnings.append("\(site.host) does not run. \(error)")
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
            let modules = (state.apacheModules ?? ApacheConfig.defaultModules).intersection(Self.apacheModules(of: apache))
            let settings = ApacheSettings(port: apachePort, runtime: apache.folder, runFolder: paths.run, modules: modules.sorted())
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
            modules: state.nginxModules.intersection(Self.nginxModules(of: nginx)).sorted()
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

        let fpmChanged = try Self.writeIfChanged(fpm, to: folder.appending(path: "php-fpm.conf"))
        let iniChanged = try Self.writeIfChanged(nexusIni, to: confD.appending(path: "00-nexus.ini"))
        return fpmChanged || iniChanged
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

    static func apacheModules(of runtime: InstalledRuntime) -> Set<String> {
        Set(files(in: runtime.folder.appending(path: "modules"), suffix: ".so").filter { $0.hasPrefix("mod_") }.map { String($0.dropFirst(4).dropLast(3)) })
    }

    static func nginxModules(of runtime: InstalledRuntime) -> Set<String> {
        Set(files(in: runtime.folder.appending(path: "modules"), suffix: ".so").map { String($0.dropLast(3)) })
    }

    private static func files(in folder: URL, suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(suffix) }
    }

    // Starts what the sites need and makes the running servers read their new configuration. A
    // web service that no site needs stops, unless the user started it with nexus start.
    @discardableResult
    func applyWeb() async throws -> [String] {
        let plan = try await writeWebConfig()
        let enabled = await stateStore.current().enabledServices

        for line in plan.phpLines.sorted() {
            try await ensureRunning(ServiceCatalog.phpID(line: line), reload: plan.changedPHPLines.contains(line) ? SIGUSR2 : nil)
        }

        for status in await supervisor.status() where status.id.hasPrefix("php-") && status.state.isActive {
            if !plan.phpLines.contains(String(status.id.dropFirst(4))), !enabled.contains(status.id) {
                try await supervisor.stop(status.id)
            }
        }

        try await apply(ServiceCatalog.apacheID, needed: plan.needsApache, enabled: enabled, reload: SIGUSR1)
        try await apply(ServiceCatalog.nginxID, needed: !plan.sites.isEmpty, enabled: enabled, reload: SIGHUP)

        let state = await stateStore.current()
        if etcHosts(state) != writtenHosts ?? [] {
            await applySystemFiles()
        }

        return plan.warnings
    }

    private func apply(_ id: String, needed: Bool, enabled: Set<String>, reload: Int32) async throws {
        let running = await supervisor.state(of: id)?.isActive == true

        if needed {
            try await ensureRunning(id, reload: reload)
        } else if running, enabled.contains(id) {
            await supervisor.signal(id, reload)
        } else if running {
            try await supervisor.stop(id)
        }
    }

    private func ensureRunning(_ id: String, reload: Int32?) async throws {
        if await supervisor.state(of: id)?.isActive == true {
            if let reload {
                await supervisor.signal(id, reload)
            }
            return
        }

        _ = try await startService(id)
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
        var all: [SiteInfo] = []

        for (site, parked) in resolvedSites(await stateStore.current()) {
            all.append(SiteInfo(
                hosts: site.hosts,
                folder: site.folder.path(percentEncoded: false),
                documentRoot: site.documentRoot.path(percentEncoded: false),
                php: site.php,
                server: site.server,
                parked: parked,
                url: await url(for: site.host)
            ))
        }

        return all
    }

    func addSite(folder path: String, host: String?, aliases: [String], php: String?, server: WebServer?) async throws -> String {
        let folder = try Self.validatedFolder(path)
        let state = await stateStore.current()
        let host = try HostName.validated(host ?? "\(HostName.label(from: folder.lastPathComponent)).\(state.tld)")

        if state.sites.contains(where: { $0.host == host }) {
            throw RuntimeError.unsupported("\(host) exists already. Change it with: nexus site edit \(host)")
        }

        let site = Site(host: host, folder: folder, aliases: try aliases.map(HostName.validated), php: try await phpLine(php), server: server ?? .nginx)
        try checkUnique(site, in: state)

        return try await siteMessage(site, warnings: changeWeb { $0.sites.append(site) })
    }

    // Changes the state and applies it to the web servers. When that fails, the sites and the
    // web settings go back to what they were, so a site that cannot run does not stay behind.
    func changeWeb(_ change: @Sendable (inout EngineState) -> Void) async throws -> [String] {
        let previous = await stateStore.current()
        try await stateStore.update(change)

        do {
            return try await applyWeb()
        } catch {
            try? await stateStore.update { state in
                state.sites = previous.sites
                state.parked = previous.parked
                state.lanAccess = previous.lanAccess
                state.apacheModules = previous.apacheModules
                state.nginxModules = previous.nginxModules
                state.ports = previous.ports
            }
            _ = try? await applyWeb()
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

        let warnings = try await changeWeb { $0.sites.removeAll { $0.host == host } }
        return (["\(host) is removed."] + warnings).joined(separator: "\n")
    }

    // A parked site gets an added site with the same host, so its new settings stay.
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

        try checkUnique(site, in: state)

        let edited = site
        let warnings = try await changeWeb { state in
            state.sites.removeAll { $0.host == host }
            state.sites.append(edited)
        }

        return await siteMessage(edited, warnings: warnings)
    }

    func park(folder path: String, php: String?, server: WebServer?) async throws -> String {
        let folder = try Self.validatedFolder(path)
        let state = await stateStore.current()

        if state.parked.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            throw RuntimeError.unsupported("\(folder.path(percentEncoded: false)) is parked already.")
        }

        let parked = ParkedFolder(folder: folder, php: try await phpLine(php), server: server ?? .nginx)
        let warnings = try await changeWeb { $0.parked.append(parked) }
        let hosts = parked.sites(tld: state.tld).map(\.host)
        return (["\(folder.path(percentEncoded: false)) is parked. Its \(hosts.count) sites: \(hosts.joined(separator: ", "))"] + warnings).joined(separator: "\n")
    }

    func unpark(folder path: String) async throws -> String {
        let folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL

        guard await stateStore.current().parked.contains(where: { $0.folder.standardizedFileURL == folder }) else {
            throw RuntimeError.unsupported("\(folder.path(percentEncoded: false)) is not parked.")
        }

        let warnings = try await changeWeb { $0.parked.removeAll { $0.folder.standardizedFileURL == folder } }
        return (["\(folder.path(percentEncoded: false)) is not parked now."] + warnings).joined(separator: "\n")
    }

    func lan(_ enabled: Bool?) async throws -> String {
        if let enabled {
            _ = try await changeWeb { $0.lanAccess = enabled }
        }

        return await stateStore.current().lanAccess
            ? "Other devices on the network can open the sites."
            : "Only this Mac can open the sites. Other devices get a 403."
    }

    private func siteMessage(_ site: Site, warnings: [String]) async -> String {
        let server = site.server == .nginx ? "nginx" : "Apache"
        return (["\(await url(for: site.host)) runs on \(server) with PHP \(site.php). Folder: \(site.documentRoot.path(percentEncoded: false))"] + warnings).joined(separator: "\n")
    }

    private func phpLine(_ requested: String?) async throws -> String {
        let installed = await installer.installedRuntimes().filter { $0.name == "php" }.map(\.line)

        if let requested {
            guard installed.contains(requested) else {
                throw RuntimeError.unsupported("PHP \(requested) is not installed. Run: nexus install php \(requested)")
            }
            return requested
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

        let enabled = await stateStore.current().phpExtensions[line] ?? PHPConfig.defaultExtensions
        return Self.phpExtensions(of: runtime).available.sorted().map {
            Toggle(name: $0, enabled: enabled.contains($0), required: false)
        }
    }

    func setExtension(line: String, name: String, enabled: Bool) async throws -> String {
        guard let runtime = await runtime(named: "php", line: line) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed.")
        }

        guard Self.phpExtensions(of: runtime).available.contains(name) else {
            throw RuntimeError.unsupported("PHP \(line) has no shared extension \(name). See: nexus ext \(line)")
        }

        var current = await stateStore.current().phpExtensions[line] ?? PHPConfig.defaultExtensions
        var changed = [name]

        if enabled {
            let required = PHPConfig.dependencies[name] ?? []
            changed += required.filter { !current.contains($0) }
            current.formUnion([name] + required)
        } else {
            let dependents = PHPConfig.dependencies.filter { $0.value.contains(name) }.map(\.key).filter(current.contains)
            changed += dependents
            current.subtract([name] + dependents)
        }

        let updated = current
        try await stateStore.update { $0.phpExtensions[line] = updated }

        if try await writePHPConfig(line: line, state: await stateStore.current()) {
            await supervisor.signal(ServiceCatalog.phpID(line: line), SIGUSR2)
        }

        return "\(changed.sorted().joined(separator: " and ")) \(enabled ? "on" : "off") for PHP \(line). Other PHP versions do not change."
    }

    func moduleToggles(_ server: WebServer) async throws -> [Toggle] {
        let state = await stateStore.current()

        switch server {
        case .apache:
            let enabled = state.apacheModules ?? ApacheConfig.defaultModules
            return try await installedModules(.apache).map {
                let required = ApacheConfig.requiredModules.contains($0)
                return Toggle(name: $0, enabled: required || enabled.contains($0), required: required)
            }
        case .nginx:
            return try await installedModules(.nginx).map { Toggle(name: $0, enabled: state.nginxModules.contains($0), required: false) }
        }
    }

    func setModule(_ server: WebServer, name: String, enabled: Bool) async throws -> String {
        guard try await installedModules(server).contains(name) else {
            throw RuntimeError.unsupported("\(server == .nginx ? "nginx" : "Apache") has no module \(name). See: nexus module \(server.rawValue)")
        }

        switch server {
        case .apache:
            guard !ApacheConfig.requiredModules.contains(name) else {
                throw RuntimeError.unsupported("Apache needs \(name) behind nginx, so it cannot be turned off.")
            }

            var modules = await stateStore.current().apacheModules ?? ApacheConfig.defaultModules
            if enabled { modules.insert(name) } else { modules.remove(name) }
            let updated = modules
            _ = try await changeWeb { $0.apacheModules = updated }
        case .nginx:
            try await changeAndRestartNginx { state in
                if enabled { state.nginxModules.insert(name) } else { state.nginxModules.remove(name) }
            }
        }

        return "\(name) is \(enabled ? "on" : "off") for \(server == .nginx ? "nginx" : "Apache")."
    }

    private func installedModules(_ server: WebServer) async throws -> [String] {
        switch server {
        case .apache:
            guard let apache = await newestRuntime(named: "httpd") else {
                throw RuntimeError.unsupported("Apache is not installed. Run: nexus install httpd 2.4")
            }
            return Self.apacheModules(of: apache).sorted()
        case .nginx:
            guard let nginx = await newestRuntime(named: "nginx") else {
                throw RuntimeError.unsupported("nginx is not installed. Run: nexus install nginx 1.30")
            }
            return Self.nginxModules(of: nginx).sorted()
        }
    }

    func setWebPort(_ key: String, _ port: Int) async throws -> String {
        let current = await stateStore.current().ports[key]

        if current != port, !PortInspector.isFree(port) {
            throw SupervisorError.portInUse(port: port, owner: PortInspector.owner(of: port))
        }

        if key == ServiceCatalog.apacheID {
            _ = try await changeWeb { $0.ports[key] = port }
            return "Apache uses port \(port) on 127.0.0.1."
        }

        try await changeAndRestartNginx { $0.ports[key] = port }
        return "nginx uses port \(port) for \(key.uppercased())."
    }

    // nginx opens a new port and loads a dynamic module only at a start, not when it reads its
    // configuration again. When the change fails, the old ports and modules come back and nginx
    // starts again with them.
    private func changeAndRestartNginx(_ change: @Sendable (inout EngineState) -> Void) async throws {
        let previous = await stateStore.current()
        try await stateStore.update(change)

        do {
            try await restartNginx()
        } catch {
            try? await stateStore.update { state in
                state.ports = previous.ports
                state.nginxModules = previous.nginxModules
            }
            try? await restartNginx()
            throw error
        }
    }

    private func restartNginx() async throws {
        _ = try await writeWebConfig()

        guard await supervisor.state(of: ServiceCatalog.nginxID)?.isActive == true else {
            return
        }

        try await supervisor.stop(ServiceCatalog.nginxID)
        _ = try await startService(ServiceCatalog.nginxID)
    }
}
