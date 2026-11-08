import Foundation
import NexusCore
import NexusIPC
import Synchronization

// The progress of one task. A download or a dump writes it from its own thread many times each
// second. nexusd reads it a few times each second and sends the task list to the app.
final class TaskProgress: Sendable {
    struct Values: Sendable, Equatable {
        var completed: Int64 = 0
        var total: Int64?
        var table: String?
        var tableNumber: Int?
        var tableCount: Int?
        var steps: [TaskStep]?
        var stepStarted: Date?
        var logFile: URL?
        // Text that the log view never shows, such as the password of a new WordPress site.
        var secrets: [String] = []
    }

    // The end of the log, read again only when the file grows.
    private let tail = Mutex<(size: UInt64, lines: [String])?>(nil)

    private let values = Mutex(Values())

    var current: Values {
        values.withLock { $0 }
    }

    func update(_ change: (inout Values) -> Void) {
        values.withLock { change(&$0) }
    }

    // The steps of a task with steps. Each start ends the step before it.
    func start(step index: Int) {
        update { values in
            values.endRunningStep(as: .done)
            values.steps?[index].state = .running
            values.stepStarted = .now
        }
    }

    func failRunningStep() {
        update { $0.endRunningStep(as: .failed) }
    }

    func finishSteps() {
        update { $0.endRunningStep(as: .done) }
    }

    // The steps with the label of the spinner of the tool that runs now, and the end of the log.
    func stepsAndLog(lines: Int) -> (steps: [TaskStep]?, log: [String]?) {
        let values = current

        guard let file = values.logFile else {
            return (values.steps, nil)
        }

        let log = logTail(of: file, lines: lines).map { line in
            values.secrets.reduce(line) { $0.replacingOccurrences(of: $1, with: "…") }
        }
        let activity = TerminalOutput.activity(in: log)
        let steps = values.steps?.map { step in
            var step = step
            if step.state == .running {
                step.detail = activity
            }
            return step
        }

        return (steps, log)
    }

    private func logTail(of file: URL, lines: Int) -> [String] {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.size] as? NSNumber)?.uint64Value ?? 0

        if let cached = tail.withLock({ $0 }), cached.size == size {
            return cached.lines
        }

        let read = TerminalOutput.tail(of: file, lines: lines)
        tail.withLock { $0 = (size, read) }
        return read
    }
}

extension TaskProgress.Values {
    mutating func endRunningStep(as state: TaskStepState) {
        guard let index = steps?.firstIndex(where: { $0.state == .running }) else {
            return
        }

        steps?[index].state = state
        steps?[index].seconds = stepStarted.map { max(1, Int(Date.now.timeIntervalSince($0).rounded())) }
    }
}

struct RunningTask {
    let id: String
    let work: TaskWork
    let started: Date
    let progress: TaskProgress
    let cancel: @Sendable () -> Void

    var info: TaskInfo {
        let values = progress.current
        let (steps, log) = progress.stepsAndLog(lines: RunningTask.logLines)
        return TaskInfo(id: id, work: work, started: started, completed: values.completed, total: values.total, table: values.table, tableNumber: values.tableNumber, tableCount: values.tableCount, steps: steps, log: log, logFile: values.logFile?.path(percentEncoded: false))
    }

    static let logLines = 12
}

// The user can stop a task with "stop task" (part 6f). A stopped task throws TaskStopped, and
// the request answers .stopped with its message.
struct TaskStopped: Error, CustomStringConvertible {
    let description: String
}

extension NexusEngine {
    // Runs the work as a task that the app shows and that the user can stop. The work gets a
    // cancel when the user stops it. stopped gives the message for that case.
    func runTask<Result: Sendable>(
        _ work: TaskWork,
        id: String = UUID().uuidString,
        progress: TaskProgress = TaskProgress(),
        stopped: @escaping @Sendable () -> String,
        _ operation: @escaping @Sendable (TaskProgress) async throws -> Result
    ) async throws -> Result {
        let task = Task { try await operation(progress) }

        addTask(RunningTask(id: id, work: work, started: .now, progress: progress, cancel: { task.cancel() }))
        defer { removeTask(id) }

        do {
            return try await task.value
        } catch is CancellationError {
            throw TaskStopped(description: stopped())
        }
    }

    // A click on stop can come just after the end of the task. That is no error.
    func stopTask(_ id: String) -> String {
        guard let task = runningTasks[id] else {
            return "The task ended already."
        }

        task.cancel()
        return "The task stops."
    }
}
