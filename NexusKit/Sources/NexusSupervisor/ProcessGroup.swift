import Foundation

// Process starts each program as the leader of its own process group. A signal to the group also
// reaches the programs that the program started, for example the workers of a php-fpm or a
// command in a shell file.
enum ProcessGroup {
    // macOS gives the number of a process to no new process while that process is not collected,
    // or while a group with that number has processes. So the group is still the group of the
    // program when the main process is not collected yet, or when no process has its number.
    // When another process has the number, the group of the program has no processes left.
    static func signal(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier

        guard pid > 0, process.isRunning || kill(pid, 0) == -1 && errno == ESRCH else {
            return
        }

        kill(-pid, signal)
    }
}
