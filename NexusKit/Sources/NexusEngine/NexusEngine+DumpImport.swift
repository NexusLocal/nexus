import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import Synchronization

// nexus db import and a dump file in the sheet "Import a database" (owner, 2026-11-09). A new
// database that fails is dropped, as after a copy. A database that exists changes only after a
// choice, and Nexus puts a copy of it in the trash first.
extension NexusEngine {
    func importDump(_ request: DumpImport) async throws -> String {
        let file = URL(filePath: request.file, directoryHint: .notDirectory)
        let fileName = file.lastPathComponent

        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            throw RuntimeError.unsupported("\(file.path(percentEncoded: false)) does not exist.")
        }

        let container = DumpContainer.of(fileName)
        let dump = try await chosenDump(in: file, container: container, wanted: request.dump)
        let name = try DatabaseName.validated(request.name)
        let instance = request.target.instanceID
        let server = request.target.serverName

        if case .instance = request.target, await supervisor.state(of: instance)?.isActive != true {
            _ = try await serialWeb { try await self.start(instance) }
        }

        let (tools, client, work) = try await client(for: request.target)
        defer { try? FileManager.default.removeItem(at: work) }

        try client.prepare()

        let format = try await dumpFormat(of: file, container: container, dump: dump) ?? (tools.kind.usesMySQLProtocol ? .mysql : .postgresql)
        let shownName = dump.map { "\(fileName) (\($0))" } ?? fileName

        guard format.fits(tools.kind) else {
            throw RuntimeError.unsupported("\(shownName) is a dump of \(format.displayName). Choose an instance of \(format.displayName).")
        }

        if request.existing == .replaceTables, format == .postgresql {
            throw RuntimeError.unsupported("Nexus can replace only the tables of a PostgreSQL dump of pg_dump -Fc. For \(shownName), replace the whole database.")
        }

        let reserved = try reserveCopyTarget(name, on: instance, for: "import")
        defer { copyTargets.remove(reserved) }

        let exists = try await client.exists(name)

        if exists, request.existing == nil {
            throw DatabaseTargetExists(description: "\(name) exists on \(server) already. Add --replace-tables or --replace-database, or load the dump into another database with --into.")
        }

        let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)
        try copier.prepare()

        let trashCopy = exists ? try await writeDump(of: name, as: name, with: copier, instance: instance, kind: tools.kind) : nil

        if exists, request.existing == .replaceDatabase {
            try await copier.drop(name)
        }

        let createsDatabase = !exists || request.existing == .replaceDatabase

        if createsDatabase {
            let identifier = DatabaseConfig.identifier(name, kind: tools.kind)
            try await client.query(tools.kind.usesMySQLProtocol ? "CREATE DATABASE \(identifier)" : "CREATE DATABASE \(identifier) TEMPLATE template0")
        }

        let keptCopy = trashCopy.map { " Nexus put a copy of the old \(name) in the trash: \($0.lastPathComponent)." } ?? ""
        let plan = DumpLoad(file: file, container: container, dump: dump, format: format, name: name, replacesTables: request.existing == .replaceTables)
        let progress = TaskProgress()
        progress.update { $0.total = container == .plain ? Self.fileSize(file) : nil }

        do {
            try await runTask(.importDump(file: fileName, instance: instance, name: name), progress: progress, stopped: {
                exists ? "The import of \(shownName) stopped. \(name) can be incomplete.\(keptCopy)" : "The import of \(shownName) stopped. \(server) has no database \(name)."
            }) { progress in
                try await self.load(plan, client: client, tools: tools, progress: progress)
            }
        } catch {
            if !exists {
                await Task { try? await copier.drop(name) }.value
            }

            guard exists else {
                throw error
            }

            throw RuntimeError.unsupported("The dump did not load completely. \(ErrorText.plain(error))\(keptCopy)")
        }

        switch request.existing {
        case nil:
            return "\(shownName) is loaded into the new database \(name) on \(server)."
        case .replaceTables:
            return "\(shownName) is loaded into \(name) on \(server). The tables of the dump replaced their old tables. The other tables stay as they were.\(keptCopy)"
        case .replaceDatabase:
            return "\(shownName) replaced the database \(name) on \(server).\(keptCopy)"
        }
    }

    // What the sheet shows before the import: the dumps of an archive, the kind, the tables of the
    // dump, and the tables of the database when it exists. A problem is an answer, not an error. So
    // the sheet can show it under the file.
    func inspectDump(_ inspection: DumpInspection) async throws -> DumpInfo {
        let file = URL(filePath: inspection.file, directoryHint: .notDirectory)
        let fileName = file.lastPathComponent

        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return DumpInfo(problem: "\(file.path(percentEncoded: false)) does not exist.")
        }

        let container = DumpContainer.of(fileName)
        let dumps = try await archiveDumps(in: file, container: container)
        var info = DumpInfo(dumps: dumps, bytes: Self.fileSize(file) ?? 0)

        if container.isArchive, dumps.isEmpty {
            info.problem = "\(fileName) has no .sql file. Choose a .sql or .sql.gz file, or an archive with such a file."
            return info
        }

        info.dump = container.isArchive ? inspection.dump.flatMap { dumps.contains($0) ? $0 : nil } ?? (dumps.count == 1 ? dumps[0] : nil) : nil

        if container.isArchive, info.dump == nil {
            return info
        }

        let format = try await dumpFormat(of: file, container: container, dump: info.dump)
        info.format = format

        if let target = inspection.target, let format, let kind = await databaseRuntime(target.instanceID)?.kind, !format.fits(kind) {
            info.problem = "\(info.dump.map { "\(fileName) (\($0))" } ?? fileName) is a dump of \(format.displayName). Choose an instance of \(format.displayName)."
            return info
        }

        info.tables = try await dumpTables(of: file, container: container, dump: info.dump, format: format)

        if let target = inspection.target, let name = inspection.name.flatMap({ try? DatabaseName.validated($0) }) {
            info.existingTables = await existingTables(of: name, on: target)
        }

        return info
    }

    // The names of the tables that the dump makes, in their order. A file of pg_dump -Fc has a
    // binary list. Nexus does not read it, so the sheet then names no tables.
    private func dumpTables(of file: URL, container: DumpContainer, dump: String?, format: DumpFormat?) async throws -> [String]? {
        let pattern: String

        switch format {
        case .mysql, nil:
            pattern = "^CREATE TABLE (IF NOT EXISTS )?`[^`]+`"
        case .postgresql:
            pattern = "^CREATE TABLE [^ (]+"
        case .postgresqlCustom:
            return nil
        }

        let script = "( \(container.readerScript(dump: dump)) ) 2>/dev/null | LC_ALL=C /usr/bin/grep -E -o \"$PATTERN\"; exit 0"
        let output = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/bash"), arguments: ["-c", script, "reader", file.path(percentEncoded: false)] + (dump.map { [$0] } ?? []), environment: ["PATTERN": pattern]))

        return Self.tableNames(in: output.standardOutput)
    }

    static func tableNames(in lines: String) -> [String] {
        var names: [String] = []

        for line in lines.split(whereSeparator: \.isNewline) {
            let last = line.split(separator: " ").last.map(String.init) ?? ""
            let name = last.trimmingCharacters(in: CharacterSet(charactersIn: "`\"")).replacingOccurrences(of: "public.", with: "")

            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }

        return names
    }

    // nil when the database does not exist, or when its server does not answer.
    private func existingTables(of name: String, on target: DatabaseTarget) async -> [String]? {
        guard let connection = try? await client(for: target) else {
            return nil
        }

        let (tools, client, work) = connection
        defer { try? FileManager.default.removeItem(at: work) }

        guard (try? client.prepare()) != nil, (try? await client.exists(name)) == true else {
            return nil
        }

        let mysql = tools.kind.usesMySQLProtocol
        let sql = mysql
            ? "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(name)' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME"
            : "SELECT tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY tablename"
        let output = (try? await client.query(sql, database: mysql ? nil : name)) ?? ""

        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func archiveDumps(in file: URL, container: DumpContainer) async throws -> [String] {
        guard let list = container.listArguments else {
            return []
        }

        let output = try await CommandRunner.run(Command(executable: URL(filePath: list[0]), arguments: Array(list.dropFirst()) + [file.path(percentEncoded: false)]))
        return DumpArchive.dumps(in: output.standardOutput.split(whereSeparator: \.isNewline).map(String.init))
    }

    // A plain archive has one dump. With more than one, the request names it.
    private func chosenDump(in file: URL, container: DumpContainer, wanted: String?) async throws -> String? {
        guard container.isArchive else {
            return nil
        }

        let dumps = try await archiveDumps(in: file, container: container)
        let archive = file.lastPathComponent

        if let wanted {
            guard dumps.contains(wanted) else {
                throw RuntimeError.unsupported("\(archive) has no dump \(wanted). It has: \(dumps.joined(separator: ", ")).")
            }

            return wanted
        }

        guard let first = dumps.first else {
            throw RuntimeError.unsupported("\(archive) has no .sql file. Choose a .sql or .sql.gz file, or an archive with such a file.")
        }

        guard dumps.count == 1 else {
            throw RuntimeError.unsupported("\(archive) has \(dumps.count) dumps: \(dumps.joined(separator: ", ")). Choose one with --dump.")
        }

        return first
    }

    // The first 64 KB tell the kind of the dump. The reader stops early, so its own error does not
    // count.
    private func dumpFormat(of file: URL, container: DumpContainer, dump: String?) async throws -> DumpFormat? {
        let script = "( \(container.readerScript(dump: dump)) ) 2>/dev/null | /usr/bin/head -c 65536; exit 0"
        let output = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/bash"), arguments: ["-c", script, "reader", file.path(percentEncoded: false)] + (dump.map { [$0] } ?? [])))

        return DumpFormat.of(start: Data(output.standardOutput.utf8))
    }

    private func load(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools, progress: TaskProgress) async throws {
        let reader = Command(
            executable: URL(filePath: "/bin/bash"),
            arguments: ["-c", plan.container.readerScript(dump: plan.dump), "reader", plan.file.path(percentEncoded: false)] + (plan.dump.map { [$0] } ?? []),
            name: "the dump"
        )
        let counted = Mutex<Int64>(0)

        try await CommandRunner.pipe(reader, into: Self.loader(for: plan, client: client, tools: tools)) { data in
            let done = counted.withLock { value in
                value += Int64(data.count)
                return value
            }

            progress.update { $0.completed = done }
        }
    }

    static func loader(for plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools) -> Command {
        let endpoint = client.endpoint

        switch plan.format {
        case .mysql:
            let filter = [importFilter(prefix: nil, toMySQL: tools.kind == .mysql)] + (plan.replacesTables ? [replaceTablesFilter] : [])

            return Command(
                executable: URL(filePath: "/bin/bash"),
                arguments: ["-c", #"set -o pipefail; LC_ALL=C /usr/bin/sed -E "$1" | "$2" "${@:3}""#, "load", filter.joined(separator: "\n"), tools.client.path(percentEncoded: false),
                            "--defaults-file=\(client.options.path(percentEncoded: false))", "--default-character-set=utf8mb4", "--init-command=\(importSession)", plan.name],
                name: tools.client.lastPathComponent
            )
        case .postgresql:
            return Command(
                executable: URL(filePath: "/bin/bash"),
                arguments: ["-c", #"set -o pipefail; LC_ALL=C /usr/bin/sed -E "$1" | "$2" "${@:3}""#, "load", postgresFilter, tools.client.path(percentEncoded: false),
                            "-X", "-q", "-v", "ON_ERROR_STOP=1", "-h", endpoint.host, "-p", String(endpoint.port), "-U", endpoint.account.user, "-d", plan.name],
                environment: ["PGPASSWORD": endpoint.account.password],
                name: "psql"
            )
        case .postgresqlCustom:
            return Command(
                executable: tools.bin("pg_restore"),
                arguments: ["--no-owner", "--no-privileges", "-h", endpoint.host, "-p", String(endpoint.port), "-U", endpoint.account.user, "-d", plan.name] + (plan.replacesTables ? ["--clean", "--if-exists"] : []),
                environment: ["PGPASSWORD": endpoint.account.password]
            )
        }
    }

    // A dump of mysqldump drops each table before it makes it again. Another tool can leave that
    // out. Then the CREATE TABLE fails on a table that exists, or IF NOT EXISTS keeps the old rows
    // next to the new ones. So each table of the dump goes first, also when the dump drops it too.
    static let replaceTablesFilter = #"s/^CREATE TABLE (IF NOT EXISTS )?(`[^`]+`)/DROP TABLE IF EXISTS \2; CREATE TABLE \2/I"#

    // A plain dump of PostgreSQL can connect to another database, make one, or give objects to
    // roles that this server does not have. pg_dump 17 writes transaction_timeout, which older
    // servers do not know.
    static let postgresFilter = #"/^\\connect /d; /^CREATE DATABASE /Id; /^ALTER .* OWNER TO .*;$/d; /^(GRANT|REVOKE) /d; /^SET transaction_timeout /d"#

    private static func fileSize(_ file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
    }
}

struct DumpLoad: Sendable {
    let file: URL
    let container: DumpContainer
    let dump: String?
    let format: DumpFormat
    let name: String
    let replacesTables: Bool
}
