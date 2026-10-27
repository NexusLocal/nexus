import Darwin
import Foundation

public enum SupervisorError: Error, Equatable, CustomStringConvertible {
    case portInUse(port: Int, owner: PortOwner?)
    case unknownService(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .portInUse(let port, let owner?):
            "Port \(port) is in use by \(owner.description). Stop that app, or give the service another port."
        case .portInUse(let port, nil):
            "Port \(port) is in use by a process that Nexus cannot see, probably one of another user. Stop it, or give the service another port."
        case .unknownService(let id):
            "Nexus has no service \(id)."
        case .launchFailed(let reason):
            "The service did not start: \(reason)"
        }
    }
}

public struct RestartPolicy: Sendable {
    public var firstDelay: Duration
    public var maximumDelay: Duration
    public var stableAfter: Duration
    public var maximumQuickRestarts: Int
    public var stopTimeout: Duration

    public static let standard = RestartPolicy(
        firstDelay: .seconds(1),
        maximumDelay: .seconds(60),
        stableAfter: .seconds(60),
        maximumQuickRestarts: 5,
        stopTimeout: .seconds(10)
    )

    public init(firstDelay: Duration, maximumDelay: Duration, stableAfter: Duration, maximumQuickRestarts: Int, stopTimeout: Duration) {
        self.firstDelay = firstDelay
        self.maximumDelay = maximumDelay
        self.stableAfter = stableAfter
        self.maximumQuickRestarts = maximumQuickRestarts
        self.stopTimeout = stopTimeout
    }

    func delay(forAttempt attempt: Int) -> Duration {
        let factor = 1 << min(attempt - 1, 16)
        return min(firstDelay * factor, maximumDelay)
    }
}

// Starts each service as a child process, writes its output to its log file, and starts it again
// after an unexpected exit. A service that exits quickly again and again is marked as failed, so
// a broken configuration does not restart forever.
public actor ProcessSupervisor {
    private struct Managed {
        var definition: ServiceDefinition
        var state: ServiceState
        var process: Process?
        var startedAt: Date?
        var quickRestarts = 0
        var stopping = false
    }

    private let policy: RestartPolicy
    private var services: [String: Managed] = [:]

    public init(policy: RestartPolicy = .standard) {
        self.policy = policy
    }

    public func start(_ definition: ServiceDefinition) async throws {
        if let current = services[definition.id], current.state.isActive {
            return
        }

        for port in definition.ports where !(await PortInspector.becomesFree(port)) {
            throw SupervisorError.portInUse(port: port, owner: PortInspector.owner(of: port))
        }

        // Another start of the same service can run during the wait for the ports.
        if let current = services[definition.id], current.state.isActive {
            return
        }

        services[definition.id] = Managed(definition: definition, state: .stopped)
        try launch(definition.id)
    }

    public func stop(_ id: String) async throws {
        guard var managed = services[id] else {
            throw SupervisorError.unknownService(id)
        }

        managed.stopping = true
        services[id] = managed

        guard let process = managed.process, process.isRunning else {
            markStopped(id)
            return
        }

        kill(process.processIdentifier, managed.definition.stopSignal)

        let deadline = ContinuousClock.now + (managed.definition.stopTimeout ?? policy.stopTimeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        markStopped(id)
    }

    // The services stop at the same time, so a database that writes its data to disk does not
    // make the others wait.
    public func stopAll() async {
        await withTaskGroup { group in
            for id in services.keys {
                group.addTask { try? await self.stop(id) }
            }
        }
    }

    public func status() -> [ServiceStatus] {
        services.values
            .map { ServiceStatus(id: $0.definition.id, displayName: $0.definition.displayName, ports: $0.definition.ports, state: $0.state) }
            .sorted { $0.id < $1.id }
    }

    public func state(of id: String) -> ServiceState? {
        services[id]?.state
    }

    // Sends a signal to a running service, for example SIGHUP to make nginx read its
    // configuration again. Returns false when the service does not run.
    @discardableResult
    public func signal(_ id: String, _ signal: Int32) -> Bool {
        guard let process = services[id]?.process, process.isRunning else {
            return false
        }

        return kill(process.processIdentifier, signal) == 0
    }

    private func launch(_ id: String) throws {
        guard var managed = services[id] else {
            throw SupervisorError.unknownService(id)
        }

        let definition = managed.definition
        let log = try LogFile.openForAppending(definition.logFile)

        let process = Process()
        process.executableURL = definition.executable
        process.arguments = definition.arguments
        process.environment = ChildEnvironment.base().merging(definition.environment) { _, service in service }
        process.currentDirectoryURL = definition.workingDirectory
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.handleExit(of: id, pid: finished.processIdentifier, status: status) }
        }

        do {
            try process.run()
        } catch {
            managed.state = .failed(reason: error.localizedDescription)
            services[id] = managed
            throw SupervisorError.launchFailed(error.localizedDescription)
        }

        managed.process = process
        managed.startedAt = .now
        managed.stopping = false
        managed.state = .running(pid: process.processIdentifier, since: .now)
        services[id] = managed
    }

    private func handleExit(of id: String, pid: Int32, status: Int32) async {
        guard var managed = services[id], managed.process?.processIdentifier == pid else {
            return
        }

        managed.process = nil

        if managed.stopping {
            managed.state = .stopped
            services[id] = managed
            return
        }

        let ranFor = managed.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let stableSeconds = Double(policy.stableAfter.components.seconds)
        managed.quickRestarts = ranFor >= stableSeconds ? 1 : managed.quickRestarts + 1

        if managed.quickRestarts > policy.maximumQuickRestarts {
            managed.state = .failed(reason: "The service stopped \(policy.maximumQuickRestarts) times within a short time. The last exit status was \(status). See \(managed.definition.logFile.path(percentEncoded: false)).")
            services[id] = managed
            return
        }

        let attempt = managed.quickRestarts
        managed.state = .restarting(attempt: attempt)
        services[id] = managed

        try? await Task.sleep(for: policy.delay(forAttempt: attempt))

        guard let current = services[id], !current.stopping, case .restarting = current.state else {
            return
        }

        try? launch(id)
    }

    private func markStopped(_ id: String) {
        guard var managed = services[id] else {
            return
        }

        managed.process = nil
        managed.state = .stopped
        services[id] = managed
    }

}

public enum LogFile {
    public static func openForAppending(_ file: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
            fileManager.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        return handle
    }
}

// Every child process starts with this environment, not with the environment of nexusd. So a
// PATH or a setting such as MYSQL_HOME from the shell of the user cannot change a service.
enum ChildEnvironment {
    static func base() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment

        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }
}
