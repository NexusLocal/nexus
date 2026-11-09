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

        // A database of a workspace has the name of the main database on a server of its own. So its
        // trash copy and its reservation get the name of the workspace too.
        let ownName: String

        if case .workspace(_, let workspace, _) = request.target {
            ownName = Workspace.databaseName(name, workspace: workspace)
        } else {
            ownName = name
        }

        let reserved = try reserveCopyTarget(ownName, on: instance, for: "import")
        defer { copyTargets.remove(reserved) }

        let exists = try await client.exists(name)

        if exists, request.existing == nil {
            throw DatabaseTargetExists(description: "\(name) exists on \(server) already. Add --replace-tables or --replace-database, or load the dump into another database with --into.")
        }

        let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)
        try copier.prepare()

        let trashCopy = exists ? try await writeDump(of: name, as: ownName, with: copier, instance: instance, kind: tools.kind) : nil

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
        let total = await Self.sqlSize(of: file, container: container)
        progress.update { $0.total = total }

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

        info.tables = try await sharedDumpTables(of: file, container: container, dump: info.dump, format: format)

        if let target = inspection.target, let name = inspection.name.flatMap({ try? DatabaseName.validated($0) }) {
            info.existingTables = await existingTables(of: name, on: target)
        }

        return info
    }

    // The sheet asks again at each change of the name or the instance, but the tables of the dump
    // stay the same. So one read of the file serves each question until the file changes, also the
    // questions that come while the read runs.
    private func sharedDumpTables(of file: URL, container: DumpContainer, dump: String?, format: DumpFormat?) async throws -> [String]? {
        let path = file.path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = [path, dump ?? "", String(size), String(modified)].joined(separator: "\n")

        if let running = dumpTableReads[key] {
            return try await running.value
        }

        let read = Task { try await self.dumpTables(of: file, container: container, dump: dump, format: format) }
        dumpTableReads = dumpTableReads.filter { !$0.key.hasPrefix(path + "\n") }
        dumpTableReads[key] = read

        do {
            return try await read.value
        } catch {
            dumpTableReads[key] = nil
            throw error
        }
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

    func archiveDumps(in file: URL, container: DumpContainer) async throws -> [String] {
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
    func dumpFormat(of file: URL, container: DumpContainer, dump: String?) async throws -> DumpFormat? {
        let script = "( \(container.readerScript(dump: dump)) ) 2>/dev/null | /usr/bin/head -c 65536; exit 0"
        let output = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/bash"), arguments: ["-c", script, "reader", file.path(percentEncoded: false)] + (dump.map { [$0] } ?? [])))

        return DumpFormat.of(start: Data(output.standardOutput.utf8))
    }

    private func load(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools, progress: TaskProgress) async throws {
        try await Self.pipe(plan, client: client, tools: tools) { done in
            progress.update { $0.completed = done }
        }
    }

    static func reader(of file: URL, container: DumpContainer, dump: String?) -> Command {
        Command(
            executable: URL(filePath: "/bin/bash"),
            arguments: ["-c", container.readerScript(dump: dump), "reader", file.path(percentEncoded: false)] + (dump.map { [$0] } ?? []),
            name: "the dump"
        )
    }

    // read gets the number of bytes of SQL that went to the client so far.
    static func pipe(_ plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools, read: @escaping @Sendable (Int64) -> Void) async throws {
        let reader = reader(of: plan.file, container: plan.container, dump: plan.dump)
        let counted = Mutex<Int64>(0)

        try await CommandRunner.pipe(reader, into: loader(for: plan, client: client, tools: tools)) { data in
            read(counted.withLock { value in
                value += Int64(data.count)
                return value
            })
        }
    }

    // The size of the SQL. gzip keeps the size of the original in its last 4 bytes, so a dump of 4 GB
    // or more gives a wrong number. That number is then smaller than the file, and it does not count.
    static func sqlSize(of file: URL, container: DumpContainer) async -> Int64? {
        let size = fileSize(file)

        switch container {
        case .plain:
            return size
        case .gzip:
            guard let output = try? await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/gzip"), arguments: ["-l", file.path(percentEncoded: false)])) else {
                return nil
            }

            let numbers = output.standardOutput.split(whereSeparator: \.isNewline).dropFirst().first?.split(separator: " ").compactMap { Int64($0) } ?? []

            guard numbers.count >= 2, let size, numbers[1] >= size else {
                return nil
            }

            return numbers[1]
        case .zip, .tar:
            return nil
        }
    }

    // A path of the setting: an empty value removes the file.
    static func workspaceDumpPath(_ value: String) throws -> String? {
        let path = (value.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath

        guard !path.isEmpty else {
            return nil
        }

        var isFolder: ObjCBool = false

        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw RuntimeError.unsupported("\(path) is no file. Choose a .sql or .sql.gz file, or a .zip, .tar or .tar.gz file with such a dump.")
        }

        return URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    }

    // The live URLs that a user adds to a WordPress dump. An empty list removes them.
    static func liveURLs(_ values: [String]) throws -> [String]? {
        var urls: [String] = []

        for value in values where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = WordPressURL.liveURL(value) else {
                throw RuntimeError.unsupported("\(value) is no URL of a site. Give a URL with http or https, for example https://staging.shop.com")
            }

            if !urls.contains(where: { WordPressURL.same($0, url) }) {
                urls.append(url)
            }
        }

        return urls.isEmpty ? nil : urls
    }

    // A new workspace with the choice dump (owner, 2026-11-09). Its database is empty already. A
    // failure says so in its first sentence, and the Site screen shows that sentence as the state.
    // A WordPress dump goes through the filter of its links. The report then names the tables that
    // WP-CLI must change after the load.
    @discardableResult
    func loadWorkspaceDump(_ file: URL, into name: String, tools: DatabaseTools, client: DatabaseClient, owner: String, links: SQLDumpFilter.Plan? = nil) async throws -> SQLDumpFilter.Report? {
        let path = file.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.gone) Nexus cannot find \(path). Choose the file again under Dump file, and then click Retry.")
        }

        let container = DumpContainer.of(file.lastPathComponent)
        let dumps = try await archiveDumps(in: file, container: container)

        guard !container.isArchive || dumps.count == 1 else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) \(file.lastPathComponent) has \(dumps.count) dumps. Choose a file with one dump under Dump file.")
        }

        let dump = container.isArchive ? dumps.first : nil
        let format = try await dumpFormat(of: file, container: container, dump: dump) ?? (tools.kind.usesMySQLProtocol ? .mysql : .postgresql)

        guard format.fits(tools.kind) else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) \(file.lastPathComponent) is a dump of \(format.displayName), and this database is on \(tools.kind.displayName).")
        }

        guard links == nil || format == .mysql else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) \(file.lastPathComponent) is a dump of \(format.displayName). WordPress needs a dump of MySQL or MariaDB.")
        }

        let report = FileManager.default.temporaryDirectory.appending(path: "nexus-dump-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: report) }

        let filter = try links.map { try DumpURLFilter(command: dumpFilterCommand(), plan: $0, report: report) }
        let plan = DumpLoad(file: file, container: container, dump: dump, format: format, name: name, replacesTables: false, links: filter)
        let total = await Self.sqlSize(of: file, container: container)
        let done = Mutex<Int64>(0)

        dumpProgress[owner] = WorkspaceDumpProgress(completed: 0, total: total)
        publishSites()

        let reporter = Task { [weak self] in
            while (try? await Task.sleep(for: .milliseconds(500))) != nil {
                await self?.reportDump(owner: owner, completed: done.withLock { $0 }, total: total)
            }
        }

        defer {
            reporter.cancel()
            dumpProgress[owner] = nil
            publishSites()
        }

        do {
            try await Self.pipe(plan, client: client, tools: tools) { bytes in
                done.withLock { $0 = bytes }
            }
        } catch {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) \(ErrorText.plain(error)) Retry makes the database of this workspace empty and loads the dump again.")
        }

        guard filter != nil else {
            return nil
        }

        guard let data = try? Data(contentsOf: report), let result = try? JSONDecoder().decode(SQLDumpFilter.Report.self, from: data) else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) The filter of the links wrote no report. Retry makes the database of this workspace empty and loads the dump again.")
        }

        return result
    }

    private func reportDump(owner: String, completed: Int64, total: Int64?) {
        guard dumpProgress[owner] != nil else {
            return
        }

        dumpProgress[owner] = WorkspaceDumpProgress(completed: completed, total: total)
        publishSites()
    }

    static func loader(for plan: DumpLoad, client: DatabaseClient, tools: DatabaseTools) -> Command {
        let endpoint = client.endpoint

        switch plan.format {
        case .mysql:
            let filter = [importFilter(prefix: nil, toMySQL: tools.kind == .mysql)] + (plan.replacesTables ? [replaceTablesFilter] : [])
            let links = plan.links.map { links in
                (#""$NEXUS_COMMAND" dump-filter --plan "$NEXUS_PLAN" --report "$NEXUS_REPORT" | "#, links.environment)
            }

            return Command(
                executable: URL(filePath: "/bin/bash"),
                arguments: ["-c", #"set -o pipefail; "# + (links?.0 ?? "") + #"LC_ALL=C /usr/bin/sed -E "$1" | "$2" "${@:3}""#, "load", filter.joined(separator: "\n"), tools.client.path(percentEncoded: false),
                            "--defaults-file=\(client.options.path(percentEncoded: false))", "--default-character-set=utf8mb4", "--init-command=\(importSession)", plan.name],
                environment: links?.1 ?? [:],
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
    var links: DumpURLFilter?
}

// nexus dump-filter between the reader and the client, with its plan and the file of its report.
struct DumpURLFilter: Sendable {
    let command: URL
    let plan: SQLDumpFilter.Plan
    let report: URL

    init(command: URL, plan: SQLDumpFilter.Plan, report: URL) throws {
        self.command = command
        self.plan = plan
        self.report = report
        planText = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    }

    private let planText: String

    var environment: [String: String] {
        ["NEXUS_COMMAND": command.path(percentEncoded: false), "NEXUS_PLAN": planText, "NEXUS_REPORT": report.path(percentEncoded: false)]
    }

    func arguments(writes: Bool) -> [String] {
        ["dump-filter", "--plan", planText, "--report", report.path(percentEncoded: false)] + (writes ? [] : ["--no-output"])
    }
}
