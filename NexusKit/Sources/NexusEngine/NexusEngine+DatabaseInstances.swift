import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

// The account and the databases of each instance (step 6, part 6c).
extension NexusEngine {
    // An instance that has data but no stored account was made before the accounts could
    // change, with root/root. An instance without data gets the account for new instances at its
    // first start. The first start stores that account itself. So root/root goes in only when
    // no account is stored yet.
    func account(of tools: DatabaseTools) async throws -> DatabaseAccount {
        let state = await stateStore.current()

        if let account = state.databaseAccounts[tools.id] {
            return account
        }

        guard Self.holdsDatabase(catalog.dataFolder(for: tools.runtime), kind: tools.kind) else {
            return state.newInstanceAccount
        }

        try await stateStore.update { state in
            if state.databaseAccounts[tools.id] == nil {
                state.databaseAccounts[tools.id] = .standard
            }
        }
        return await stateStore.current().databaseAccounts[tools.id] ?? .standard
    }

    // A running instance listens on the port of its start, also after nexus port gave it a new
    // one.
    func connectionPort(of tools: DatabaseTools) async throws -> Int {
        let running = await supervisor.status().first { $0.id == tools.id && $0.state.isActive }

        if let port = running?.ports.first {
            return port
        }

        return try await port(of: tools)
    }

    // The system databases of the server are left out. MySQL keeps the sizes of its tables for a
    // day by default. The session asks for the current sizes.
    func databaseSizes(_ id: String) async throws -> [DatabaseSize] {
        let (tools, client, work) = try await runningClient(id)
        defer { try? FileManager.default.removeItem(at: work) }

        let mysqlSizes = """
            SELECT s.SCHEMA_NAME, COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0)
            FROM information_schema.SCHEMATA s LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
            WHERE s.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
            GROUP BY s.SCHEMA_NAME ORDER BY s.SCHEMA_NAME
            """

        let sql = switch tools.kind {
        case .mysql: "SET SESSION information_schema_stats_expiry = 0;\n\(mysqlSizes)"
        case .mariadb: mysqlSizes
        case .postgresql: "SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname"
        }

        let users = await databaseUsers(kind: tools.kind, port: client.endpoint.port)

        return try await client.rows(sql).compactMap { row in
            guard row.count == 2, let bytes = Int64(row[1]) else {
                return nil
            }

            return DatabaseSize(name: row[0], bytes: bytes, usedBy: users[row[0]])
        }
    }

    // The sites whose .env points to a database on this port, for each database. Step 8a reads
    // the real configuration of each application (D43). Until then the .env is enough for this
    // list. Laravel uses 127.0.0.1 without DB_HOST.
    func databaseUsers(kind: DatabaseKind, port: Int) async -> [String: [String]] {
        var users: [String: [String]] = [:]

        for (site, _) in resolvedSites(await stateStore.current()) {
            let env = EnvFile.values(of: site.folder.appending(path: ".env")).filter { !$0.value.isEmpty }

            guard let connection = env["DB_CONNECTION"], kind.laravelConnections.contains(connection),
                  let database = env["DB_DATABASE"],
                  ["127.0.0.1", "localhost", "::1"].contains(env["DB_HOST"] ?? "127.0.0.1"),
                  (env["DB_PORT"].flatMap { Int($0) } ?? kind.standardPort) == port else {
                continue
            }

            users[database, default: []].append(site.host)
        }

        return users
    }

    // The instance must run, because the account lives in its data.
    func setAccount(_ id: String, _ account: DatabaseAccount) async throws -> String {
        let new = try DatabaseUser.validated(account)
        let (tools, client, work) = try await runningClient(id)
        defer { try? FileManager.default.removeItem(at: work) }

        let old = client.endpoint.account

        if tools.kind.usesMySQLProtocol {
            try await changeMySQLAccount(client, from: old, to: new)
        } else {
            try await changePostgreSQLAccount(tools, client, from: old, to: new)
        }

        try await stateStore.update { $0.databaseAccounts[id] = new }

        let password = new.password.isEmpty ? "no password" : "the password \(new.password)"
        return "\(id) has the user \(new.user) with \(password) now. Change DB_USERNAME and DB_PASSWORD in the .env files of your sites too."
    }

    // The supervisor marks an instance as running when its process starts. The server accepts
    // connections some seconds later. So a request right after a start waits for the port.
    private func runningClient(_ id: String) async throws -> (DatabaseTools, DatabaseClient, URL) {
        guard let tools = await databaseRuntime(id) else {
            throw RuntimeError.unsupported("Nexus has no database instance \(id). See: nexus db list")
        }

        guard await supervisor.state(of: id)?.isActive == true else {
            throw RuntimeError.unsupported("Start \(id) first.")
        }

        let port = try await connectionPort(of: tools)
        let deadline = ContinuousClock.now + ServiceCatalog.databaseStartTimeout
        while !PortInspector.acceptsConnections(port), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let work = paths.run.appending(path: ".account-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let endpoint = DatabaseEndpoint(host: "127.0.0.1", port: port, account: try await account(of: tools))
        let client = DatabaseClient(tools: tools, endpoint: endpoint, options: work.appending(path: "client.cnf"))

        do {
            try client.prepare()
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }

        return (tools, client, work)
    }

    // The user can exist for more than one host, for example localhost, 127.0.0.1 and ::1. Each
    // one changes. So every way to connect keeps working. One statement renames all hosts. MySQL
    // renames all of them or none.
    private func changeMySQLAccount(_ client: DatabaseClient, from old: DatabaseAccount, to new: DatabaseAccount) async throws {
        let hosts = try await client.rows("SELECT Host FROM mysql.user WHERE User = \(DatabaseConfig.sqlString(old.user))").compactMap(\.first)

        guard !hosts.isEmpty else {
            throw RuntimeError.unsupported("The instance has no user \(old.user).")
        }

        func name(_ user: String, _ host: String) -> String {
            "\(DatabaseConfig.sqlString(user))@\(DatabaseConfig.sqlString(host))"
        }

        let renames = hosts.map { host in "\(name(old.user, host)) TO \(name(new.user, host))" }
        let passwords = hosts.map { host in "\(name(new.user, host)) IDENTIFIED BY \(DatabaseConfig.sqlString(new.password))" }
        let rename = old.user == new.user ? [] : ["RENAME USER \(renames.joined(separator: ", "));"]

        try await client.script((rename + ["ALTER USER \(passwords.joined(separator: ", "));"]).joined(separator: "\n"))
    }

    // PostgreSQL does not rename the user of the session. So a short-lived role makes the change
    // over the socket, where every local connection is trusted. PostgreSQL cannot have an empty
    // password. So pg_hba.conf then trusts the connections over TCP as well. The rename and the
    // password change in one transaction.
    private func changePostgreSQLAccount(_ tools: DatabaseTools, _ client: DatabaseClient, from old: DatabaseAccount, to new: DatabaseAccount) async throws {
        let helperRole = "nexus_account_change"
        let overSocket = { (user: String) in
            let folder = self.paths.databaseSocket(tools.kind, line: tools.runtime.line, port: client.endpoint.port).deletingLastPathComponent()
            let endpoint = DatabaseEndpoint(host: folder.path(percentEncoded: false), port: client.endpoint.port, account: DatabaseAccount(user: user, password: ""))
            return DatabaseClient(tools: tools, endpoint: endpoint, options: client.options)
        }
        let oldRole = DatabaseConfig.identifier(old.user, kind: .postgresql)
        let newRole = DatabaseConfig.identifier(new.user, kind: .postgresql)
        let password = new.password.isEmpty ? "NULL" : PostgreSQLAccess.string(new.password)
        let rename = old.user == new.user ? [] : ["ALTER ROLE \(oldRole) RENAME TO \(newRole);"]

        try await overSocket(old.user).query("DROP ROLE IF EXISTS \(helperRole); CREATE ROLE \(helperRole) SUPERUSER LOGIN")

        do {
            try await overSocket(helperRole).script((["BEGIN;"] + rename + ["ALTER ROLE \(newRole) PASSWORD \(password);", "COMMIT;"]).joined(separator: "\n"))
            try PostgreSQLAccess.setHostMethod(PostgreSQLAccess.hostMethod(for: new), in: catalog.dataFolder(for: tools.runtime))
            try await overSocket(helperRole).query("SELECT pg_reload_conf()")
        } catch {
            for user in [old.user, new.user] {
                _ = try? await overSocket(user).query("DROP ROLE IF EXISTS \(helperRole)")
            }
            throw error
        }

        // The account changed already. A helper role that stays goes at the next change.
        _ = try? await overSocket(new.user).query("DROP ROLE \(helperRole)")
    }
}

enum DatabaseUser {
    // A user name that every client and every option file can carry without quotes. A password
    // with a line break would end the line of an option file.
    static func validated(_ account: DatabaseAccount) throws -> DatabaseAccount {
        let user = account.user

        guard (1...32).contains(user.count),
              user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else {
            throw RuntimeError.unsupported("\(user) is not a user name that Nexus can use. Use 1 to 32 characters: letters, digits, _, - and dots.")
        }

        guard !account.password.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw RuntimeError.unsupported("A password cannot have a line break or another control character.")
        }

        return account
    }
}

// The access rules of PostgreSQL for connections over TCP.
enum PostgreSQLAccess {
    static func hostMethod(for account: DatabaseAccount) -> String {
        account.password.isEmpty ? "trust" : "scram-sha-256"
    }

    // A string literal. PostgreSQL reads a backslash as a normal character. So only the quote
    // needs a second quote.
    static func string(_ value: String) -> String {
        "'\(value.replacing("'", with: "''"))'"
    }

    // Changes the method of each "host" line. The "local" lines for the socket stay trusted.
    static func setHostMethod(_ method: String, in dataFolder: URL) throws {
        let file = dataFolder.appending(path: "pg_hba.conf")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")

        let changed = lines.map { line -> String in
            var fields = line.split(whereSeparator: \.isWhitespace).map(String.init)

            guard fields.first == "host", fields.count >= 5 else {
                return line
            }

            fields[fields.count - 1] = method
            return fields.joined(separator: "    ")
        }

        try changed.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
