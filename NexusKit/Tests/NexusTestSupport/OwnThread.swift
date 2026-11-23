import Foundation

// Blocking work of a test, for example a read on a socket, runs on a thread of its own. A test that
// waits on a thread of the task pool can take the last free thread of a small CI runner. The server
// that the test waits for then cannot answer in time.
public func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(with: Result { try work() })
        }
    }
}
