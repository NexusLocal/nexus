import Foundation
import NexusConfig
import NexusCore
import NexusRuntime
import NexusSupervisor

// Runs SQL on one server with the client of an instance. MySQL and MariaDB get the password in an
// option file and PostgreSQL in the environment. So no password shows in the process list. The
// host of a PostgreSQL endpoint can be the folder of its socket.
struct DatabaseClient {
    let tools: DatabaseTools
    let endpoint: DatabaseEndpoint
    let options: URL

    private var kind: DatabaseKind { tools.kind }

    func prepare() throws {
        guard kind.usesMySQLProtocol else {
            return
        }

        let plugins = tools.runtime.folder.appending(path: "lib/plugin", directoryHint: .isDirectory)
        try Data(DatabaseConfig.clientOptions(host: endpoint.host, port: endpoint.port, account: endpoint.account, pluginFolder: plugins).utf8).write(to: options)
    }

    @discardableResult
    func query(_ sql: String, database: String? = nil) async throws -> String {
        guard kind.usesMySQLProtocol else {
            let command = Command(
                executable: tools.client,
                arguments: ["-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", endpoint.host, "-p", String(endpoint.port), "-U", endpoint.account.user, "-d", database ?? "postgres", "-c", sql],
                environment: ["PGPASSWORD": endpoint.account.password]
            )
            return try await CommandRunner.run(command).trimmed
        }

        let command = Command(
            executable: tools.client,
            arguments: ["--defaults-file=\(options.path(percentEncoded: false))", "-N", "-B", "-e", sql] + (database.map { [$0] } ?? [])
        )
        return try await CommandRunner.run(command).trimmed
    }

    // Runs SQL that holds a password. The SQL goes in a private file next to the option file and
    // reaches the client on its standard input. So the password does not show in the process
    // list as an argument does.
    func script(_ sql: String) async throws {
        let file = options.deletingLastPathComponent().appending(path: "script-\(UUID().uuidString).sql")
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(sql.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported("Nexus cannot write \(file.path(percentEncoded: false)).")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let client = kind.usesMySQLProtocol
            ? Command(executable: tools.client, arguments: ["--defaults-file=\(options.path(percentEncoded: false))", "-N", "-B"])
            : Command(
                executable: tools.client,
                arguments: ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-h", endpoint.host, "-p", String(endpoint.port), "-U", endpoint.account.user, "-d", "postgres"],
                environment: ["PGPASSWORD": endpoint.account.password]
            )

        try await CommandRunner.pipe(Command(executable: URL(filePath: "/bin/cat"), arguments: [file.path(percentEncoded: false)]), into: client)
    }

    // Each row of the answer, with its columns.
    func rows(_ sql: String, database: String? = nil) async throws -> [[String]] {
        try await query(sql, database: database)
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
}
