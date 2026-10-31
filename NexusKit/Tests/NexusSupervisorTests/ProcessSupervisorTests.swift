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

    @Test(arguments: [false, true])
    func theWorkersOfAServiceEndWithItsMainProcess(stoppedByTheSupervisor: Bool) async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let childFile = logs.appending(path: "child-\(stoppedByTheSupervisor).pid")
        let script = "/bin/sleep 300 & echo $! > '\(childFile.path(percentEncoded: false))'; trap '' TERM; wait"
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("master", executable: "/bin/sh", arguments: ["-c", script]))
        let main = try #require(pid(await supervisor.state(of: "master")))
        let written = await waitFor { (try? String(contentsOf: childFile, encoding: .utf8)) != nil }
        let child = try #require(Int32((try String(contentsOf: childFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))

        if stoppedByTheSupervisor {
            try await supervisor.stop("master")
        } else {
            kill(main, SIGKILL)
        }
        let childEnded = await waitFor { kill(child, 0) != 0 }

        #expect(written)
        #expect(childEnded)
        await supervisor.stopAll()
    }

    @Test func aStopOfAGroupWaitsForAChildThatEndsItsWork() async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let done = logs.appending(path: "done.txt")
        let ready = logs.appending(path: "ready.txt")
        let child = "trap 'sleep 0.3; touch \"$DONE\"; exit 0' TERM; touch \"$READY\"; while :; do sleep 0.05; done"
        let definition = ServiceDefinition(
            id: "worker",
            displayName: "worker",
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "/bin/sh -c \"$WORKER\" & wait"],
            environment: ["WORKER": child, "DONE": done.path(percentEncoded: false), "READY": ready.path(percentEncoded: false)],
            logFile: logs.appending(path: "worker.log"),
            stopsGroup: true
        )
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition)
        let started = await waitFor { FileManager.default.fileExists(atPath: ready.path(percentEncoded: false)) }

        try await supervisor.stop("worker")

        #expect(started)
        #expect(FileManager.default.fileExists(atPath: done.path(percentEncoded: false)))
        #expect(await supervisor.state(of: "worker") == .stopped)
    }

    @Test func aStopOfAGroupEndsAChildThatIgnoresTheSignal() async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let childFile = logs.appending(path: "child.pid")
        let script = "trap '' TERM; /bin/sleep 300 & echo $! > \"$CHILD\"; wait"
        let definition = ServiceDefinition(
            id: "stubborn",
            displayName: "stubborn",
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["CHILD": childFile.path(percentEncoded: false)],
            logFile: logs.appending(path: "stubborn.log"),
            stopTimeout: .milliseconds(200),
            stopsGroup: true
        )
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition)
        let written = await waitFor { (try? String(contentsOf: childFile, encoding: .utf8))?.hasSuffix("\n") == true }
        let child = try #require(Int32((try String(contentsOf: childFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))

        try await supervisor.stop("stubborn")
        let childEnded = await waitFor { kill(child, 0) != 0 }

        #expect(written)
        #expect(childEnded)
    }

    @Test func aSupervisorStartsNothingAfterAStopForGood() async throws {
        let supervisor = ProcessSupervisor(policy: fastPolicy)
        try await supervisor.start(definition("first", executable: "/bin/sleep", arguments: ["30"]))

        await supervisor.stopForGood()
        try await supervisor.start(definition("second", executable: "/bin/sleep", arguments: ["30"]))

        #expect(await supervisor.state(of: "first") == .stopped)
        #expect(await supervisor.state(of: "second") == nil)
    }

    @Test func twoProgramsWithOneLogDoNotWriteOverEachOther() throws {
        let file = logs.appending(path: "shared.log")
        let first = try LogFile.openForAppending(file)
        let second = try LogFile.openForAppending(file)

        try first.write(contentsOf: Data("one\n".utf8))
        try second.write(contentsOf: Data("two\n".utf8))
        try first.write(contentsOf: Data("three\n".utf8))

        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\nthree\n")
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
