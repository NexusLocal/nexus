import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

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
// tests call it directly.
public actor NexusEngine {
    private let paths: NexusPaths
    private let supervisor: ProcessSupervisor
    private let installer: RuntimeInstaller
    private let catalog: ServiceCatalog
    private let stateStore: EngineStateStore
    private let manifestSource: any ManifestSource

    public init(
        paths: NexusPaths,
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        downloader: any PackageDownloader = URLSessionDownloader(),
        manifestSource: any ManifestSource = HTTPManifestSource()
    ) {
        self.paths = paths
        self.supervisor = supervisor
        self.installer = RuntimeInstaller(paths: paths, downloader: downloader)
        self.catalog = ServiceCatalog(paths: paths)
        self.stateStore = EngineStateStore(paths: paths)
        self.manifestSource = manifestSource
    }

    public func handle(_ request: NexusRequest) async -> NexusResponse {
        do {
            switch request {
            case .status:
                return .services(try await serviceStatus())
            case .start(let id):
                return .done(message: try await start(id))
            case .stop(let id):
                try await supervisor.stop(id)
                try await stateStore.update { $0.enabledServices.remove(id) }
                return .done(message: "\(id) stopped.")
            case .setPort(let id, let port):
                return .done(message: try await setPort(id, port))
            case .available:
                return .available(try await manifest().packages)
            case .installed:
                return .installed(await installer.installedRuntimes())
            case .install(let name, let line):
                return .done(message: try await install(name: name, line: line))
            case .remove(let name, let line):
                return .done(message: try await remove(name: name, line: line))
            }
        } catch {
            return .failure(message: String(describing: error))
        }
    }

    // Starts every service that ran when nexusd stopped the last time.
    public func startEnabledServices() async {
        for id in await stateStore.current().enabledServices.sorted() {
            _ = try? await start(id)
        }
    }

    public func shutdown() async {
        await supervisor.stopAll()
    }

    private func serviceStatus() async throws -> [ServiceStatus] {
        let supervised = Dictionary(uniqueKeysWithValues: await supervisor.status().map { ($0.id, $0) })
        var all: [ServiceStatus] = []

        for runtime in await installer.installedRuntimes() {
            guard let id = catalog.serviceID(for: runtime), let standard = catalog.standardPort(for: runtime) else {
                continue
            }

            if let status = supervised[id] {
                all.append(status)
                continue
            }

            let port = try await stateStore.port(for: id, standard: standard)
            let name = catalog.definition(for: runtime, port: port)?.displayName ?? id
            all.append(ServiceStatus(id: id, displayName: name, ports: [port], state: .stopped))
        }

        return all.sorted { $0.id < $1.id }
    }

    private func start(_ id: String) async throws -> String {
        guard let runtime = await installer.installedRuntimes().first(where: { catalog.serviceID(for: $0) == id }),
              let standard = catalog.standardPort(for: runtime) else {
            throw SupervisorError.unknownService(id)
        }

        let port = try await stateStore.port(for: id, standard: standard)
        guard let definition = catalog.definition(for: runtime, port: port) else {
            throw SupervisorError.unknownService(id)
        }

        try await supervisor.start(definition)
        try await stateStore.update { $0.enabledServices.insert(id) }
        return "\(definition.displayName) runs on port \(port)."
    }

    private func setPort(_ id: String, _ port: Int) async throws -> String {
        guard (1...65535).contains(port) else {
            throw RuntimeError.unsupported("\(port) is not a valid port.")
        }

        let state = await stateStore.current()
        if let other = state.ports.first(where: { $0.key != id && $0.value == port })?.key {
            throw RuntimeError.unsupported("Port \(port) belongs to \(other) already.")
        }

        try await stateStore.update { $0.ports[id] = port }

        if await supervisor.state(of: id)?.isActive == true {
            return "\(id) gets port \(port) at its next start. Run: nexus stop \(id) && nexus start \(id)"
        }

        return "\(id) uses port \(port)."
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
