import Darwin
import Foundation
import Testing
@testable import NexusSupervisor

struct ProcessSupervisorTests {
    private let logs = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Supervisor Tests \(UUID().uuidString)", directoryHint: .isDirectory)

    private let fastPolicy = RestartPolicy(
        firstDelay: .milliseconds(50),
        maximumDelay: .milliseconds(200),
        stableAfter: .seconds(60),
        maximumQuickRestarts: 3,
        stopTimeout: .seconds(2)
    )

    private func definition(_ id: String, executable: String, arguments: [String] = [], ports: [Int] = []) -> ServiceDefinition {
        ServiceDefinition(
            id: id,
            displayName: id,
            executable: URL(filePath: executable),
            arguments: arguments,
            ports: ports,
            logFile: logs.appending(path: "\(id).log")
        )
    }

    private func waitFor(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func pid(_ state: ServiceState?) -> Int32? {
        if case .running(let pid, _) = state {
            return pid
        }
        return nil
    }

    @Test func aReloadKeepsTheProcessAndShowsTheNewPorts() async throws {
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("sleeper", executable: "/bin/sleep", arguments: ["30"]))
        let first = try #require(pid(await supervisor.state(of: "sleeper")))

        let reloaded = await supervisor.reload(definition("sleeper", executable: "/bin/sleep", arguments: ["30"], ports: [18091]), signal: 0)

        #expect(reloaded)
        #expect(pid(await supervisor.state(of: "sleeper")) == first)
        #expect(await supervisor.status().first?.ports == [18091])
        await supervisor.stopAll()
    }

    @Test func aServiceThatWaitsForARestartStartsWithTheReloadedDefinition() async throws {
        let slowRestarts = RestartPolicy(firstDelay: .milliseconds(500), maximumDelay: .seconds(1), stableAfter: .seconds(60), maximumQuickRestarts: 3, stopTimeout: .seconds(2))
        let supervisor = ProcessSupervisor(policy: slowRestarts)
        try await supervisor.start(definition("quitter", executable: "/usr/bin/false"))
        let waiting = await waitFor {
            guard case .restarting = await supervisor.state(of: "quitter") else {
                return false
            }
            return true
        }

        let reloaded = await supervisor.reload(definition("quitter", executable: "/bin/sleep", arguments: ["30"], ports: [18092]), signal: SIGHUP)
        let restarted = await waitFor { pid(await supervisor.state(of: "quitter")) != nil }

        #expect(waiting)
        #expect(!reloaded)
        #expect(restarted)
        #expect(await supervisor.status().first?.ports == [18092])
        await supervisor.stopAll()
    }

    @Test func aKilledServiceComesBackWithANewProcess() async throws {
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("sleeper", executable: "/bin/sleep", arguments: ["30"]))
        let first = try #require(pid(await supervisor.state(of: "sleeper")))

        kill(first, SIGKILL)

        let restarted = await waitFor {
            let current = pid(await supervisor.state(of: "sleeper"))
            return current != nil && current != first
        }
        #expect(restarted)
        await supervisor.stopAll()
    }

    @Test func stopEndsTheProcessAndKeepsItStopped() async throws {
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("sleeper", executable: "/bin/sleep", arguments: ["30"]))
        let running = try #require(pid(await supervisor.state(of: "sleeper")))

        try await supervisor.stop("sleeper")
        try await Task.sleep(for: .milliseconds(300))

        #expect(await supervisor.state(of: "sleeper") == .stopped)
        #expect(kill(running, 0) != 0)
    }

    @Test func stopSendsTheStopSignalOfTheService() async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let marker = logs.appending(path: "interrupted")
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        let script = "trap 'touch \"\(marker.path(percentEncoded: false))\"; exit 0' INT; echo ready; while :; do sleep 0.05; done"
        let service = ServiceDefinition(
            id: "database",
            displayName: "database",
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            logFile: logs.appending(path: "database.log"),
            stopSignal: SIGINT
        )
        try await supervisor.start(service)
        _ = await waitFor { (try? String(contentsOf: logs.appending(path: "database.log"), encoding: .utf8))?.contains("ready") == true }

        try await supervisor.stop("database")

        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test func aServiceThatKeepsCrashingIsMarkedAsFailed() async throws {
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("broken", executable: "/usr/bin/false"))

        let failed = await waitFor {
            if case .failed = await supervisor.state(of: "broken") {
                return true
            }
            return false
        }

        #expect(failed)
    }

    @Test func aPortInUseStopsTheStartAndNamesTheOwner() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let supervisor = ProcessSupervisor(policy: fastPolicy)

        do {
            try await supervisor.start(definition("blocked", executable: "/bin/sleep", arguments: ["30"], ports: [port]))
            Issue.record("the start should have failed")
        } catch let SupervisorError.portInUse(failedPort, owner) {
            #expect(failedPort == port)
            #expect(owner?.pid == getpid())
        }
    }

    @Test func theOwnerNamesKnownApplications() {
        let mamp = PortOwner(pid: 1, command: "httpd", executable: "/Applications/MAMP/Library/bin/httpd")
        let herd = PortOwner(pid: 2, command: "nginx", executable: "/Users/me/Library/Application Support/Herd/bin/nginx")
        let app = PortOwner(pid: 3, command: "Spotify", executable: "/Applications/Spotify.app/Contents/MacOS/Spotify")
        let unknown = PortOwner(pid: 4, command: "mystery", executable: nil)

        #expect(mamp.application == "MAMP PRO")
        #expect(herd.application == "Herd")
        #expect(app.application == "Spotify")
        #expect(unknown.application == "mystery")
        #expect(mamp.description == "MAMP PRO (httpd, process 1)")
    }

    @Test func theRestartDelayDoublesUpToTheMaximum() {
        #expect(RestartPolicy.standard.delay(forAttempt: 1) == .seconds(1))
        #expect(RestartPolicy.standard.delay(forAttempt: 3) == .seconds(4))
        #expect(RestartPolicy.standard.delay(forAttempt: 10) == .seconds(60))
    }
}
