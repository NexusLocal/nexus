import Foundation
import Synchronization

public struct Command: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    // The signal that stops the program when the task is cancelled. An interactive shell ignores
    // SIGTERM. So it needs SIGKILL.
    public let stopSignal: Int32

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: URL? = nil, stopSignal: Int32 = SIGTERM) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stopSignal = stopSignal
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
// blocked thread. A cancelled task stops its programs and gets a CancellationError.
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

        let exit = try start(process)
        let end = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            ProcessGroup.signal(process, command.stopSignal)
        }

        try Task.checkCancellation()
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
    // cut input, so the error of the first is the cause. With an observer, nexusd passes each
    // part of the data on itself. The observer sees each part first, for example to count the
    // bytes of a dump.
    public static func pipe(_ first: Command, into second: Command, observer: (@Sendable (Data) -> Void)? = nil) async throws {
        let firstErrors = try OutputFile()
        let secondOutput = try OutputFile()
        defer {
            firstErrors.remove()
            secondOutput.remove()
        }

        let output = Pipe()
        let input = observer == nil ? output : Pipe()
        let producer = try makeProcess(first)
        producer.standardInput = FileHandle.nullDevice
        producer.standardOutput = output
        producer.standardError = firstErrors.handle

        let consumer = try makeProcess(second)
        consumer.standardInput = input
        consumer.standardOutput = secondOutput.handle
        consumer.standardError = secondOutput.handle

        let producerExit = try start(producer)
        let consumerExit: ExitStatus

        do {
            consumerExit = try start(consumer)
        } catch {
            ProcessGroup.signal(producer, first.stopSignal)
            _ = await producerExit.wait()
            throw error
        }

        let relay = observer.map { relay(from: output.fileHandleForReading, to: input.fileHandleForWriting, observer: $0) }
        let (consumerEnd, producerEnd) = await withTaskCancellationHandler {
            let consumerEnd = await consumerExit.wait()
            let producerEnd = await producerExit.wait()
            await relay?.wait()
            return (consumerEnd, producerEnd)
        } onCancel: {
            ProcessGroup.signal(producer, first.stopSignal)
            ProcessGroup.signal(consumer, second.stopSignal)
        }

        try Task.checkCancellation()
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

    // Reads on its own thread, because a read waits until data comes. A write to a consumer that
    // stopped fails with an error and not with a SIGPIPE for nexusd. The relay then closes its
    // ends. So the producer stops on the closed pipe.
    private static func relay(from source: FileHandle, to destination: FileHandle, observer: @escaping @Sendable (Data) -> Void) -> RelayEnd {
        let end = RelayEnd()
        let input = source.fileDescriptor
        let output = destination.fileDescriptor
        _ = fcntl(output, F_SETNOSIGPIPE, 1)

        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)

            reading: while true {
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR {
                    continue
                }

                guard count > 0 else {
                    break
                }

                observer(Data(buffer[0..<count]))

                var written = 0
                while written < count {
                    let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                    if result < 0, errno == EINTR {
                        continue
                    }

                    guard result > 0 else {
                        break reading
                    }

                    written += result
                }
            }

            try? destination.close()
            try? source.close()
            end.finish()
        }

        return end
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

private final class RelayEnd: Sendable {
    private let state = Mutex<(finished: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func finish() {
        let waiter = state.withLock { state in
            state.finished = true
            return state.waiter.take()
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state in
                if !state.finished {
                    state.waiter = continuation
                }
                return state.finished
            }

            if finished {
                continuation.resume()
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
