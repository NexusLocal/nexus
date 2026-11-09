import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import Synchronization

// The dump file of a WordPress site (owner, 2026-11-09, docs/dump-url-rewrite.md). The links of the
// live site change in the SQL while the dump loads into a new workspace. The check of the file
// finds the live URLs first, because wp_options often comes after wp_comments in a dump.
extension NexusEngine {
    // nexusd links bin/nexus to the nexus command of its own build at each start.
    func dumpFilterCommand() throws -> URL {
        let command = paths.bin.appending(path: "nexus").resolvingSymlinksInPath()

        guard FileManager.default.isExecutableFile(atPath: command.path(percentEncoded: false)) else {
            throw RuntimeError.unsupported("Nexus cannot find its nexus command, so it cannot change the links of the dump. Quit Nexus, and open it again.")
        }

        return command
    }

    // A check that fails before it reads the file, for example without the file, shows its reason on
    // the Site screen until the next check.
    func checkWordPressDumpSoon(_ host: String) {
        Task {
            do {
                try await wordPressDumpCheck(host: host)
            } catch {
                dumpCheckFailures[host] = ErrorText.plain(error)
                publishSites()
            }
        }
    }

    func shownDumpCheck(of site: Site) -> WordPressDumpCheck? {
        guard let failure = dumpCheckFailures[site.host], let path = site.workspaceDump else {
            return site.workspaceDumpCheck
        }

        return WordPressDumpCheck(file: path, size: 0, modified: 0, prefix: "", addedURLs: [], problem: failure)
    }

    // A check that fits the file comes back at once. A check that runs now is shared, so a new
    // workspace waits for it.
    @discardableResult
    func wordPressDumpCheck(host: String) async throws -> WordPressDumpCheck {
        if let running = dumpChecks[host] {
            return try await running.value
        }

        dumpCheckFailures[host] = nil

        guard let site = await stateStore.current().sites.first(where: { $0.host == host }), let path = site.workspaceDump else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.gone) \(host) has no dump file. Choose one under Dump file, and then click Retry.")
        }

        let target = try await wordPressTarget(host)

        guard let prefix = target.config?.safeTablePrefix else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) Nexus cannot read the table prefix of \(host) in \(target.configName). So it cannot find the tables of the site in the dump.")
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.gone) Nexus cannot find \(path). Choose the file again under Dump file, and then click Retry.")
        }

        let added = site.workspaceDumpURLs ?? []

        if let check = site.workspaceDumpCheck, check.fits(file: path, size: size, modified: modified, prefix: prefix, addedURLs: added) {
            return check
        }

        if let running = dumpChecks[host] {
            return try await running.value
        }

        // The task is in place before the next await. So a second caller waits for this check.
        let task = Task {
            let columns = await self.postsColumns(of: target, prefix: prefix)
            let file = WordPressDumpFile(path: path, size: size, modified: modified, prefix: prefix, addedURLs: added, postsColumns: columns)

            return try await self.runWordPressDumpCheck(file, host: host)
        }

        dumpChecks[host] = task
        dumpCheckProgress[host] = WorkspaceDumpProgress(completed: 0, total: nil)
        publishSites()

        defer {
            dumpChecks[host] = nil
            dumpCheckProgress[host] = nil
            publishSites()
        }

        let check = try await task.value

        try await stateStore.update { state in
            if let index = state.sites.firstIndex(where: { $0.host == host }), state.sites[index].workspaceDump == path {
                state.sites[index].workspaceDumpCheck = check
            }
        }

        return check
    }

    typealias WorkspaceDumpSource = @Sendable () async throws -> (file: URL, links: WorkspaceDumpLinks?)

    // What the load of a WordPress dump needs: the plan of the filter, and the URLs that WP-CLI
    // changes in the tables that the filter did not change.
    struct WorkspaceDumpLinks: Sendable {
        let plan: SQLDumpFilter.Plan
        let fallbackURLs: [String]
        let to: String
    }

    struct WordPressDumpFile: Sendable {
        let path: String
        let size: Int64
        let modified: Double
        let prefix: String
        let addedURLs: [String]
        let postsColumns: [String: [String]]
    }

    // Two reads of the file: the first finds the tables and the live URLs, the second counts the
    // links and finds the values that the filter cannot change. A network changes its links with
    // WP-CLI after the load in the first version, so it needs no second read.
    private func runWordPressDumpCheck(_ dumpFile: WordPressDumpFile, host: String) async throws -> WordPressDumpCheck {
        let file = URL(filePath: dumpFile.path, directoryHint: .notDirectory)
        let container = DumpContainer.of(file.lastPathComponent)
        let dumps = try await archiveDumps(in: file, container: container)
        let check = { (problem: String?, report: SQLDumpFilter.Report?, counted: SQLDumpFilter.Report?) in
            WordPressDumpCheck(
                file: dumpFile.path,
                size: dumpFile.size,
                modified: dumpFile.modified,
                prefix: dumpFile.prefix,
                addedURLs: dumpFile.addedURLs,
                home: report?.home,
                siteURL: report?.siteURL,
                isNetwork: report.map { $0.hasTable(dumpFile.prefix + "blogs") && $0.hasTable(dumpFile.prefix + "site") } ?? false,
                networkDomain: report?.networkDomain,
                links: counted?.links ?? 0,
                uncertainTables: counted?.uncertainTables ?? [],
                uncertainLinks: counted?.uncertainLinks ?? 0,
                postsColumns: dumpFile.postsColumns,
                problem: problem
            )
        }

        guard !container.isArchive || dumps.count == 1 else {
            return check("\(file.lastPathComponent) has \(dumps.count) dumps. Choose a file with one dump.", nil, nil)
        }

        let dump = container.isArchive ? dumps.first : nil

        if let format = try await dumpFormat(of: file, container: container, dump: dump), format != .mysql {
            return check("\(file.lastPathComponent) is a dump of \(format.displayName). WordPress needs a dump of MySQL or MariaDB.", nil, nil)
        }

        let source = (file: file, container: container, dump: dump, total: await Self.sqlSize(of: file, container: container))
        let found = try await dumpFilterReport(source, plan: SQLDumpFilter.Plan(prefix: dumpFile.prefix, columns: dumpFile.postsColumns), part: 0, host: host)

        guard found.hasTable(dumpFile.prefix + "options") else {
            return check("The dump has no tables with the prefix \(dumpFile.prefix) of this site.", found, nil)
        }

        guard let home = found.home else {
            return check("The dump has no option home in \(dumpFile.prefix)options.", found, nil)
        }

        let workspace = "https://workspace.invalid"

        if let unreadable = LiveURLRewriter.unreadable([home, found.siteURL].compactMap { $0 }.map { LiveURLRule(from: $0, to: workspace) }).first {
            return check("The dump has the URL \(unreadable.from) in \(dumpFile.prefix)options. Nexus cannot read it as the URL of a site.", found, nil)
        }

        let first = check(nil, found, nil)

        guard !first.isNetwork else {
            return first
        }

        // The URL of the workspace does not change the count. Only the rules of the live URLs do.
        let siteURL = first.siteURL.flatMap { WordPressDumpCheck.suffix(of: $0, below: home) }.map { workspace + $0 } ?? workspace
        let counted = try await dumpFilterReport(source, plan: SQLDumpFilter.Plan(prefix: dumpFile.prefix, rules: first.rules(home: workspace, siteURL: siteURL), columns: dumpFile.postsColumns), part: 1, host: host)

        return check(nil, found, counted)
    }

    private func dumpFilterReport(_ source: (file: URL, container: DumpContainer, dump: String?, total: Int64?), plan: SQLDumpFilter.Plan, part: Int64, host: String) async throws -> SQLDumpFilter.Report {
        let report = FileManager.default.temporaryDirectory.appending(path: "nexus-dump-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: report) }

        let filter = try DumpURLFilter(command: dumpFilterCommand(), plan: plan, report: report)
        let reader = Self.reader(of: source.file, container: source.container, dump: source.dump)
        let command = Command(executable: filter.command, arguments: filter.arguments(writes: false), name: "nexus dump-filter")
        let done = Mutex<Int64>(0)
        let total = source.total

        let reporter = Task { [weak self] in
            while (try? await Task.sleep(for: .milliseconds(500))) != nil {
                let read = done.withLock { $0 }
                await self?.reportDumpCheck(host: host, progress: WorkspaceDumpProgress(completed: (total ?? 0) * part + read, total: total.map { $0 * 2 }))
            }
        }

        defer { reporter.cancel() }

        try await CommandRunner.pipe(reader, into: command) { data in
            done.withLock { $0 += Int64(data.count) }
        }

        return try JSONDecoder().decode(SQLDumpFilter.Report.self, from: Data(contentsOf: report))
    }

    private func reportDumpCheck(host: String, progress: WorkspaceDumpProgress) {
        guard dumpCheckProgress[host] != nil else {
            return
        }

        dumpCheckProgress[host] = progress
        publishSites()
    }

    // The order of the columns of the posts table in the main database. A dump of
    // mysqldump --no-create-info has no CREATE TABLE, and guid must not change. The posts tables of
    // the sites of a network have the same columns, so the filter uses this order for them too.
    private func postsColumns(of target: WordPressTarget, prefix: String) async -> [String: [String]] {
        guard let config = target.config, let name = config.database, let port = config.address?.localPort,
              let instance = await mysqlInstances().first(where: { $0.port == port && $0.running }),
              let (_, client, work) = try? await runningClient(instance.id) else {
            return [:]
        }

        defer { try? FileManager.default.removeItem(at: work) }

        let table = prefix + "posts"
        let rows = (try? await client.rows("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(Self.sqlText(name)) AND TABLE_NAME = \(Self.sqlText(table)) ORDER BY ORDINAL_POSITION")) ?? []
        let columns = rows.compactMap(\.first)

        return columns.isEmpty ? [:] : [table: columns]
    }

    // The check of the WordPress site of a workspace, before its load. A problem of the dump stops
    // the setup with the text of a dump that did not load.
    func workspaceDumpCheck(key: String) async throws -> WordPressDumpCheck {
        let sites = resolvedSites(await stateStore.current()).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }

        guard let site = sites.first(where: { $0.workspaceDump != nil }) else {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.gone) This site has no dump file. Choose one under Dump file, and then click Retry.")
        }

        let check = try await wordPressDumpCheck(host: site.host)

        if let problem = check.problem {
            throw RuntimeError.unsupported("\(WorkspaceDumpText.failed) \(problem)")
        }

        return check
    }
}
