import Darwin
import Foundation
import Synchronization
import Testing
@testable import NexusSupervisor

struct CommandRunnerTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Command Tests \(UUID().uuidString)", directoryHint: .isDirectory)

    private func shell(_ script: String) -> Command {
        Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script])
    }

    @Test func theOutputAndTheErrorOutputStaySeparate() async throws {
        let output = try await CommandRunner.run(shell("echo result; echo warning >&2"))

        #expect(output.trimmed == "result")
        #expect(output.standardError == "warning\n")
    }

    @Test func aFailedCommandGivesItsErrorOutput() async {
        await #expect(throws: CommandError.failed(program: "sh", status: 3, output: "no access")) {
            try await CommandRunner.run(shell("echo ignored; echo 'no access' >&2; exit 3"))
        }
    }

    @Test func aCommandGetsItsOwnEnvironmentAndNotTheEnvironmentOfTheCaller() async throws {
        let output = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "echo $PGPASSWORD:$PATH"], environment: ["PGPASSWORD": "root"]))

        #expect(output.trimmed == "root:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func aPipeSendsTheOutputOfTheFirstCommandToTheSecond() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "copy.txt")

        try await CommandRunner.pipe(shell("seq 1 100000"), into: Command(executable: URL(filePath: "/usr/bin/tee"), arguments: [file.path(percentEncoded: false)]))

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 100000)
        #expect(lines.last == "100000")
    }

    @Test func aPipeFailsWhenTheFirstCommandFails() async {
        await #expect(throws: CommandError.failed(program: "sh", status: 2, output: "dump failed")) {
            try await CommandRunner.pipe(shell("echo partial; echo 'dump failed' >&2; exit 2"), into: shell("cat > /dev/null"))
        }
    }

    @Test func aPipeGivesTheErrorOfTheFirstCommandWhenTheSecondOnlyGotACutInput() async {
        await #expect(throws: CommandError.failed(program: "sh", status: 2, output: "connection lost")) {
            try await CommandRunner.pipe(
                shell("echo 'CREATE TABLE'; echo 'connection lost' >&2; exit 2"),
                into: shell("cat > /dev/null; echo 'input too short' >&2; exit 1")
            )
        }
    }

    @Test func aPipeGivesTheErrorOfTheSecondCommandWhenTheFirstStoppedOnTheClosedPipe() async {
        await #expect(throws: CommandError.failed(program: "sh", status: 4, output: "restore failed")) {
            try await CommandRunner.pipe(shell("seq 1 100000"), into: shell("echo 'restore failed' >&2; exit 4"))
        }
    }

    @Test func aPipeWithAnObserverSendsAllDataAndShowsEachPart() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "copy.txt")
        let seen = ByteCounter()

        try await CommandRunner.pipe(shell("seq 1 100000"), into: Command(executable: URL(filePath: "/usr/bin/tee"), arguments: [file.path(percentEncoded: false)]), observer: { seen.add($0.count) })

        let copy = try Data(contentsOf: file)
        #expect(String(decoding: copy, as: UTF8.self).split(separator: "\n").last == "100000")
        #expect(seen.total == copy.count)
    }

    @Test func aPipeWithAnObserverGivesTheErrorOfTheSecondCommandWhenItStopsEarly() async {
        await #expect(throws: CommandError.failed(program: "sh", status: 4, output: "restore failed")) {
            try await CommandRunner.pipe(shell("seq 1 1000000"), into: shell("echo 'restore failed' >&2; exit 4"), observer: { _ in })
        }
    }

    @Test(arguments: [false, true])
    func aStoppedPipeStopsBothCommands(observed: Bool) async throws {
        let started = ContinuousClock.now
        var observer: (@Sendable (Data) -> Void)?
        if observed {
            observer = { _ in }
        }

        let relay = observer
        let pipe = Task {
            try await CommandRunner.pipe(shell("yes"), into: shell("cat > /dev/null"), observer: relay)
        }

        try await Task.sleep(for: .milliseconds(300))
        pipe.cancel()

        await #expect(throws: CancellationError.self) {
            try await pipe.value
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aStoppedCommandStops() async throws {
        let started = ContinuousClock.now
        let command = Task {
            try await CommandRunner.run(shell("sleep 30"))
        }

        try await Task.sleep(for: .milliseconds(300))
        command.cancel()

        await #expect(throws: CancellationError.self) {
            try await command.value
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aStoppedCommandThatIgnoresSigtermStopsWithItsOwnSignal() async throws {
        let started = ContinuousClock.now
        let command = Task {
            try await CommandRunner.run(Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"], stopSignal: SIGKILL))
        }

        try await Task.sleep(for: .milliseconds(300))
        command.cancel()

        await #expect(throws: CancellationError.self) {
            try await command.value
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aStopAlsoStopsTheProgramsThatTheProgramStarted() async throws {
        let marker = "nexus-group-\(UUID().uuidString.prefix(8))"
        let command = Task {
            try await CommandRunner.run(Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "/bin/sh -c 'while :; do /bin/sleep 1; done' \(marker) & wait"]))
        }

        try await Task.sleep(for: .milliseconds(300))
        command.cancel()
        _ = try? await command.value
        try await Task.sleep(for: .milliseconds(300))

        let search = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "/usr/bin/pgrep -f '\(marker)' || true"]))
        #expect(search.trimmed.isEmpty)
    }
}

private final class ByteCounter: Sendable {
    private let count = Mutex(0)

    var total: Int {
        count.withLock { $0 }
    }

    func add(_ bytes: Int) {
        count.withLock { $0 += bytes }
    }
}
