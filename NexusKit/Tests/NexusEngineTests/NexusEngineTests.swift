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
    func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

struct HalfDownloader: PackageDownloader {
    func download(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        progress(DownloadProgress(received: 50, expected: 100))
        try await Task.sleep(for: .seconds(60))
        throw RuntimeError.unsupported("The test did not stop the download.")
    }
}

func shortTemporaryRoot() -> URL {
    URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
}

func fakeListener(port: String) -> String {
    #"/usr/bin/perl -MIO::Socket::INET -e '$| = 1; $SIG{CHLD} = "IGNORE"; my $server = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ARGV[0], Listen => 16, ReuseAddr => 1) or die "bind: $!"; while (my $client = $server->accept) { my $child = fork; die "fork: $!" unless defined $child; if ($child) { close $client; next } close $server; while (sysread($client, my $bytes, 4096)) { print $bytes } exit 0 }' "\#(port)""#
}

func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)

    while ContinuousClock.now < deadline {
        if try await condition() {
            return true
        }

        try? await Task.sleep(for: .milliseconds(25))
    }

    return false
}

// Adds text at the end of a log, as nginx does.
func writeAtEnd(_ text: String, of file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

// One line of the visitor log of a link, in the format nexus_share of nginx.
func visitorLine(_ request: String = "5f2b", visitor: String = "203.0.113.7", time: Date = Date(timeIntervalSince1970: 1_800_000_000.125)) -> String {
    #"{"time":\#(time.timeIntervalSince1970),"request":"\#(request)","status":200,"visitor":"\#(visitor)"}"# + "\n"
}

func exists(_ file: URL) -> Bool {
    FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
}

extension NexusEvent {
    var services: ServiceList? {
        guard case .services(let list) = self else {
            return nil
        }

        return list
    }

    var tasks: TaskList? {
        guard case .tasks(let list) = self else {
            return nil
        }

        return list
    }

    var dumpList: DumpList? {
        guard case .dumpList(let list) = self else {
            return nil
        }

        return list
    }

    var dumpChanges: DumpChange? {
        guard case .dumpChanges(let change) = self else {
            return nil
        }

        return change
    }
}

final class EventRecorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    private let pick: @Sendable (NexusEvent) -> Value?

    init(_ pick: @escaping @Sendable (NexusEvent) -> Value?) {
        self.pick = pick
    }

    func record(_ events: AsyncStream<NexusEvent>) {
        Task {
            for await event in events {
                if let value = pick(event) {
                    values.withLock { $0.append(value) }
                }
            }
        }
    }

    var all: [Value] {
        values.withLock { $0 }
    }

    func next(where condition: (Value) -> Bool = { _ in true }) async -> Value? {
        let deadline = ContinuousClock.now + .seconds(5)

        while ContinuousClock.now < deadline {
            let match = values.withLock { values -> Value? in
                guard let index = values.firstIndex(where: condition) else {
                    return nil
                }

                defer { values.removeFirst(index + 1) }
                return values[index]
            }

            if let match {
                return match
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return nil
    }
}

@Suite(.serialized)
struct NexusEngineTests {
    private let workspace = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Engine Tests \(UUID().uuidString)", directoryHint: .isDirectory)

    let helper = RecordingHelper()
    let keyStore = MemoryKeyStore()

    private var paths: NexusPaths {
        NexusPaths(root: workspace.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
    }

    private var systemFiles: SystemDNSFiles {
        SystemDNSFiles(
            resolverFolder: workspace.appending(path: "etc/resolver", directoryHint: .isDirectory),
            hostsFile: workspace.appending(path: "etc/hosts", directoryHint: .notDirectory)
        )
    }

    private func makeFakeRedis(version: String = "1.0.0") throws -> ManifestPackage {
        let source = workspace.appending(path: "source/redis-\(version)/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let server = source.appending(path: "redis-server")
        try Data("#!/bin/sh\nexec \(fakeListener(port: "$3"))\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path(percentEncoded: false))

        let archive = workspace.appending(path: "redis-\(version).tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", workspace.appending(path: "source").path(percentEncoded: false), "redis-\(version)"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "redis", version: version, line: "1.0", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    func freePort() -> Int {
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

    // Above the ports of Nexus and Nexus Dev, and below the ports that macOS gives to outgoing
    // connections (49152 and higher). So no other program gets the port after a close in a test.
    // PortGateTests.freePort uses 47001 to 48000.
    func freePortAboveNexus() -> Int {
        while true {
            let port = Int.random(in: 48_001...49_000)
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            close(listener)

            if bound == 0 {
                return port
            }
        }
    }

    private func makeEngine(
        package: ManifestPackage,
        port: Int,
        dnsPort: Int? = nil,
        downloader: any PackageDownloader = CopyDownloader(),
        manifestSource: (any ManifestSource)? = nil,
        unregister: @escaping @Sendable () -> Void = {}
    ) throws -> NexusEngine {
        try paths.createFolders()
        var state = EngineState()
        state.ports["redis-1.0"] = port
        state.ports[NexusEngine.dnsServiceID] = dnsPort ?? freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        return makeEngine(package: package, downloader: downloader, manifestSource: manifestSource, unregister: unregister)
    }

    private func makeEngine(
        package: ManifestPackage,
        downloader: any PackageDownloader = CopyDownloader(),
        manifestSource: (any ManifestSource)? = nil,
        unregister: @escaping @Sendable () -> Void = {}
    ) -> NexusEngine {
        let manifest = Manifest(schema: 1, generated: .now, repository: "test", packages: [package])
        return NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: downloader,
            manifestSource: manifestSource ?? FixedManifest(manifest: manifest),
            systemFiles: systemFiles,
            helperRetryDelay: .milliseconds(50),
            workspaceFolderQuiet: .zero,
            unregister: unregister
        )
    }

    // The engine stops also when a step throws or returns early, so no watch or process stays
    // after the test.
    func whileRunning(_ engine: NexusEngine, _ steps: () async throws -> Void) async throws {
        do {
            try await steps()
        } catch {
            await engine.shutdown()
            throw error
        }

        await engine.shutdown()
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
        try await whileRunning(first) {
            _ = await first.handle(.install(name: "redis", line: "1.0"))
            _ = await first.handle(.start(service: "redis-1.0"))
        }

        let second = makeEngine(package: package)
        try await whileRunning(second) {
            await second.startEnabledServices()
            let status = services(await second.handle(.status))

            guard case .running = status["redis-1.0"]?.state, case .running = status["dns"]?.state else {
                Issue.record("the services did not start again: \(status)")
                return
            }
        }
    }

    @Test func removingARunningRuntimeIsRefused() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))

            let response = await engine.handle(.remove(name: "redis", line: "1.0"))

            #expect(response == .failure(message: "Stop redis-1.0 first. It uses redis 1.0."))
        }
    }

    @Test func aRemovedRuntimeWithoutDataLeavesNoDataFolder() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let data = paths.dataFolder(service: "redis", line: "1.0")
        _ = await engine.handle(.install(name: "redis", line: "1.0"))
        _ = await engine.handle(.status)
        try #require(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))

        let response = await engine.handle(.remove(name: "redis", line: "1.0"))

        #expect(response == .done(message: "redis 1.0 is removed."))
        #expect(!FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    @Test func aRemovedRuntimeKeepsItsData() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let data = paths.dataFolder(service: "redis", line: "1.0")
        _ = await engine.handle(.install(name: "redis", line: "1.0"))
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: data.appending(path: "dump.rdb"))

        let response = await engine.handle(.remove(name: "redis", line: "1.0"))

        #expect(response == .done(message: "redis 1.0 is removed. Its data folder stays: \(data.path(percentEncoded: false))"))
        #expect(FileManager.default.fileExists(atPath: data.appending(path: "dump.rdb").path(percentEncoded: false)))
    }

    @Test func aPortThatAnotherServiceHasIsRefused() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: 23456)
        _ = await engine.handle(.install(name: "redis", line: "1.0"))

        let taken = await engine.handle(.setPort(service: "dns", port: 23456))
        let free = await engine.handle(.setPort(service: "redis-1.0", port: 23457))

        #expect(taken == .failure(message: "Port 23456 belongs to redis-1.0 already."))
        #expect(free == .done(message: "redis-1.0 uses port 23457."))
    }

    @Test func bothWebPortsMoveOnlyToFreeDifferentPortsWithNginxInstalled() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: 23456)
        _ = await engine.handle(.install(name: "redis", line: "1.0"))

        let same = await engine.handle(.setWebPorts(http: 8080, https: 8080))
        let taken = await engine.handle(.setWebPorts(http: 23456, https: 23457))
        let noNginx = await engine.handle(.setWebPorts(http: 23458, https: 23459))

        #expect(same == .failure(message: "HTTP and HTTPS need two different ports."))
        #expect(taken == .failure(message: "Port 23456 belongs to redis-1.0 already."))
        #expect(noNginx == .failure(message: "nginx is not installed. Run: nexus install nginx 1.30"))
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

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let status = services(await engine.handle(.status))

            #expect(helper.requests == [.setResolver(tld: "test", port: dnsPort), .setHosts([])])
            #expect(status["dns"]?.ports == [dnsPort])
            if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        }
    }

    @Test func dnsWithoutTheHelperIsFailedUntilTheHelperAnswers() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
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
        }
    }

    @Test func aNewDNSPortMovesTheServerAndTheResolverFile() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let newPort = freeUDPPort()

            let response = await engine.handle(.setPort(service: "dns", port: newPort))

            #expect(response == .done(message: "The DNS server runs on port \(newPort), and /etc/resolver names it."))
            #expect(helper.requests.last(where: { if case .setResolver = $0 { true } else { false } }) == .setResolver(tld: "test", port: newPort))
            #expect(await engine.handle(.setPort(service: "dns", port: 53)) == .failure(message: "The DNS server needs a port from 1024 to 65535, because it runs without root."))
        }
    }

    @Test func aDNSPortInUseKeepsTheRunningServerAndItsPort() async throws {
        let dnsPort = freeUDPPort()
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), dnsPort: dnsPort)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let other = DNSServer(responder: DNSResponder(tld: "test"))
            let takenPort = try startOnFreePort(other)
            defer { other.stop() }

            let response = await engine.handle(.setPort(service: "dns", port: takenPort))
            let status = services(await engine.handle(.status))

            #expect(response == .failure(message: DNSServerError.portInUse(takenPort).description))
            #expect(status["dns"]?.ports == [dnsPort])
            if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        }
    }

    @Test func aNewDNSPortStartsAFailedServer() async throws {
        let other = DNSServer(responder: DNSResponder(tld: "test"))
        let takenPort = try startOnFreePort(other)
        defer { other.stop() }
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), dnsPort: takenPort)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let freePort = freeUDPPort()

            let response = await engine.handle(.setPort(service: "dns", port: freePort))
            let status = services(await engine.handle(.status))

            #expect(response == .done(message: "The DNS server runs on port \(freePort), and /etc/resolver names it."))
            if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
        }
    }

    @Test func aRefusedResolverFileDoesNotStopTheEtcHostsLines() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            helper.refuseResolver(for: "test")
            await engine.startEnabledServices()

            _ = await engine.handle(.addHost("shop.local"))

            #expect(helper.requests.last == .setHosts(["shop.local"]))
        }
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

        try await whileRunning(engine) {
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
        }
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

    @Test func withTheLocalDomainEachSiteNameGetsALineInTheHostsFile() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let folder = workspace.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = EngineState()
        state.tld = "local"
        state.sites = [Site(host: "shop.local", folder: folder, aliases: ["www.shop.local", "*.shop.local"], php: "8.5", server: .nginx)]
        state.hosts = ["extra.local"]

        let etcHosts = await engine.etcHosts(state)

        #expect(etcHosts == ["extra.local", "shop.local", "www.shop.local"])
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

    @Test func aStateFileWithTheOldManifestAddressGetsTheManifestOfTheLatestRelease() throws {
        let old = #"{"manifestURL":"https://github.com/NexusLocal/binaries/releases/download/manifest/manifest.json"}"#

        let state = try JSONDecoder().decode(EngineState.self, from: Data(old.utf8))

        #expect(state.manifestURL == URL(string: "https://github.com/NexusLocal/binaries/releases/latest/download/manifest.json"))
    }

    @Test func aStateFileWithoutTheDumpSettingsGetsTheirDefaults() throws {
        let old = #"{"tld":"test","mailSettings":{"outboxMails":20}}"#

        let state = try JSONDecoder().decode(EngineState.self, from: Data(old.utf8))

        #expect(state.dumpSettings == DumpSettings())
        #expect(state.mailSettings.outboxMails == 20)
    }

    @Test func theDumpSettingsSurviveASaveOfTheState() throws {
        var state = EngineState()
        state.dumpSettings = DumpSettings(catchDumps: false, catchLogs: true, pageMode: .always, commands: false)

        let saved = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(state))

        #expect(saved.dumpSettings == state.dumpSettings)
    }

    @Test func aStateFileOfAnOlderNexusdGetsAllCatchSwitchesOffOneTime() throws {
        let old = #"{"dumpSettings":{"catchDumps":true,"catchQueries":true,"catchLogs":true,"catchJobs":true,"pageMode":"always","commands":false}}"#

        let state = try JSONDecoder().decode(EngineState.self, from: Data(old.utf8))
        let saved = try JSONEncoder().encode(state)

        #expect(state.dumpSettings == DumpSettings(pageMode: .always, commands: false))
        #expect(String(decoding: saved, as: UTF8.self).contains(#""dumpSwitchesTurnedOff":true"#))
    }

    @Test func aSwitchThatTheUserTurnsOnAfterTheOneTimeChangeStaysOn() throws {
        var state = try JSONDecoder().decode(EngineState.self, from: Data(#"{"dumpSettings":{"catchDumps":true}}"#.utf8))
        state.dumpSettings.catchDumps = true

        let saved = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(state))

        #expect(saved.dumpSettings.catchDumps)
    }

    @Test func aStateFileWithoutTheLinksOrWithLinksOfANewerNexusdGetsTheDefaultsAndKeepsTheRest() throws {
        let old = try JSONDecoder().decode(EngineState.self, from: Data(#"{"tld":"test"}"#.utf8))
        let newer = try JSONDecoder().decode(EngineState.self, from: Data(#"{"hosts":["shop.test"],"shares":[{"id":"abc","state":{"paused":{}}}],"shareDefaults":[],"ownDomain":{"domain":"example.com"}}"#.utf8))

        #expect(old.shares.isEmpty)
        #expect(old.shareDefaults == .standard)
        #expect(old.ownDomain == nil)
        #expect(newer.shares.isEmpty)
        #expect(newer.shareDefaults == .standard)
        #expect(newer.ownDomain == nil)
        #expect(newer.hosts == ["shop.test"])
    }

    @Test func theLinksTheDefaultsAndTheDomainSurviveASaveOfTheState() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var state = EngineState()
        state.shares = [
            ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: .standard, mode: .publicHost, publicHost: "calm-river-tree-lamp.trycloudflare.com", port: 18_000, metricsPort: 18_001, started: started, endsAt: started.addingTimeInterval(28_800), state: .open, usesVite: true),
            ShareRecord(id: "fedcba9876543210fedcba9876543210", host: "fix.shop.test", site: "shop.test", workspace: "fix", options: .standard, mode: .localHost, started: started, state: .ended(.failed("cloudflared stopped."))),
        ]
        state.shareDefaults = ShareOptions(duration: .untilStopped, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .ownDomain)
        state.ownDomain = OwnDomainRecord(domain: "example.com", tunnelID: "6ff42ae2-765d-4adf-8112-31c55c1551ef", tunnelName: "nexus-macbook-pro", labels: ["shop.test": "shop"], dnsRecords: ["shop.example.com"], metricsPort: 18_010)

        let saved = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(state))

        #expect(saved == state)
    }
}

// The events for the app, restart, and "Stop all services" with "Start stopped services" (D63).
extension NexusEngineTests {
    private func recordEvents(of engine: NexusEngine) async -> EventRecorder<ServiceList> {
        let recorder = EventRecorder { $0.services }
        recorder.record(await engine.events())
        return recorder
    }

    private func state(of id: String, in list: ServiceList?) -> ServiceState? {
        list?.services.first { $0.id == id }?.state
    }

    @Test func theEventsStartWithTheServicesAndFollowEachChange() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            let events = await recordEvents(of: engine)

            let first = await events.next { _ in true }
            _ = await engine.handle(.start(service: "redis-1.0"))
            let started = await events.next { self.state(of: "redis-1.0", in: $0)?.pid != nil }

            let redis = first?.services.last
            #expect(first?.services.map(\.id) == ["dns", "redis-1.0"])
            #expect(redis?.name == "redis")
            #expect(redis?.line == "1.0")
            #expect(redis?.version == "1.0.0")
            #expect(redis?.state == .stopped)
            #expect(started != nil)
        }
    }

    @Test func anExitThatNobodyAskedForReachesTheWatchers() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            let events = await recordEvents(of: engine)
            let running = await events.next { self.state(of: "redis-1.0", in: $0)?.pid != nil }
            let processNumber = state(of: "redis-1.0", in: running)?.pid

            if let processNumber {
                kill(processNumber, SIGKILL)
            }
            let after = await events.next { self.state(of: "redis-1.0", in: $0)?.pid != processNumber }

            #expect(processNumber != nil)
            #expect(after != nil)
        }
    }

    @Test func aRestartGivesTheServiceANewProcess() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            let before = services(await engine.handle(.status))["redis-1.0"]?.state.pid

            let restarted = await engine.handle(.restart(service: "redis-1.0"))
            let after = services(await engine.handle(.status))["redis-1.0"]?.state.pid

            if case .done(let message) = restarted {
                #expect(message.hasPrefix("Nexus restarted redis-1.0. "))
            } else {
                Issue.record("the restart failed: \(restarted)")
            }
            #expect(before != nil)
            #expect(after != nil)
            #expect(after != before)
        }
    }

    @Test func startStoppedStartsOnlyTheServicesThatStopAllStopped() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "dns"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            let events = await recordEvents(of: engine)

            let stopped = await engine.handle(.stopAll)
            let remembered = await events.next { $0.stoppedByStopAll == ["dns", "redis-1.0"] }
            _ = await engine.handle(.start(service: "redis-1.0"))
            _ = await engine.handle(.stop(service: "redis-1.0"))
            let started = await engine.handle(.startStopped)
            let status = services(await engine.handle(.status))
            let afterwards = await events.next { $0.stoppedByStopAll.isEmpty }

            #expect(stopped == .done(message: "Nexus stopped 2 services. Start the stopped services again with: nexus start --stopped"))
            #expect(remembered != nil)
            #expect(started == .done(message: "Nexus started 1 service."))
            if case .running = status["dns"]?.state {} else { Issue.record("DNS does not run: \(status)") }
            #expect(status["redis-1.0"]?.state == .stopped)
            #expect(afterwards != nil)
        }
    }

    @Test func aServiceThatStopAllStoppedWaitsForStartStoppedAfterANewStartOfNexusd() async throws {
        let first = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(first) {
            _ = await first.handle(.install(name: "redis", line: "1.0"))
            _ = await first.handle(.start(service: "redis-1.0"))
            _ = await first.handle(.stopAll)
        }

        let engine = makeEngine(package: try makeFakeRedis())

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let afterLaunch = services(await engine.handle(.status))["redis-1.0"]?.state
            let started = await engine.handle(.startStopped)
            let afterStart = services(await engine.handle(.status))["redis-1.0"]?.state.pid
            let state = await engine.stateStore.current()

            #expect(afterLaunch == .stopped)
            #expect(started == .done(message: "Nexus started 1 service."))
            #expect(afterStart != nil)
            #expect(state.enabledServices.contains("redis-1.0"))
            #expect(state.stoppedByStopAll.isEmpty)
        }
    }

    @Test func stopAllStopsADNSServerThatMacOSDoesNotUseYet() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            helper.setReachable(false)
            await engine.startEnabledServices()

            let stopped = await engine.handle(.stopAll)
            let state = services(await engine.handle(.status))["dns"]?.state

            #expect(stopped == .done(message: "Nexus stopped 1 service. Start the stopped services again with: nexus start --stopped"))
            #expect(state == .stopped)
        }
    }

    @Test func theAppSeesADNSServerThatMacOSDoesNotUseYetAsRunningWithAProblem() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            helper.setReachable(false)
            await engine.startEnabledServices()
            let events = await recordEvents(of: engine)

            let list = await events.next { _ in true }
            let dns = list?.services.first { $0.id == "dns" }

            #expect(dns?.state.pid != nil)
            #expect(dns?.problem?.contains("Login Items & Extensions") == true)
        }
    }

    @Test func aRestartKeepsTheChoiceOfTheUserAboutTheNextStartOfNexusd() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            try await engine.stateStore.update { $0.enabledServices.remove("redis-1.0") }

            let restarted = await engine.handle(.restart(service: "redis-1.0"))
            let state = await engine.stateStore.current()

            if case .done = restarted {} else { Issue.record("the restart failed: \(restarted)") }
            #expect(!state.enabledServices.contains("redis-1.0"))
        }
    }

    @Test func aStartOnAPortInUseNamesTheProgramAndAFreePortUntilThePortChanges() async throws {
        let port = freePort()
        let engine = try makeEngine(package: try makeFakeRedis(), port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            let listener = try listen(on: port)
            defer { close(listener) }
            let events = await recordEvents(of: engine)

            let response = await engine.handle(.start(service: "redis-1.0"))
            let shown = await events.next { $0.services.contains { $0.portConflict != nil } }
            _ = await engine.handle(.setPort(service: "redis-1.0", port: freePort()))
            let cleared = await events.next { $0.services.allSatisfy { $0.portConflict == nil } }

            guard case .portInUse(let conflict) = response else {
                Issue.record("no port conflict: \(response)")
                return
            }
            #expect(conflict.service == "redis-1.0")
            #expect(conflict.port == port)
            #expect(conflict.owner?.pid == getpid())
            #expect(conflict.suggestedPort > port)
            #expect(shown?.services.first { $0.id == "redis-1.0" }?.portConflict == conflict)
            #expect(cleared != nil)
        }
    }

    func listen(on port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        try #require(Darwin.listen(descriptor, 1) == 0)
        return descriptor
    }

    @Test func aStoppedServiceShowsItsNewPortAndNotThePortOfItsLastRun() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            _ = await engine.handle(.stop(service: "redis-1.0"))
            let newPort = freePort()

            _ = await engine.handle(.setPort(service: "redis-1.0", port: newPort))
            let status = services(await engine.handle(.status))["redis-1.0"]

            #expect(status?.ports == [newPort])
            #expect(status?.state == .stopped)
        }
    }

    @Test func startStoppedWithoutAStopAllStartsNothing() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        _ = await engine.handle(.install(name: "redis", line: "1.0"))

        let response = await engine.handle(.startStopped)

        #expect(response == .done(message: "No service to start. This starts only the services that \"Stop all services\" stopped."))
        #expect(services(await engine.handle(.status))["redis-1.0"]?.state == .stopped)
    }
}

extension NexusEngineTests {
    @Test func aDownloadShowsItsProgressAndStopsWithoutAnInstall() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), downloader: HalfDownloader())

        try await whileRunning(engine) {
            let tasks = EventRecorder { $0.tasks }
            tasks.record(await engine.events())
            let install = Task { await engine.handle(.install(name: "redis", line: "1.0")) }

            let running = await tasks.next { $0.tasks.first?.completed == 50 }
            let task = try #require(running?.tasks.first)
            let stop = await engine.handle(.stopTask(id: task.id))
            let answer = await install.value
            let ended = await tasks.next { $0.tasks.isEmpty }

            #expect(task.work == .install(name: "redis", line: "1.0", version: "1.0.0", update: false))
            #expect(task.total == 100)
            #expect(stop == .done(message: "The task stops."))
            #expect(answer == .stopped(message: "The download of redis 1.0 stopped. Nexus installed nothing."))
            #expect(ended != nil)
            #expect(await engine.handle(.installed) == .installed([]))
            #expect((try? FileManager.default.contentsOfDirectory(atPath: paths.runtimeStaging.path(percentEncoded: false)))?.isEmpty ?? true)
        }
    }

    @Test func aStopAfterTheEndOfATaskIsNoError() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())

        let response = await engine.handle(.stopTask(id: "ended"))

        #expect(response == .done(message: "The task ended already."))
    }

    @Test func anUpdateOfARunningServiceStartsItAgainWithTheNewVersion() async throws {
        let first = try makeFakeRedis(version: "1.0.0")
        let manifest = ChangingManifest(first)
        let engine = try makeEngine(package: first, port: freePort(), manifestSource: manifest)

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.start(service: "redis-1.0"))
            let before = services(await engine.handle(.status))["redis-1.0"]?.state.pid
            manifest.change(to: try makeFakeRedis(version: "1.0.1"))

            let update = await engine.handle(.install(name: "redis", line: "1.0"))
            let after = services(await engine.handle(.status))["redis-1.0"]?.state.pid

            #expect(update == .done(message: "redis 1.0 is updated from 1.0.0 to 1.0.1 in \(paths.runtime("redis", line: "1.0").path(percentEncoded: false))"))
            #expect(before != nil)
            #expect(after != nil)
            #expect(after != before)
            guard case .installed(let runtimes) = await engine.handle(.installed) else {
                Issue.record("no runtimes")
                return
            }
            #expect(runtimes.map(\.version) == ["1.0.1"])
        }
    }

    @Test func aSecondInstallOfAPackageThatDownloadsIsRefused() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), downloader: HalfDownloader())

        try await whileRunning(engine) {
            let tasks = EventRecorder { $0.tasks }
            tasks.record(await engine.events())
            let first = Task { await engine.handle(.install(name: "redis", line: "1.0")) }
            let running = try #require(await tasks.next { !$0.tasks.isEmpty }?.tasks.first)

            let second = await engine.handle(.install(name: "redis", line: "1.0"))
            _ = await engine.handle(.stopTask(id: running.id))
            _ = await first.value

            #expect(second == .failure(message: "Nexus installs redis 1.0 already. Wait until it ends, or stop it."))
        }
    }

    @Test func anUpdateIsRefusedWhileADatabaseCopyIntoTheServiceRuns() async throws {
        let first = try makeFakeRedis(version: "1.0.0")
        let manifest = ChangingManifest(first)
        let engine = try makeEngine(package: first, port: freePort(), manifestSource: manifest)

        try await whileRunning(engine) {
            _ = await engine.handle(.install(name: "redis", line: "1.0"))
            await engine.startCopy(into: "redis-1.0 shop")
            manifest.change(to: try makeFakeRedis(version: "1.0.1"))

            let update = await engine.handle(.install(name: "redis", line: "1.0"))

            #expect(update == .failure(message: "Nexus did not update redis 1.0, because a database copy into redis-1.0 runs. Update it after the copy, or stop the copy first."))
        }
    }
}

extension NexusEngineTests {
    private func makeApp(build: String) throws -> URL {
        let app = workspace.appending(path: "Nexus.app", directoryHint: .isDirectory)
        let daemon = app.appending(path: "Contents/MacOS/nexusd")
        try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": build], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try Data().write(to: daemon)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: daemon.path(percentEncoded: false))
        return app
    }

    // A Debug build adds the time of the nexusd file of makeApp to the build.
    private func identity(_ build: String) -> String {
        #if DEBUG
        "\(build)+1800000000"
        #else
        build
        #endif
    }

    @Test func nexusdStopsWhenTheAppOnDiskGetsANewBuild() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let app = try makeApp(build: "5")
        let restarts = Mutex<[String]>([])

        try await whileRunning(engine) {
            await engine.restartAfterUpdates(of: app, every: .milliseconds(20), runningBuild: identity("5")) { build in
                restarts.withLock { $0.append(build) }
            }
            try await Task.sleep(for: .milliseconds(150))
            let beforeTheUpdate = restarts.withLock { $0 }

            _ = try makeApp(build: "6")
            let afterTheUpdate = await waitFor { restarts.withLock { $0 } == [identity("6")] }
            let request = await engine.handle(.status)

            #expect(beforeTheUpdate.isEmpty)
            #expect(afterTheUpdate)
            #expect(request == .failure(message: "nexusd starts again for an update of Nexus. Try again in a few seconds."))
        }
    }

    @Test func nexusdWaitsForARunningTaskBeforeItStopsForAnUpdate() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort(), downloader: HalfDownloader())
        let app = try makeApp(build: "5")
        let restarts = Mutex<[String]>([])

        try await whileRunning(engine) {
            let tasks = EventRecorder { $0.tasks }
            let services = EventRecorder { $0.services }
            tasks.record(await engine.events())
            services.record(await engine.events())
            let install = Task { await engine.handle(.install(name: "redis", line: "1.0")) }
            let running = try #require(await tasks.next { !$0.tasks.isEmpty }?.tasks.first)

            await engine.restartAfterUpdates(of: app, every: .milliseconds(20), runningBuild: identity("4")) { build in
                restarts.withLock { $0.append(build) }
            }
            let waiting = await services.next { $0.updateBuild == identity("5") }
            try await Task.sleep(for: .milliseconds(150))
            let whileTheTaskRuns = restarts.withLock { $0 }

            _ = await engine.handle(.stopTask(id: running.id))
            _ = await install.value
            let afterTheTask = await waitFor { restarts.withLock { $0 } == [identity("5")] }

            #expect(waiting != nil)
            #expect(whileTheTaskRuns.isEmpty)
            #expect(afterTheTask)
        }
    }

    @Test func nexusdDoesNotWaitForWorkThatGoesOnAfterItsStop() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let app = try makeApp(build: "5")
        let restarts = Mutex<[String]>([])

        try await whileRunning(engine) {
            await engine.startWorkThatGoesOnAfterAStop()

            await engine.restartAfterUpdates(of: app, every: .milliseconds(20), runningBuild: identity("4")) { build in
                restarts.withLock { $0.append(build) }
            }

            #expect(await waitFor { restarts.withLock { $0 } == [identity("5")] })
        }
    }

    @Test func nexusdWaitsForTheCommandsOfAWorkspaceSetup() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let app = try makeApp(build: "5")
        let restarts = Mutex<[String]>([])

        try await whileRunning(engine) {
            await engine.startWorkThatGoesOnAfterAStop()
            await engine.setRunsWorkspaceCommands(true)

            await engine.restartAfterUpdates(of: app, every: .milliseconds(20), runningBuild: identity("4")) { build in
                restarts.withLock { $0.append(build) }
            }
            try await Task.sleep(for: .milliseconds(150))
            let whileTheCommandsRun = restarts.withLock { $0 }

            await engine.setRunsWorkspaceCommands(false)
            let afterTheCommands = await waitFor { restarts.withLock { $0 } == [identity("5")] }

            #expect(whileTheCommandsRun.isEmpty)
            #expect(afterTheCommands)
        }
    }

    @Test func aNewConnectionOfTheAppChecksTheBuildAtOnce() async throws {
        let engine = try makeEngine(package: try makeFakeRedis(), port: freePort())
        let app = try makeApp(build: "6")
        let restarts = Mutex<[String]>([])

        try await whileRunning(engine) {
            await engine.restartAfterUpdates(of: app, every: .seconds(60), runningBuild: identity("5")) { build in
                restarts.withLock { $0.append(build) }
            }
            _ = await engine.events()

            #expect(await waitFor { restarts.withLock { $0 } == [identity("6")] })
        }
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)

        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(20))
        }

        return false
    }
}

private extension NexusEngine {
    func startCopy(into target: String) {
        copyTargets.insert(target)
    }

    func startWorkThatGoesOnAfterAStop() {
        settingUpWorkspaces = true
        runningCommand = ("/worktree", Task { throw CancellationError() })
        cloningServers.insert("/clone")
    }

    func setRunsWorkspaceCommands(_ runs: Bool) {
        runsWorkspaceCommands = runs
    }
}

private final class ChangingManifest: ManifestSource {
    private let current: Mutex<Manifest>

    init(_ package: ManifestPackage) {
        current = Mutex(Manifest(schema: 1, generated: .now, repository: "test", packages: [package]))
    }

    func change(to package: ManifestPackage) {
        current.withLock { $0 = Manifest(schema: 1, generated: .now, repository: "test", packages: [package]) }
    }

    func manifest(from url: URL) async throws -> Manifest {
        current.withLock { $0 }
    }
}
