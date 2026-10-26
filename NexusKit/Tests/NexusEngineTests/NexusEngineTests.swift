import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
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

    private var paths: NexusPaths {
        NexusPaths(root: workspace.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
    }

    // A package named redis whose redis-server only sleeps, so the test needs no real Redis.
    private func makeFakeRedis() throws -> ManifestPackage {
        let source = workspace.appending(path: "source/redis-1.0.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let server = source.appending(path: "redis-server")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: server)
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

    private func makeEngine(package: ManifestPackage, port: Int) throws -> NexusEngine {
        try paths.createFolders()
        var state = EngineState()
        state.ports["redis-1.0"] = port
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let manifest = Manifest(schema: 1, generated: .now, repository: "test", packages: [package])
        return NexusEngine(paths: paths, downloader: CopyDownloader(), manifestSource: FixedManifest(manifest: manifest))
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
        #expect(services.map(\.id) == ["redis-1.0"])
        if case .running = services.first?.state {} else { Issue.record("the service does not run: \(services)") }
        #expect(stopped == .done(message: "redis-1.0 stopped."))
    }

    @Test func aStartedServiceStartsAgainWithTheEngine() async throws {
        let package = try makeFakeRedis()
        let port = freePort()
        let first = try makeEngine(package: package, port: port)
        _ = await first.handle(.install(name: "redis", line: "1.0"))
        _ = await first.handle(.start(service: "redis-1.0"))
        await first.shutdown()

        let second = NexusEngine(paths: paths, downloader: CopyDownloader(),
                                 manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [package])))
        await second.startEnabledServices()
        let status = await second.handle(.status)

        guard case .services(let services) = status, case .running = services.first?.state else {
            Issue.record("the service did not start again: \(status)")
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

        let taken = await engine.handle(.setPort(service: "redis-2.0", port: 23456))
        let free = await engine.handle(.setPort(service: "redis-2.0", port: 23457))

        #expect(taken == .failure(message: "Port 23456 belongs to redis-1.0 already."))
        #expect(free == .done(message: "redis-2.0 uses port 23457."))
    }

    @Test func theDevelopmentProfileMovesPortsAwayFromTheStandardOnes() {
        #expect(PortProfile.development.defaultPort(6379) == 16379)
        #expect(PortProfile.development.defaultPort(3306) == 13306)
        #expect(PortProfile.development.defaultPort(443) == 8443)
        #expect(PortProfile.standard.defaultPort(6379) == 6379)
    }
}
