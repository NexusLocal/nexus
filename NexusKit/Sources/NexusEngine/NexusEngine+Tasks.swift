import Foundation
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
    }

    private let values = Mutex(Values())

    var current: Values {
        values.withLock { $0 }
    }

    func update(_ change: (inout Values) -> Void) {
        values.withLock { change(&$0) }
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
        return TaskInfo(id: id, work: work, started: started, completed: values.completed, total: values.total, table: values.table, tableNumber: values.tableNumber, tableCount: values.tableCount)
    }
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
        stopped: @escaping @Sendable () -> String,
        _ operation: @escaping @Sendable (TaskProgress) async throws -> Result
    ) async throws -> Result {
        let id = UUID().uuidString
        let progress = TaskProgress()
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
