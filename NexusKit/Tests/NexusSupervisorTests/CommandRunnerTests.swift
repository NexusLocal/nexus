import Darwin
import Foundation
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
}
