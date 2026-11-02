import Darwin
import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// A client that stays connected between two statements, because a read lock and a backup mode of
// PostgreSQL end with their connection. So a stop of nexusd cannot leave a freeze behind.
final class DatabaseSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors: URL

    // The errors go to a file, because PostgreSQL also writes notices to standard error, and a pipe
    // that nobody reads can stop the client.
    init(_ client: DatabaseClient) throws {
        let command = client.sessionCommand

        errors = client.options.deletingLastPathComponent().appending(path: "session-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: errors.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = ChildEnvironment.base().merging(command.environment) { _, own in own }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)

        // A client that stopped must give an error here, and no SIGPIPE for nexusd.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    func send(_ sql: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\(sql)\n".utf8))
    }

    // The lines before the line with this text. The client stops at a statement that fails, so its
    // output ends and this gives nil. A client that gives no answer in time stops too.
    func lines(until end: String, within limit: Duration) async -> [String]? {
        let timer = Task { [self] in
            guard (try? await Task.sleep(for: limit)) != nil else {
                return
            }

            stop()
        }

        defer { timer.cancel() }

        let handle = output.fileHandleForReading

        return await Task.detached { Self.read(handle, until: end) }.value
    }

    var errorText: String {
        ((try? String(contentsOf: errors, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close() {
        try? input.fileHandleForWriting.close()
        stop()
        try? FileManager.default.removeItem(at: errors)
    }

    private func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    private static func read(_ handle: FileHandle, until end: String) -> [String]? {
        var text = ""

        while true {
            let part = handle.availableData

            guard !part.isEmpty else {
                return nil
            }

            text += String(decoding: part, as: UTF8.self)

            let lines = text.components(separatedBy: "\n")

            if lines.dropLast().contains(end) {
                return Array(lines.prefix { $0 != end })
            }
        }
    }
}

// Clones the data folder of a running instance (D66). A running server writes to its files all the
// time, also when no site uses it. So a clone needs a moment without writes.
struct DatabaseSnapshot {
    private static let lockWaitSeconds = 5
    private static let quietLimit: Duration = .seconds(10)
    private static let backupLimit: Duration = .seconds(30)

    let tools: DatabaseTools
    let client: DatabaseClient
    let source: String
    let target: String

    func take() async throws {
        if tools.kind.usesMySQLProtocol {
            try await takeDuringFreeze()
        } else {
            try await takeInBackupMode()
        }
    }

    // What belongs to the server of the source and not to a new server. A MySQL server takes its
    // identity from auto.cnf. PostgreSQL does not start with the process file of another server.
    static func removeFilesOfSource(from folder: String, kind: DatabaseKind) throws {
        let manager = FileManager.default

        for name in try manager.contentsOfDirectory(atPath: folder) where belongsToSource(name, kind: kind) {
            try manager.removeItem(atPath: "\(folder)/\(name)")
        }
    }

    private static func belongsToSource(_ name: String, kind: DatabaseKind) -> Bool {
        guard kind.usesMySQLProtocol else {
            return name == "postmaster.pid" || name == "postmaster.opts"
        }

        return name == "auto.cnf" || name.hasPrefix("binlog.") || name.hasSuffix(".pid")
    }

    // The read lock waits for running statements and stops new writes. A writer waits and goes on
    // after the lock, so it gets no error. A transaction that stays open during the clone ends as
    // after a crash: the new server rolls it back. The lock does not stop the writes of the server
    // itself, so the clone waits until nothing is left to write.
    private func takeDuringFreeze() async throws {
        let session = try DatabaseSession(client)
        defer { session.close() }

        try session.send("SET SESSION lock_wait_timeout = \(Self.lockWaitSeconds);\nFLUSH TABLES WITH READ LOCK;\nSELECT 'nexus-frozen';")

        guard await session.lines(until: "nexus-frozen", within: .seconds(Self.lockWaitSeconds + 3)) != nil else {
            throw RuntimeError.unsupported(freezeProblem(session.errorText))
        }

        let settings = try await client.rows("SELECT @@global.innodb_max_dirty_pages_pct, @@global.innodb_max_dirty_pages_pct_lwm")

        guard let limits = settings.first, limits.count == 2 else {
            throw RuntimeError.unsupported("\(tools.id) gave no settings for the freeze, so Nexus made no clone.")
        }

        var failure: (any Error)?

        do {
            try await client.query("SET GLOBAL innodb_max_dirty_pages_pct_lwm = 0; SET GLOBAL innodb_max_dirty_pages_pct = 0")
            try await waitUntilQuiet()
            try await NexusEngine.cloneOutsideTheActor(source, to: target)
        } catch {
            failure = error
        }

        // The lock ends with its connection. So a client that stopped has no answer here, and the
        // files can have changed during the clone.
        try? session.send("UNLOCK TABLES;\nSELECT 'nexus-end';")
        let heldTheLock = await session.lines(until: "nexus-end", within: .seconds(5)) != nil
        _ = try? await client.query("SET GLOBAL innodb_max_dirty_pages_pct = \(limits[0]); SET GLOBAL innodb_max_dirty_pages_pct_lwm = \(limits[1])")

        if let failure {
            throw failure
        }

        guard heldTheLock else {
            throw RuntimeError.unsupported("The freeze of \(tools.id) ended before the clone was complete, so Nexus made no clone. Retry when \(tools.id) runs.")
        }
    }

    // A client that gave no answer in time has no error text.
    private func freezeProblem(_ error: String) -> String {
        guard error.isEmpty || error.contains("Lock wait timeout") else {
            return "\(tools.id) gave an error at the freeze, so Nexus made no clone. \(error)"
        }

        return "A long statement on \(tools.id) blocks the freeze, so Nexus made no clone. Retry when that statement ended."
    }

    private var redoKeys: (current: String, flushed: String) {
        tools.kind == .mysql
            ? ("Innodb_redo_log_current_lsn", "Innodb_redo_log_flushed_to_disk_lsn")
            : ("Innodb_lsn_current", "Innodb_lsn_flushed")
    }

    // Quiet means no dirty page in memory, and a redo log that is on disk and that does not grow.
    private func waitUntilQuiet() async throws {
        let keys = redoKeys
        let deadline = ContinuousClock.now + Self.quietLimit
        var last: String?

        while ContinuousClock.now < deadline {
            let rows = try await client.rows("SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_buffer_pool_pages_dirty', '\(keys.current)', '\(keys.flushed)')")
            let values = Dictionary(rows.filter { $0.count == 2 }.map { ($0[0], $0[1]) }) { first, _ in first }

            guard let current = values[keys.current], let flushed = values[keys.flushed] else {
                throw RuntimeError.unsupported("\(tools.id) does not show the state of its redo log, so Nexus made no clone.")
            }

            if values["Innodb_buffer_pool_pages_dirty"] == "0", current == flushed, current == last {
                return
            }

            last = current
            try await Task.sleep(for: .milliseconds(50))
        }

        throw RuntimeError.unsupported("The files of \(tools.id) did not become quiet in time, so Nexus made no clone. Retry when the load on \(tools.id) is lower.")
    }

    // PostgreSQL makes a clone safe during writes. The server keeps all changes since the start of
    // this mode in its write-ahead log, and the new server applies them. The last of these changes
    // come after the clone, so pg_wal gets a new clone. PostgreSQL 14 has older names.
    private func takeInBackupMode() async throws {
        let session = try DatabaseSession(client)
        defer { session.close() }

        let hasOldNames = VersionLine.isOlder(tools.runtime.line, than: "15")
        let start = hasOldNames ? "SELECT pg_start_backup('nexus', true, false);" : "SELECT pg_backup_start('nexus', true);"
        let stop = hasOldNames ? "SELECT labelfile FROM pg_stop_backup(false, true);" : "SELECT labelfile FROM pg_backup_stop(true);"

        try session.send("\(start)\nSELECT 'nexus-started';")

        guard await session.lines(until: "nexus-started", within: Self.backupLimit) != nil else {
            throw RuntimeError.unsupported("\(tools.id) did not start its backup mode, so Nexus made no clone. \(session.errorText)")
        }

        try await NexusEngine.cloneOutsideTheActor(source, to: target)
        try session.send("\(stop)\nSELECT 'nexus-stopped';")

        guard let label = await session.lines(until: "nexus-stopped", within: Self.backupLimit) else {
            throw RuntimeError.unsupported("\(tools.id) did not end its backup mode, so the clone is not complete. \(session.errorText)")
        }

        let log = "\(target)/pg_wal"

        try FileManager.default.removeItem(atPath: log)
        try await NexusEngine.cloneOutsideTheActor("\(source)/pg_wal", to: log)
        try Data("\(label.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))\n".utf8).write(to: URL(filePath: "\(target)/backup_label"))
    }
}
