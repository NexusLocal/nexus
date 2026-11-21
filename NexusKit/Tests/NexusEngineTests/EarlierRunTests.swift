import Darwin
import Foundation
import NexusSupervisor
import NexusTestSupport
import Testing
@testable import NexusEngine

struct EarlierRunTests {
    @Test func onlyAServiceProgramOfThisDataFolderWithoutItsNexusdStops() {
        let mysql = "/Users/a/Library/Application Support/Nexus/runtimes/mysql/8.4/bin/mysqld"
        let nginx = "/Users/a/Library/Application Support/Nexus/runtimes/nginx/1.30/bin/nginx"
        let programs = [
            NexusEngine.RunningProgram(pid: 501, parent: 1, path: mysql),
            NexusEngine.RunningProgram(pid: 502, parent: 1, path: nginx),
            NexusEngine.RunningProgram(pid: 503, parent: 502, path: nginx),
            NexusEngine.RunningProgram(pid: 504, parent: 900, path: mysql),
            NexusEngine.RunningProgram(pid: 505, parent: 1, path: "/Applications/MAMP/Library/bin/mysql80/bin/mysqld"),
        ]

        let leftovers = NexusEngine.leftovers(in: programs, services: [mysql: "mysql-8.4", nginx: "nginx"])

        #expect(leftovers.map(\.pid) == [501, 502])
        #expect(leftovers.map(\.id) == ["mysql-8.4", "nginx"])
        #expect(leftovers.map(\.path) == [mysql, nginx])
    }

    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func aStopSendsNoSignalToANumberWithAnotherProgram() async throws {
        let other = try sleeper()
        defer { other.terminate() }

        await NexusEngine.stop(pid: other.processIdentifier, path: "/Users/a/Library/Application Support/Nexus/runtimes/mysql/8.4/bin/mysqld", signal: SIGTERM, timeout: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(100))

        #expect(other.isRunning)
    }

    @Test func aStopEndsTheProgramOfItsPath() async throws {
        let leftover = try sleeper()
        defer { leftover.terminate() }
        let path = try #require(PortInspector.executablePath(of: leftover.processIdentifier))

        await NexusEngine.stop(pid: leftover.processIdentifier, path: path, signal: SIGTERM, timeout: .seconds(5))
        leftover.waitForEnd()

        #expect(leftover.terminationReason == .uncaughtSignal)
        #expect(leftover.terminationStatus == SIGTERM)
    }

    @Test func theListOfProgramsHoldsThisTestProcess() {
        let own = NexusEngine.runningPrograms().first { $0.pid == getpid() }

        #expect(own != nil)
        #expect(own?.parent == getppid())
    }
}
