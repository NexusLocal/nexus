import Foundation
import NexusCore
import NexusMongoDB
import NexusRuntime
import Synchronization

// The MongoDB server of a workspace (D66, group 6 step 4). Its clone gets its own replica set on the
// port of the workspace before it counts as complete.
extension NexusEngine {
    static let mongoDBLockLimit: Duration = .seconds(10)
    // A lock that comes after the limit must still get its unlock. Only the request of the lock
    // waits this long.
    static let lateLockTimeout: TimeInterval = 86_400

    // The fsync lock makes the files safe to copy. Writes wait during the lock, and reads go on. The
    // lock does not end with its connection. A stop of mongod ends it, and nexusd stops each server of
    // an earlier run at its start. The server takes a lock also after its client stopped to wait,
    // and also after killOp (tested with 7.0, 8.0 and 9.0). So the request stays, and the unlock
    // follows a late lock at once. The lock is a counter that all clients share. So one clone of an
    // instance runs at a time, and the repair of a failed unlock cannot end the lock of another clone.
    func cloneDuringLock(_ tools: DatabaseTools, source: String, target: String) async throws {
        let blocked = "A long write on \(tools.id) blocks the lock, so Nexus made no clone. Retry when that write ended."
        let deadline = ContinuousClock.now + Self.mongoDBLockLimit

        while lockingMongoDBInstances.contains(tools.id) {
            guard ContinuousClock.now < deadline else {
                throw RuntimeError.unsupported(blocked)
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        lockingMongoDBInstances.insert(tools.id)
        var waitsForLateLock = false
        defer {
            if !waitsForLateLock {
                lockingMongoDBInstances.remove(tools.id)
            }
        }

        let server = try await mongoDBServer(tools)
        let lock = Task {
            await server.connection.setTimeout(Self.lateLockTimeout)
            try await server.lock()
        }
        let isLocked: Bool

        do {
            isLocked = try await Self.ends(lock, within: Self.mongoDBLockLimit)
        } catch {
            await server.connection.disconnect()
            throw RuntimeError.unsupported("\(tools.id) gave an error at the lock, so Nexus made no clone. \(ErrorText.plain(error))")
        }

        guard isLocked else {
            waitsForLateLock = true

            Task {
                if (try? await lock.value) != nil {
                    try? await server.unlock()
                }

                await server.connection.disconnect()
                lockingMongoDBInstances.remove(tools.id)
            }

            throw RuntimeError.unsupported(blocked)
        }

        await server.connection.setTimeout(MongoDBConnection.standardTimeout)

        var failure: (any Error)?

        do {
            try await Self.cloneOutsideTheActor(source, to: target)
        } catch {
            failure = error
        }

        let heldTheLock = (try? await server.isLocked()) == true
        let unlocked = (try? await server.unlock()) != nil
        await server.connection.disconnect()

        if !unlocked {
            await endLock(of: tools)
        }

        if let failure {
            throw failure
        }

        guard heldTheLock else {
            throw RuntimeError.unsupported("The lock of \(tools.id) ended before the clone was complete, so Nexus made no clone. Retry when \(tools.id) runs.")
        }
    }

    // The connection of the lock failed after the lock. A server that does not run has no lock. One
    // clone of an instance runs at a time, so a lock here is the lock of this clone. A server that
    // still has a lock after a new unlock gets a restart, because each write waits.
    private func endLock(of tools: DatabaseTools) async {
        guard let server = try? await mongoDBServer(tools) else {
            return
        }

        if (try? await server.isLocked()) == true {
            try? await server.unlock()
        }

        let isStillLocked = (try? await server.isLocked()) != false
        await server.connection.disconnect()

        if isStillLocked {
            _ = try? await restart(tools.id, cause: "a lock for a clone that Nexus could not end")
        }
    }

    // A clone has the replica set of the main server, with the port of that server.
    func moveReplicaSet(ofClone folder: String, tools: DatabaseTools, to port: Int) async throws {
        try await moveReplicaSet(of: tools, data: URL(filePath: folder, directoryHint: .isDirectory), to: port, logFile: paths.log(tools.id))
    }

    // hello needs no login. A clone takes writes after the election of its set.
    func becomesPrimary(port: Int, until deadline: ContinuousClock.Instant) async throws -> Bool {
        while ContinuousClock.now < deadline {
            if let connection = try? await MongoDBConnection.connect(port: port, timeout: 1) {
                let isPrimary = (try? await MongoDBServer(connection).isPrimary()) == true
                await connection.disconnect()

                if isPrimary {
                    return true
                }
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        return false
    }

    // A MongoDB database exists from its first write. So an empty database is a database that is
    // not there.
    func emptyMongoDBDatabases(_ names: [String], port: Int, account: DatabaseAccount) async throws {
        let connection = try await MongoDBConnection.connect(port: port, account: account)
        let server = MongoDBServer(connection)

        do {
            for name in Set(names).sorted() {
                try await server.dropDatabase(try DatabaseName.validated(name))
            }
        } catch {
            await connection.disconnect()
            throw error
        }

        await connection.disconnect()
    }

    // True when the task ended within the limit, and false when it still runs. The task goes on
    // after the limit.
    static func ends(_ task: Task<Void, any Error>, within limit: Duration) async throws -> Bool {
        let first = FirstResult()

        return try await withCheckedThrowingContinuation { continuation in
            first.set(continuation)

            Task {
                first.resume(with: await task.result.map { true })
            }

            Task {
                try? await Task.sleep(for: limit)
                first.resume(with: .success(false))
            }
        }
    }
}

private final class FirstResult: Sendable {
    private let continuation = Mutex<CheckedContinuation<Bool, any Error>?>(nil)

    func set(_ continuation: CheckedContinuation<Bool, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(with result: Result<Bool, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}
