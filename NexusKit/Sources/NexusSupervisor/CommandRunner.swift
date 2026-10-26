import Foundation
import Synchronization

public struct Command: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct CommandOutput: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String

    public var trimmed: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case failed(program: String, status: Int32, output: String)

    public var description: String {
        switch self {
        case .failed(let program, let status, let output) where output.isEmpty:
            "\(program) stopped with exit status \(status)."
        case .failed(let program, let status, let output):
            "\(program) stopped with exit status \(status): \(output)"
        }
    }
}

// Runs the programs that nexusd needs next to its services, such as a database initialization,
// a dump and a restore. The output goes to a file and not to a pipe, so a program with much
// output cannot block. A program runs on its own process, and the caller waits without a
// blocked thread.
public enum CommandRunner {
    @discardableResult
    public static func run(_ command: Command) async throws -> CommandOutput {
        let output = try OutputFile()
        let errors = try OutputFile()
        defer {
            output.remove()
            errors.remove()
        }

        let process = try makeProcess(command)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.handle
        process.standardError = errors.handle

        let end = await (try start(process)).wait()
        let result = CommandOutput(standardOutput: output.text(), standardError: errors.text())

        guard !end.failed else {
            let reason = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw CommandError.failed(program: command.executable.lastPathComponent, status: end.status, output: tail(reason))
        }

        return result
    }

    // Sends the output of the first program to the input of the second, as a shell pipe does.
    // Both must succeed. When the second stops early, the first stops on the closed pipe, so the
    // error of the second is the cause. When the first fails in another way, the second got a
    // cut input, so the error of the first is the cause.
    public static func pipe(_ first: Command, into second: Command) async throws {
        let firstErrors = try OutputFile()
        let secondOutput = try OutputFile()
        defer {
            firstErrors.remove()
            secondOutput.remove()
        }

        let pipe = Pipe()
        let producer = try makeProcess(first)
        producer.standardInput = FileHandle.nullDevice
        producer.standardOutput = pipe
        producer.standardError = firstErrors.handle

        let consumer = try makeProcess(second)
        consumer.standardInput = pipe
        consumer.standardOutput = secondOutput.handle
        consumer.standardError = secondOutput.handle

        let producerExit = try start(producer)
        let consumerExit: ExitStatus

        do {
            consumerExit = try start(consumer)
        } catch {
            producer.terminate()
            _ = await producerExit.wait()
            throw error
        }

        let consumerEnd = await consumerExit.wait()
        let producerEnd = await producerExit.wait()
        let producerErrors = firstErrors.text()
        let producerError = CommandError.failed(program: first.executable.lastPathComponent, status: producerEnd.status, output: tail(producerErrors))
        let producerStoppedOnClosedPipe = producerEnd == Termination(status: SIGPIPE, signaled: true) || producerErrors.contains("Broken pipe")

        if producerEnd.failed, !producerStoppedOnClosedPipe {
            throw producerError
        }

        if consumerEnd.failed {
            throw CommandError.failed(program: second.executable.lastPathComponent, status: consumerEnd.status, output: tail(secondOutput.text()))
        }

        if producerEnd.failed {
            throw producerError
        }
    }

    private static func makeProcess(_ command: Command) throws -> Process {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = ChildEnvironment.base().merging(command.environment) { _, own in own }
        process.currentDirectoryURL = command.workingDirectory
        return process
    }

    private static func start(_ process: Process) throws -> ExitStatus {
        let exit = ExitStatus()
        process.terminationHandler = { exit.finish(Termination(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal)) }
        try process.run()
        return exit
    }

    private static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 2000 ? "...\(trimmed.suffix(2000))" : trimmed
    }
}

// For a program that a signal stopped, the status is the number of the signal.
private struct Termination: Sendable, Equatable {
    let status: Int32
    let signaled: Bool

    var failed: Bool {
        signaled || status != 0
    }
}

private final class ExitStatus: Sendable {
    private let state = Mutex<(end: Termination?, waiter: CheckedContinuation<Termination, Never>?)>((nil, nil))

    func finish(_ end: Termination) {
        let waiter = state.withLock { state in
            state.end = end
            return state.waiter.take()
        }
        waiter?.resume(returning: end)
    }

    func wait() async -> Termination {
        await withCheckedContinuation { continuation in
            let end = state.withLock { state in
                if state.end == nil {
                    state.waiter = continuation
                }
                return state.end
            }

            if let end {
                continuation.resume(returning: end)
            }
        }
    }
}

private struct OutputFile {
    let url: URL
    let handle: FileHandle

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "nexus-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func text() -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    func remove() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
