import Foundation
import NexusCore

public enum PortProfile: String, Codable, Sendable {
    case standard
    case development

    // While MAMP PRO still runs on the standard ports, the development profile keeps Nexus on
    // ports next to them.
    func defaultPort(_ standard: Int) -> Int {
        switch self {
        case .standard: standard
        case .development: standard < 1024 ? standard + 8000 : standard + 10000
        }
    }
}

public struct EngineState: Codable, Sendable, Equatable {
    public var portProfile: PortProfile = .standard
    public var ports: [String: Int] = [:]
    public var enabledServices: Set<String> = []
    public var manifestURL: URL = URL(string: "https://github.com/NexusLocal/binaries/releases/download/manifest/manifest.json")!

    public init() {}
}

// Keeps the state of nexusd in config/state.json: the port of each service and the services that
// start again when nexusd starts.
public actor EngineStateStore {
    private let file: URL
    private(set) var state: EngineState

    public init(paths: NexusPaths) {
        file = paths.config.appending(path: "state.json")
        state = Self.load(from: file) ?? EngineState()
    }

    public func current() -> EngineState {
        state
    }

    public func update(_ change: (inout EngineState) -> Void) throws {
        change(&state)
        try save()
    }

    // A service keeps its port once it has one. A new service gets the default port of the
    // profile, or the next port that no other Nexus service uses.
    public func port(for service: String, standard: Int) throws -> Int {
        if let port = state.ports[service] {
            return port
        }

        let taken = Set(state.ports.values)
        var port = state.portProfile.defaultPort(standard)
        while taken.contains(port) {
            port += 1
        }

        try update { $0.ports[service] = port }
        return port
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }

    private static func load(from file: URL) -> EngineState? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }

        return try? JSONDecoder().decode(EngineState.self, from: data)
    }
}
