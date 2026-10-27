import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

struct DatabaseTools {
    let id: String
    let kind: DatabaseKind
    let runtime: InstalledRuntime

    var client: URL {
        switch kind {
        case .mysql: bin("mysql")
        case .mariadb: bin("mariadb")
        case .postgresql: bin("psql")
        }
    }

    var dump: URL {
        switch kind {
        case .mysql: bin("mysqldump")
        case .mariadb: bin("mariadb-dump")
        case .postgresql: bin("pg_dump")
        }
    }

    func bin(_ name: String) -> URL {
        runtime.folder.appending(path: "bin/\(name)")
    }
}

// MySQL, MariaDB and PostgreSQL (step 5).
extension NexusEngine {
    static func isDatabaseService(_ id: String) -> Bool {
        DatabaseKind.allCases.contains { id.hasPrefix("\($0.rawValue)-") }
    }

    func databaseRuntime(_ id: String) async -> DatabaseTools? {
        guard Self.isDatabaseService(id) else {
            return nil
        }

        return await databaseRuntimes().first { $0.id == id }
    }

    private func databaseRuntimes() async -> [DatabaseTools] {
        await serviceRuntimes().compactMap { runtime in
            guard let kind = ServiceCatalog.databaseKind(of: runtime), let id = catalog.serviceID(for: runtime) else {
                return nil
            }

            return DatabaseTools(id: id, kind: kind, runtime: runtime)
        }
    }

    func port(of tools: DatabaseTools) async throws -> Int {
        try await ports(for: tools.runtime)[tools.id] ?? tools.kind.standardPort
    }

    func databaseInstances() async throws -> [DatabaseInstance] {
        var all: [DatabaseInstance] = []

        for tools in await databaseRuntimes() {
            all.append(DatabaseInstance(
                id: tools.id,
                kind: tools.kind,
                version: tools.runtime.version,
                port: try await port(of: tools),
                account: .standard,
                running: await supervisor.state(of: tools.id)?.isActive == true,
                dataFolder: catalog.dataFolder(for: tools.runtime).path(percentEncoded: false)
            ))
        }

        return all.sorted { $0.id < $1.id }
    }

    // A new instance gets its data folder before its first start, because MySQL needs longer for
    // it than a start may take. The initialization writes into a folder next to the data folder
    // and moves it into place only when it succeeds. So a failed one leaves nothing that blocks
    // the next try.
    func prepareDatabase(_ tools: DatabaseTools) async throws {
        let line = tools.runtime.line
        let socket = paths.databaseSocket(tools.kind, line: line, port: try await port(of: tools))

        guard socket.path(percentEncoded: false).utf8.count <= 103 else {
            throw ConfigError.socketPathTooLong(socket.path(percentEncoded: false))
        }

        try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true)

        if tools.kind.usesMySQLProtocol {
            let myCnf = paths.databaseConfig(tools.kind, line: line)
            if !FileManager.default.fileExists(atPath: myCnf.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: myCnf.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(DatabaseConfig.initialMyCnf.utf8).write(to: myCnf)
            }
        }

        let data = catalog.dataFolder(for: tools.runtime)
        if Self.holdsDatabase(data, kind: tools.kind) {
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false))) ?? []
        guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
            throw RuntimeError.unsupported("\(data.path(percentEncoded: false)) has files, but no \(tools.kind.displayName) data. Move the folder away. Nexus then makes a new data folder at the next start.")
        }

        let staging = paths.data.appending(path: ".\(tools.id).new", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)

        let output: CommandOutput
        do {
            output = try await initialize(tools, into: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw RuntimeError.unsupported("Nexus could not make the data folder of \(tools.kind.displayName) \(line). \(error)")
        }

        try? FileManager.default.removeItem(at: data)
        try FileManager.default.moveItem(at: staging, to: data)

        if let log = try? LogFile.openForAppending(paths.log(tools.id)) {
            try? log.write(contentsOf: Data((output.standardOutput + output.standardError).utf8))
            try? log.close()
        }
    }

    static func holdsDatabase(_ folder: URL, kind: DatabaseKind) -> Bool {
        let marker = kind.usesMySQLProtocol ? "mysql" : "PG_VERSION"
        return FileManager.default.fileExists(atPath: folder.appending(path: marker).path(percentEncoded: false))
    }

    // Each way ends with the user root and the password root on 127.0.0.1 (D35). A file with
    // the password lives only during the initialization.
    private func initialize(_ tools: DatabaseTools, into folder: URL) async throws -> CommandOutput {
        let account = DatabaseAccount.standard
        let secret = paths.run.appending(path: ".\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: secret) }

        let datadir = folder.path(percentEncoded: false)

        switch tools.kind {
        case .mysql:
            try Self.writePrivate(DatabaseConfig.mysqlInitSQL(account: account), to: secret)
            return try await CommandRunner.run(Command(
                executable: tools.bin("mysqld"),
                arguments: [
                    "--no-defaults",
                    "--basedir=\(tools.runtime.folder.path(percentEncoded: false))",
                    "--datadir=\(datadir)",
                    "--initialize-insecure",
                    "--init-file=\(secret.path(percentEncoded: false))",
                ],
                workingDirectory: tools.runtime.folder
            ))
        case .mariadb:
            // The script breaks on the space in "Application Support", so it runs in the package
            // folder with --basedir=. The data folder may have a space.
            try Self.writePrivate(DatabaseConfig.mariadbInitSQL(account: account), to: secret)
            return try await CommandRunner.run(Command(
                executable: tools.runtime.folder.appending(path: "scripts/mariadb-install-db"),
                arguments: [
                    "--no-defaults",
                    "--basedir=.",
                    "--datadir=\(datadir)",
                    "--auth-root-authentication-method=normal",
                    "--skip-test-db",
                    "--extra-file=\(secret.path(percentEncoded: false))",
                ],
                workingDirectory: tools.runtime.folder
            ))
        case .postgresql:
            try Self.writePrivate("\(account.password)\n", to: secret)
            var arguments = [
                "-D", datadir,
                "-U", account.user,
                "--pwfile=\(secret.path(percentEncoded: false))",
                "--auth-local=trust",
                "--auth-host=scram-sha-256",
                "--encoding=UTF8",
                "--locale=en_US.UTF-8",
            ]

            // PostgreSQL 15 is the first version that can sort with ICU.
            if !VersionLine.isOlder(tools.runtime.line, than: "15") {
                arguments += ["--locale-provider=icu", "--icu-locale=en-US"]
            }

            return try await CommandRunner.run(Command(executable: tools.bin("initdb"), arguments: arguments, workingDirectory: tools.runtime.folder))
        }
    }

    private static func writePrivate(_ contents: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported("Nexus cannot write \(file.path(percentEncoded: false)).")
        }
    }
}

// Copying a database from another server (D37). Nexus only reads the other server. It changes only
// the database in its own instance.
extension NexusEngine {
    func copyDatabase(_ request: DatabaseCopy) async throws -> String {
        guard let tools = await databaseRuntime(request.instance) else {
            throw RuntimeError.unsupported("Nexus has no database instance \(request.instance). See: nexus db list")
        }

        let database = try DatabaseName.validated(request.database)
        let name = try DatabaseName.validated(request.name ?? request.database)
        let port = try await port(of: tools)
        let source = DatabaseEndpoint(host: request.source.host, port: request.source.port ?? tools.kind.standardPort, account: request.source.account)
        let target = DatabaseEndpoint(host: "127.0.0.1", port: port, account: .standard)

        if source.isLocal, source.port == port, database == name {
            throw RuntimeError.unsupported("\(database) cannot be copied onto itself. Give the copy another name with --as.")
        }

        if await supervisor.state(of: request.instance)?.isActive != true {
            _ = try await serialWeb { try await self.start(request.instance) }
        }

        let work = paths.run.appending(path: ".copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let copier = DatabaseCopier(tools: tools, source: source, target: target, work: work)
        try copier.prepare()

        // The other server must answer before Nexus drops anything, so a wrong name or a
        // stopped server does not cost the old copy.
        let create = try await copier.createStatement(for: database, as: name)

        if try await copier.exists(name) {
            guard request.replace else {
                throw RuntimeError.unsupported("\(request.instance) has a database \(name) already. Add --replace to drop it and copy it again, or give the copy another name with --as.")
            }
            try await copier.drop(name)
        }

        let copied = try await copier.copy(database, as: name, create: create)
        let tables = Self.count(copied.tables, "table")
        let views = Self.count(copied.views, "view")
        let contents = copied.views > 0 ? "\(tables) and \(views)" : tables

        return """
            \(database) is copied from \(source.host):\(source.port) to \(request.instance) as \(name), with \(contents).
            Connect to port \(port) on 127.0.0.1 with the user \(target.account.user) and the password \(target.account.password).
            """
    }
}

struct DatabaseEndpoint {
    let host: String
    let port: Int
    let account: DatabaseAccount

    var isLocal: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }
}

// The steps of one copy. MySQL and MariaDB get the passwords in option files and PostgreSQL in
// the environment, so no password shows in the process list.
struct DatabaseCopier {
    let tools: DatabaseTools
    let source: DatabaseEndpoint
    let target: DatabaseEndpoint
    let work: URL

    private var sourceOptions: URL { work.appending(path: "source.cnf") }
    private var targetOptions: URL { work.appending(path: "target.cnf") }
    private var kind: DatabaseKind { tools.kind }

    func prepare() throws {
        guard kind.usesMySQLProtocol else {
            return
        }

        let plugins = tools.runtime.folder.appending(path: "lib/plugin", directoryHint: .isDirectory)
        try Data(DatabaseConfig.clientOptions(host: source.host, port: source.port, account: source.account, pluginFolder: plugins).utf8).write(to: sourceOptions)
        try Data(DatabaseConfig.clientOptions(host: target.host, port: target.port, account: target.account, pluginFolder: plugins).utf8).write(to: targetOptions)
    }

    // Names are checked with DatabaseName.validated, so they have no quotes.
    func exists(_ name: String) async throws -> Bool {
        let sql = kind.usesMySQLProtocol
            ? "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(name)'"
            : "SELECT COUNT(*) FROM pg_database WHERE datname = '\(name)'"

        return try await query(.target, sql) == "1"
    }

    func drop(_ name: String) async throws {
        let sql = kind.usesMySQLProtocol
            ? "DROP DATABASE \(DatabaseConfig.identifier(name, kind: kind))"
            : "DROP DATABASE \(DatabaseConfig.identifier(name, kind: kind)) WITH (FORCE)"

        try await query(.target, sql)
    }

    // Returns the number of tables and views in the copy. A copy that fails is dropped, so no
    // half database stays behind.
    func copy(_ database: String, as name: String, create: String) async throws -> (tables: Int, views: Int) {
        try await query(.target, create)

        do {
            try await CommandRunner.pipe(dumpCommand(database), into: restoreCommand(name))
        } catch {
            try? await drop(name)
            throw error
        }

        let counts = try await query(.target, countStatement, database: name).split(separator: "\t").compactMap { Int($0) }
        return (counts.first ?? 0, counts.dropFirst().first ?? 0)
    }

    // MySQL and MariaDB: the copy gets the character set and the collation of the original. The
    // query also checks that the other server answers and has the database.
    func createStatement(for database: String, as name: String) async throws -> String {
        let identifier = DatabaseConfig.identifier(name, kind: kind)

        do {
            guard kind.usesMySQLProtocol else {
                try await query(.source, "SELECT 1", database: database)
                return "CREATE DATABASE \(identifier) TEMPLATE template0"
            }

            let settings = try await query(.source, "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(database)'")
                .split(separator: "\t")
                .map(String.init)

            guard settings.count == 2 else {
                throw RuntimeError.unsupported("The server on \(source.host):\(source.port) has no database \(database).")
            }

            return "CREATE DATABASE \(identifier) CHARACTER SET \(settings[0]) COLLATE \(settings[1])"
        } catch let error as CommandError {
            throw RuntimeError.unsupported("Nexus cannot read \(database) on \(source.host):\(source.port). \(error)")
        }
    }

    private var countStatement: String {
        kind.usesMySQLProtocol
            ? "SELECT COUNT(TABLE_TYPE = 'BASE TABLE' OR NULL), COUNT(TABLE_TYPE = 'VIEW' OR NULL) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
            : "SELECT COUNT(*) FILTER (WHERE table_type = 'BASE TABLE'), COUNT(*) FILTER (WHERE table_type = 'VIEW') FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')"
    }

    private func dumpCommand(_ database: String) -> Command {
        guard kind.usesMySQLProtocol else {
            return Command(
                executable: tools.dump,
                arguments: ["-h", source.host, "-p", String(source.port), "-U", source.account.user, "-d", database, "-Fc", "--no-owner", "--no-privileges"],
                environment: ["PGPASSWORD": source.account.password]
            )
        }

        var arguments = [
            "--defaults-file=\(sourceOptions.path(percentEncoded: false))",
            "--single-transaction",
            "--routines",
            "--events",
            "--triggers",
            "--no-tablespaces",
            "--hex-blob",
            "--default-character-set=utf8mb4",
        ]

        // A MySQL dump of a server without GTIDs or histograms, such as MariaDB, fails without
        // these two settings.
        if kind == .mysql {
            arguments += ["--set-gtid-purged=OFF", "--column-statistics=0"]
        }

        return Command(executable: tools.dump, arguments: arguments + [database])
    }

    private func restoreCommand(_ name: String) -> Command {
        guard kind.usesMySQLProtocol else {
            return Command(
                executable: tools.bin("pg_restore"),
                arguments: ["-h", target.host, "-p", String(target.port), "-U", target.account.user, "-d", name, "--no-owner", "--no-privileges"],
                environment: ["PGPASSWORD": target.account.password]
            )
        }

        return Command(executable: tools.client, arguments: ["--defaults-file=\(targetOptions.path(percentEncoded: false))", "--default-character-set=utf8mb4", name])
    }

    private enum Side {
        case source
        case target
    }

    @discardableResult
    private func query(_ side: Side, _ sql: String, database: String? = nil) async throws -> String {
        let endpoint = side == .source ? source : target

        guard kind.usesMySQLProtocol else {
            let command = Command(
                executable: tools.client,
                arguments: ["-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", endpoint.host, "-p", String(endpoint.port), "-U", endpoint.account.user, "-d", database ?? "postgres", "-c", sql],
                environment: ["PGPASSWORD": endpoint.account.password]
            )
            return try await CommandRunner.run(command).trimmed
        }

        let options = side == .source ? sourceOptions : targetOptions
        let command = Command(
            executable: tools.client,
            arguments: ["--defaults-file=\(options.path(percentEncoded: false))", "-N", "-B", "-e", sql] + (database.map { [$0] } ?? [])
        )
        return try await CommandRunner.run(command).trimmed
    }
}
