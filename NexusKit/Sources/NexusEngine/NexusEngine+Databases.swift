import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import Synchronization

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

    func databaseRuntimes() async -> [DatabaseTools] {
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
                account: try await account(of: tools),
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

        let account = try await account(of: tools)
        let output: CommandOutput
        do {
            output = try await initialize(tools, into: staging, account: account)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw RuntimeError.unsupported("Nexus could not make the data folder of \(tools.kind.displayName) \(line). \(error)")
        }

        try? FileManager.default.removeItem(at: data)
        try FileManager.default.moveItem(at: staging, to: data)
        try await stateStore.update { $0.databaseAccounts[tools.id] = account }

        writeToLog(of: tools.id, output.standardOutput + output.standardError)
    }

    static func holdsDatabase(_ folder: URL, kind: DatabaseKind) -> Bool {
        let marker = kind.usesMySQLProtocol ? "mysql" : "PG_VERSION"
        return FileManager.default.fileExists(atPath: folder.appending(path: marker).path(percentEncoded: false))
    }

    // Each way ends with the account on 127.0.0.1 (D35). A file with the password lives only
    // during the initialization. PostgreSQL cannot have an empty password. So a connection over
    // TCP needs no password when the account has none.
    private func initialize(_ tools: DatabaseTools, into folder: URL, account: DatabaseAccount) async throws -> CommandOutput {
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
            var arguments = [
                "-D", datadir,
                "-U", account.user,
                "--auth-local=trust",
                "--auth-host=\(PostgreSQLAccess.hostMethod(for: account))",
                "--encoding=UTF8",
                "--locale=en_US.UTF-8",
            ]

            if !account.password.isEmpty {
                try Self.writePrivate("\(account.password)\n", to: secret)
                arguments.append("--pwfile=\(secret.path(percentEncoded: false))")
            }

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
        let port = try await connectionPort(of: tools)
        let source = DatabaseEndpoint(host: request.source.host, port: request.source.port ?? tools.kind.standardPort, account: request.source.account)
        let target = DatabaseEndpoint(host: "127.0.0.1", port: port, account: try await account(of: tools))

        if source.isLocal, source.port == port, database == name {
            throw RuntimeError.unsupported("\(database) cannot be copied onto itself. Give the copy another name with --as.")
        }

        // The check and the insert have no wait between them. So two requests on the actor
        // cannot both pass.
        let copyTarget = "\(request.instance) \(name)"
        guard !copyTargets.contains(copyTarget) else {
            throw RuntimeError.unsupported("A copy into \(name) on \(request.instance) runs already. Wait until it ends, or stop it.")
        }

        guard !updatingServices.contains(request.instance) else {
            throw RuntimeError.unsupported("Nexus updates \(request.instance) now. Start the copy after the update.")
        }

        copyTargets.insert(copyTarget)
        defer { copyTargets.remove(copyTarget) }

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
        let replaces = try await copier.exists(name)

        if replaces, !request.replace {
            throw DatabaseTargetExists(description: "\(request.instance) has a database \(name) already. Add --replace to drop it and copy it again, or give the copy another name with --as.")
        }

        if replaces {
            try await copier.drop(name)
        }

        let task = TaskWork.copyDatabase(database: database, instance: request.instance, name: name)
        let stopped = replaces
            ? "The copy of \(database) stopped. \(request.instance) has no database \(name) now, because the copy dropped the old one first."
            : "The copy of \(database) stopped. \(request.instance) has no database \(name)."
        // The estimate runs next to the copy. So the copy does not wait for it.
        let copied = try await runTask(task, stopped: { stopped }) { progress in
            let estimating = Task {
                guard let estimate = try? await copier.estimate(database) else {
                    return
                }

                progress.update { values in
                    values.total = estimate.bytes
                    values.tableCount = estimate.tables
                }
            }
            defer { estimating.cancel() }

            return try await copier.copy(database, as: name, create: create, progress: progress)
        }

        let tables = Self.count(copied.tables, "table")
        let views = Self.count(copied.views, "view")
        let contents = copied.views > 0 ? "\(tables) and \(views)" : tables

        return """
            \(database) is copied from \(source.host):\(source.port) to \(request.instance) as \(name), with \(contents).
            Connect to port \(port) on 127.0.0.1 with the user \(target.account.user) and \(target.account.password.isEmpty ? "no password" : "the password \(target.account.password)").
            """
    }

    func databaseExists(_ name: String, on tools: DatabaseTools) async throws -> Bool {
        let (_, client, work) = try await runningClient(tools.id)
        defer { try? FileManager.default.removeItem(at: work) }

        return try await client.exists(try DatabaseName.validated(name))
    }
}

// The copy stopped before it wrote anything, because a database has its name already.
struct DatabaseTargetExists: Error, CustomStringConvertible {
    let description: String
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
    private let sourceClient: DatabaseClient
    private let targetClient: DatabaseClient

    init(tools: DatabaseTools, source: DatabaseEndpoint, target: DatabaseEndpoint, work: URL) {
        self.tools = tools
        sourceClient = DatabaseClient(tools: tools, endpoint: source, options: work.appending(path: "source.cnf"))
        targetClient = DatabaseClient(tools: tools, endpoint: target, options: work.appending(path: "target.cnf"))
    }

    private var source: DatabaseEndpoint { sourceClient.endpoint }
    private var target: DatabaseEndpoint { targetClient.endpoint }
    private var sourceOptions: URL { sourceClient.options }
    private var targetOptions: URL { targetClient.options }
    private var kind: DatabaseKind { tools.kind }

    func prepare() throws {
        try sourceClient.prepare()
        try targetClient.prepare()
    }

    func exists(_ name: String) async throws -> Bool {
        try await targetClient.exists(name)
    }

    func drop(_ name: String) async throws {
        let sql = kind.usesMySQLProtocol
            ? "DROP DATABASE \(DatabaseConfig.identifier(name, kind: kind))"
            : "DROP DATABASE \(DatabaseConfig.identifier(name, kind: kind)) WITH (FORCE)"

        try await query(.target, sql)
    }

    // Returns the number of tables and views in the copy. A copy that fails or stops is dropped,
    // so no half database stays behind. The drop runs in a task of its own, because a stopped
    // task stops each program that it starts. A create that fails drops nothing, because the
    // database with that name is then not the copy. A create that stops can be done already.
    func copy(_ database: String, as name: String, create: String, progress: TaskProgress? = nil) async throws -> (tables: Int, views: Int) {
        var created = false

        do {
            try await query(.target, create)
            created = true

            var observer: (@Sendable (Data) -> Void)?
            if let progress {
                let watcher = DumpWatcher(progress: progress, namesTables: kind.usesMySQLProtocol)
                observer = { watcher.read($0) }
            }

            try await CommandRunner.pipe(dumpCommand(database), into: restoreCommand(name), observer: observer)
        } catch {
            if created || error is CancellationError {
                await Task { try? await drop(name) }.value
            }

            throw error
        }

        // The copy is complete here. So a stop does not stop the count.
        let counts = try await Task { try await query(.target, countStatement, database: name) }.value
            .split(separator: "\t")
            .compactMap { Int($0) }
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

    // The size of the data of the tables on the other server and their number, for the
    // progress of the copy. The indexes are left out, because a dump has no index data.
    func estimate(_ database: String) async throws -> (bytes: Int64, tables: Int) {
        let answer = kind.usesMySQLProtocol
            ? try await sourceClient.queryWithCurrentSizes("SELECT COALESCE(SUM(DATA_LENGTH), 0), COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(database)' AND TABLE_TYPE = 'BASE TABLE'")
            : try await query(.source, "SELECT COALESCE(SUM(pg_table_size(c.oid)), 0), COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'", database: database)

        let values = answer.split(separator: "\t").map(String.init)
        guard values.count == 2, let bytes = Int64(values[0]), let tables = Int(values[1]) else {
            throw RuntimeError.unsupported("Nexus cannot read the size of \(database): \(answer)")
        }

        return (bytes, tables)
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
                // Without compression, the bytes of the dump compare with the size of the tables.
                // The dump goes only through a pipe on this Mac.
                arguments: ["-h", source.host, "-p", String(source.port), "-U", source.account.user, "-d", database, "-Fc", "-Z", "0", "--no-owner", "--no-privileges"],
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
        try await (side == .source ? sourceClient : targetClient).query(sql, database: database)
    }
}

// Counts the bytes of a dump for the progress of a copy. A dump of MySQL or MariaDB starts each
// table with a comment line that names it. A part of the dump can end inside that line. So the
// watcher keeps the end of each part for the next one.
final class DumpWatcher: Sendable {
    private static let marker = Data("\n-- Table structure for table `".utf8)
    private static let kept = marker.count + 256

    private let progress: TaskProgress
    private let namesTables: Bool
    private let rest = Mutex(Data())

    init(progress: TaskProgress, namesTables: Bool) {
        self.progress = progress
        self.namesTables = namesTables
    }

    func read(_ part: Data) {
        guard namesTables else {
            progress.update { $0.completed += Int64(part.count) }
            return
        }

        let tables = rest.withLock { rest in
            let data = rest + part
            var tables: [String] = []
            var searchFrom = data.startIndex
            var keepFrom = max(data.startIndex, data.endIndex - Self.kept)

            while let marker = data.range(of: Self.marker, in: searchFrom..<data.endIndex) {
                guard let end = data[marker.upperBound...].firstIndex(of: UInt8(ascii: "`")) else {
                    keepFrom = min(keepFrom, marker.lowerBound)
                    break
                }

                tables.append(String(decoding: data[marker.upperBound..<end], as: UTF8.self))
                searchFrom = end
            }

            rest = Data(data[max(keepFrom, searchFrom)...])
            return tables
        }

        progress.update { values in
            values.completed += Int64(part.count)

            guard let last = tables.last else {
                return
            }

            values.table = last
            values.tableNumber = (values.tableNumber ?? 0) + tables.count
        }
    }
}
