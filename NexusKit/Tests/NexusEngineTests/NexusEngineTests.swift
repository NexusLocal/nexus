import Darwin
import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Synchronization
import Testing
@testable import NexusEngine

struct FixedManifest: ManifestSource {
    let manifest: Manifest

    func manifest(from url: URL) async throws -> Manifest {
        manifest
    }
}

struct CopyDownloader: PackageDownloader {
    func download(_ url: URL) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

struct NexusEngineTests {
    private let workspace = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Engine Tests \(UUID().uuidString)", directoryHint: .isDirectory)

    private let helper = RecordingHelper()
    private let keyStore = MemoryKeyStore()

    private var paths: NexusPaths {
        NexusPaths(root: workspace.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
    }

    private var systemFiles: SystemDNSFiles {
        SystemDNSFiles(
            resolverFolder: workspace.appending(path: "etc/resolver", directoryHint: .isDirectory),
            hostsFile: workspace.appending(path: "etc/hosts", directoryHint: .notDirectory)
        )
    }

    private func makeFakeRedis() throws -> ManifestPackage {
        let source = workspace.appending(path: "source/redis-1.0.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let server = source.appending(path: "redis-server")
        try Data("#!/bin/sh\nexec /usr/bin/nc -lk 127.0.0.1 \"$2\"\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path(percentEncoded: false))

        let archive = workspace.appending(path: "redis-1.0.0.tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", workspace.appending(path: "source").path(percentEncoded: false), "redis-1.0.0"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "redis", version: "1.0.0", line: "1.0", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    private func freePort() -> Int {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func makeEngine(package: ManifestPackage, port: Int, dnsPort: Int? = nil, unregister: @escaping @Sendable () -> Void = {}) throws -> NexusEngine {
        try paths.createFolders()
        var state = EngineState()
        state.ports["redis-1.0"] = port
        state.ports[NexusEngine.dnsServiceID] = dnsPort ?? freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        return makeEngine(package: package, unregister: unregister)
    }

    private func makeEngine(package: ManifestPackage, unregister: @escaping @Sendable () -> Void = {}) -> NexusEngine {
        let manifest = Manifest(schema: 1, generated: .now, repository: "test", packages: [package])
        return NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: CopyDownloader(),
            manifestSource: FixedManifest(manifest: manifest),
            systemFiles: systemFiles,
            helperRetryDelay: .milliseconds(50),
            unregister: unregister
        )
    }

    private func services(_ response: NexusResponse) -> [String: ServiceStatus] {
        guard case .services(let services) = response else {
            Issue.record("no service list: \(response)")
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
    }

    @Test func installStartStatusAndStop() async throws {
        let port = freePort()
        let engine = try makeEngine(package: try makeFakeRedis(), port: port)

        let installed = await engine.handle(.install(name: "redis", line: "1.0"))
        let started = await engine.handle(.start(service: "redis-1.0"))
        let status = await engine.handle(.status)
        let stopped = await engine.handle(.stop(service: "redis-1.0"))

        guard case .done = installed, case .done(let message) = started, case .services(let services) = status else {
            Issue.record("unexpected responses: \(installed) \(started) \(status)")
            return
        }
        #expect(message == "Redis 1.0.0 runs on port \(port).")
        #expect(services.map(\.id) == ["dns", "redis-1.0"])
        if case .running = services.last?.state {} else { Issue.record("the service does not run: \(services)") }
        #expect(stopped == .done(message: "redis-1.0 stopped."))
    }

    @Test func aStartedServiceStartsAgainWithTheEngine() async throws {
        let package = try makeFakeRedis()
        let port = freePort()
        let first = try makeEngine(package: package, port: port)
        _ = await first.handle(.install(name: "redis", line: "1.0"))
        _ = await first.handle(.start(service: "redis-1.0"))
        await first.shutdown()

        let second = makeEngine(package: package)
        await second.startEnabledServices()
        let status = services(await second.handle(.status))

        guard case .running = status["redis-1.0"]?.state, case .running = status["dns"]?.state else {
            Issue.record("the services did not start again: \(status)")
            return
        }
        await second.shutdown()
    }

    @Test func removingARunningRuntimeIsRefused() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        _ = await engine.handle(.install(name: "redis", line: "1.0"))
        _ = await engine.handle(.start(service: "redis-1.0"))

        let response = await engine.handle(.remove(name: "redis", line: "1.0"))

        #expect(response == .failure(message: "Stop redis-1.0 first. It uses redis 1.0."))
        await engine.shutdown()
    }

    @Test func aPortThatAnotherServiceHasIsRefused() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: 23456)
        _ = await engine.handle(.install(name: "redis", line: "1.0"))

        let taken = await engine.handle(.setPort(service: "dns", port: 23456))
        let free = await engine.handle(.setPort(service: "redis-1.0", port: 23457))

        #expect(taken == .failure(message: "Port 23456 belongs to redis-1.0 already."))
        #expect(free == .done(message: "redis-1.0 uses port 23457."))
    }

    @Test func onlyAKnownPortNameCanChange() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let nginx = await engine.handle(.setPort(service: "nginx", port: 8080))
        let php = await engine.handle(.setPort(service: "php-8.5", port: 9000))
        let unknown = await engine.handle(.setPort(service: "redis-9.9", port: 23458))

        #expect(nginx == .failure(message: "nginx has two ports. Run: nexus port http <port>, or: nexus port https <port>"))
        #expect(php == .failure(message: "PHP has no port. nginx and Apache reach it through a socket."))
        #expect(unknown == .failure(message: "Nexus has no port named redis-9.9. The ports are: dns."))
    }

    @Test func theDevelopmentProfileMovesPortsAwayFromTheStandardOnes() {
        #expect(PortProfile.development.defaultPort(6379) == 16379)
        #expect(PortProfile.development.defaultPort(3306) == 13306)
        #expect(PortProfile.development.defaultPort(443) == 8443)
        #expect(PortProfile.standard.defaultPort(6379) == 6379)
    }

    @Test func startingTheEngineStartsDNSAndWritesTheResolverFile() async throws {
        let dnsPort = freeUDPPort()
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), dnsPort: dnsPort)

        await engine.startEnabledServices()
        let status = services(await engine.handle(.status))

        #expect(helper.requests == [.setResolver(tld: "test", port: dnsPort), .setHosts([])])
        #expect(status["dns"]?.ports == [dnsPort])
        if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        await engine.shutdown()
    }

    @Test func dnsWithoutTheHelperIsFailedUntilTheHelperAnswers() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        helper.setReachable(false)
        await engine.startEnabledServices()

        let before = services(await engine.handle(.status))
        helper.setReachable(true)
        try await Task.sleep(for: .milliseconds(300))
        let after = services(await engine.handle(.status))

        guard case .failed(let reason) = before["dns"]?.state else {
            Issue.record("DNS is not failed: \(before)")
            return
        }
        #expect(reason.contains("Login Items & Extensions"))
        if case .running = after["dns"]?.state {} else { Issue.record("DNS does not run: \(after)") }
        #expect(helper.requests.contains { if case .setResolver = $0 { true } else { false } })
        await engine.shutdown()
    }

    @Test func aNewDNSPortMovesTheServerAndTheResolverFile() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        await engine.startEnabledServices()
        let newPort = freeUDPPort()

        let response = await engine.handle(.setPort(service: "dns", port: newPort))

        #expect(response == .done(message: "The DNS server runs on port \(newPort), and /etc/resolver names it."))
        #expect(helper.requests.last(where: { if case .setResolver = $0 { true } else { false } }) == .setResolver(tld: "test", port: newPort))
        #expect(await engine.handle(.setPort(service: "dns", port: 53)) == .failure(message: "The DNS server needs a port from 1024 to 65535, because it runs without root."))
        await engine.shutdown()
    }

    @Test func aDNSPortInUseKeepsTheRunningServerAndItsPort() async throws {
        let dnsPort = freeUDPPort()
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), dnsPort: dnsPort)
        await engine.startEnabledServices()
        let other = DNSServer(responder: DNSResponder(tld: "test"))
        let takenPort = freeUDPPort()
        try other.start(port: takenPort)
        defer { other.stop() }

        let response = await engine.handle(.setPort(service: "dns", port: takenPort))
        let status = services(await engine.handle(.status))

        #expect(response == .failure(message: DNSServerError.portInUse(takenPort).description))
        #expect(status["dns"]?.ports == [dnsPort])
        if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        await engine.shutdown()
    }

    @Test func aNewDNSPortStartsAFailedServer() async throws {
        let other = DNSServer(responder: DNSResponder(tld: "test"))
        let takenPort = freeUDPPort()
        try other.start(port: takenPort)
        defer { other.stop() }
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), dnsPort: takenPort)
        await engine.startEnabledServices()
        let freePort = freeUDPPort()

        let response = await engine.handle(.setPort(service: "dns", port: freePort))
        let status = services(await engine.handle(.status))

        #expect(response == .done(message: "The DNS server runs on port \(freePort), and /etc/resolver names it."))
        if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        await engine.shutdown()
    }

    @Test func aRefusedResolverFileDoesNotStopTheEtcHostsLines() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        helper.refuseResolver(for: "test")
        await engine.startEnabledServices()

        _ = await engine.handle(.addHost("shop.local"))

        #expect(helper.requests.last == .setHosts(["shop.local"]))
        await engine.shutdown()
    }

    @Test func aHostOutsideTheTLDGetsAnEtcHostsLine() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let added = await engine.handle(.addHost("Shop.Local"))
        let listed = await engine.handle(.hosts)
        let removed = await engine.handle(.removeHost("shop.local"))

        #expect(added == .done(message: "/etc/hosts sends shop.local to 127.0.0.1 and ::1."))
        #expect(listed == .hosts(["shop.local"]))
        #expect(removed == .done(message: "/etc/hosts has no line for shop.local now."))
        #expect(helper.requests == [.setHosts(["shop.local"]), .setHosts([])])
    }

    @Test func aHostInTheTLDNeedsNoEtcHostsLine() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let response = await engine.handle(.addHost("shop.test"))

        #expect(response == .failure(message: "shop.test needs no line in /etc/hosts. The DNS server of Nexus answers every .test name."))
        #expect(helper.requests.isEmpty)
    }

    @Test func aPublicNameGetsNoEtcHostsLineAndNoCertificate() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let host = await engine.handle(.addHost("github.com"))
        let certificate = await engine.handle(.certificate(hosts: ["github.com"]))

        #expect(host == .failure(message: HostNameError.publicHost("github.com").description))
        #expect(certificate == .failure(message: HostNameError.publicHost("github.com").description))
        #expect(helper.requests.isEmpty)
    }

    @Test func aCertificateNamesItsFilesAndAsksForTrust() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let response = await engine.handle(.certificate(hosts: ["shop.test"]))

        guard case .done(let message) = response else {
            Issue.record("no certificate: \(response)")
            return
        }
        #expect(message.contains(paths.certs.appending(path: "shop.test.crt").path(percentEncoded: false)))
        #expect(message.contains("nexus trust"))
    }

    @Test func uninstallRemovesTheSystemFilesAndTheRootCA() async throws {
        let unregistered = Mutex(false)
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort()) { unregistered.withLock { $0 = true } }
        _ = await engine.handle(.certificate(hosts: ["shop.test"]))
        try FileManager.default.createDirectory(at: systemFiles.resolverFolder, withIntermediateDirectories: true)
        try Data(SystemDNSFiles.resolverContents(port: 10053).utf8).write(to: systemFiles.resolverFolder.appending(path: "test"))

        let response = await engine.handle(.uninstall)
        try await Task.sleep(for: .seconds(1.5))

        guard case .done = response else {
            Issue.record("uninstall failed: \(response)")
            return
        }
        #expect(helper.requests == [.removeResolver(tld: "test"), .setHosts([])])
        #expect(try keyStore.privateKey() == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.certs.path(percentEncoded: false)))
        #expect(unregistered.withLock { $0 })
    }

    @Test func uninstallWithoutTheHelperChangesNothing() async throws {
        let unregistered = Mutex(false)
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort()) { unregistered.withLock { $0 = true } }
        await engine.startEnabledServices()
        _ = await engine.handle(.certificate(hosts: ["shop.test"]))
        try FileManager.default.createDirectory(at: systemFiles.resolverFolder, withIntermediateDirectories: true)
        try Data(SystemDNSFiles.resolverContents(port: 10053).utf8).write(to: systemFiles.resolverFolder.appending(path: "test"))
        helper.setReachable(false)

        let response = await engine.handle(.uninstall)
        try await Task.sleep(for: .seconds(1.5))
        let status = services(await engine.handle(.status))

        guard case .failure(let message) = response else {
            Issue.record("uninstall did not stop: \(response)")
            return
        }
        #expect(message.contains("Nothing else changed"))
        #expect(try keyStore.privateKey() != nil)
        #expect(!unregistered.withLock { $0 })
        #expect(status["dns"]?.state.isActive == true)
        await engine.shutdown()
    }

    @Test func trustAsksOnlyOnce() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let first = await engine.handle(.trust)
        let second = await engine.handle(.trust)

        guard case .done(let message) = first else {
            Issue.record("trust failed: \(first)")
            return
        }
        #expect(message.hasPrefix("Safari and Chrome trust the certificates of Nexus now."))
        #expect(second == .done(message: "The Nexus root CA is trusted already."))
    }

    private func makeFakePHP() throws -> ManifestPackage {
        let source = workspace.appending(path: "php-source/php-8.5.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: source.appending(path: "php"))

        let archive = workspace.appending(path: "php-8.5.0.tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", workspace.appending(path: "php-source").path(percentEncoded: false), "php-8.5.0"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "php", version: "8.5.0", line: "8.5", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    @Test func aSiteThatCannotRunIsNotKept() async throws {
        let engine = try makeEngine(package: try makeFakePHP(), port: freePort())
        _ = await engine.handle(.install(name: "php", line: "8.5"))
        let folder = workspace.appending(path: "Shop Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let response = await engine.handle(.addSite(folder: folder.path(percentEncoded: false), host: nil, aliases: [], php: nil, server: nil))

        guard case .failure = response else {
            Issue.record("the site was added: \(response)")
            return
        }
        #expect(await engine.handle(.sites) == .sites([]))
    }

    @Test func anAddedSiteWinsOverAParkedSiteWithTheSameHost() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let parked = workspace.appending(path: "parked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parked.appending(path: "shop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parked.appending(path: "blog"), withIntermediateDirectories: true)
        var state = EngineState()
        state.parked = [ParkedFolder(folder: parked, php: "8.4")]
        state.sites = [Site(host: "shop.test", folder: parked.appending(path: "shop"), aliases: ["shop.local"], php: "8.5", server: .apache)]
        state.hosts = ["extra.local"]

        let sites = await engine.resolvedSites(state)
        let etcHosts = await engine.etcHosts(state)

        #expect(sites.map(\.site.host) == ["blog.test", "shop.test"])
        #expect(sites.map(\.parked) == [true, false])
        #expect(sites[1].site.php == "8.5")
        #expect(etcHosts == ["extra.local", "shop.local"])
    }

    @Test func aParkedSiteWithTheHostOfAnotherSiteIsLeftOut() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let parked = workspace.appending(path: "parked", directoryHint: .isDirectory)
        for name in ["blog", "my shop", "my-shop"] {
            try FileManager.default.createDirectory(at: parked.appending(path: name), withIntermediateDirectories: true)
        }
        var state = EngineState()
        state.parked = [ParkedFolder(folder: parked, php: "8.4")]
        state.sites = [Site(host: "shop.test", folder: workspace, aliases: ["blog.test"], php: "8.5")]

        let resolved = await engine.resolveSites(state)

        #expect(resolved.sites.map(\.site.host) == ["my-shop.test", "shop.test"])
        #expect(resolved.conflicts.count == 2)
        #expect(resolved.conflicts.contains { $0.contains("blog.test") })
    }

    @Test func aStateFileWithoutTheNewKeysKeepsItsValues() throws {
        let old = #"{"portProfile":"development","ports":{"redis-8.2":16379},"enabledServices":["redis-8.2"],"manifestURL":"file:///tmp/m.json"}"#

        let state = try JSONDecoder().decode(EngineState.self, from: Data(old.utf8))

        #expect(state.portProfile == .development)
        #expect(state.ports == ["redis-8.2": 16379])
        #expect(state.enabledServices == ["redis-8.2"])
        #expect(state.manifestURL == URL(string: "file:///tmp/m.json"))
        #expect(state.tld == "test")
        #expect(state.hosts.isEmpty)
    }
}
