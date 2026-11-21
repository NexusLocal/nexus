// Runs one operation at a time, in the order of the calls. Each operation waits for the end of the
// operation before it, also after a failure. A caller never waits for the queue while it holds the
// queue.
struct SerialQueue {
    private(set) var last: Task<Void, Never>?

    mutating func run<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) -> Task<Result, any Error> {
        let previous = last
        let turn = Task {
            await previous?.value
            return try await operation()
        }

        last = Task { _ = try? await turn.value }
        return turn
    }
}
