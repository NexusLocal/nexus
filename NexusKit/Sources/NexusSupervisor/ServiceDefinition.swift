import Darwin
import Foundation

public struct ServiceDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let ports: [Int]
    public let logFile: URL
    // PostgreSQL waits for every client to disconnect after SIGTERM. SIGINT stops it at once.
    public let stopSignal: Int32
    // A database can need longer than a web server to start after a crash or an upgrade, and
    // to write its data to disk at a stop. A stop timeout of nil uses the restart policy.
    public let startTimeout: Duration
    public let stopTimeout: Duration?
    // The program of a shell command can be a child of that shell, for example a queue worker that
    // must end its job. The stop signal then goes to the whole group, and each program in that
    // group gets the stop timeout.
    public let stopsGroup: Bool

    public init(
        id: String,
        displayName: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        ports: [Int] = [],
        logFile: URL,
        stopSignal: Int32 = SIGTERM,
        startTimeout: Duration = .seconds(3),
        stopTimeout: Duration? = nil,
        stopsGroup: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.logFile = logFile
        self.stopSignal = stopSignal
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
        self.stopsGroup = stopsGroup
    }
}

public enum ServiceState: Codable, Sendable, Equatable {
    case stopped
    case running(pid: Int32, since: Date)
    case restarting(attempt: Int)
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .running, .restarting: true
        case .stopped, .failed: false
        }
    }
}

public struct ServiceStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let ports: [Int]
    public let state: ServiceState

    public init(id: String, displayName: String, ports: [Int], state: ServiceState) {
        self.id = id
        self.displayName = displayName
        self.ports = ports
        self.state = state
    }
}
