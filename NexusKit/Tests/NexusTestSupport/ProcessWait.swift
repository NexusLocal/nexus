import Darwin
import Foundation

extension Process {
    // waitUntilExit runs the run loop of the current thread. In a task after an await it can wait
    // without an end, also when the program ended already. In a check with 24 such tasks 15 waits
    // did not end. This wait reads isRunning and does not use the run loop.
    public func waitForEnd() {
        while isRunning {
            usleep(10_000)
        }
    }
}
