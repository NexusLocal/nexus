import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

// The move from Local by WP Engine (group 11, docs/group11-local.md). nexusd reads the files of
// Local and changes nothing in them. A database of a site that runs comes through the socket of its
// server. For a stopped site, Nexus reads a copy of its data folder with its own server. The sites
// stay in their folders and keep their names, for example blog.local.
extension NexusEngine {
    static let localPackages: Set<String> = ["php", "mysql", "mariadb", "httpd", "wp-cli"]

    func localMovePlan(home: URL) async -> HerdMovePlan? {
        guard let setup = LocalReader.read(home: home) else {
            return nil
        }

        return LocalMovePlanner.plan(setup: setup, facts: await localMoveFacts(setup: setup, home: home))
    }

    func localMoveFacts(setup: LocalSetup, home: URL) async -> LocalMoveFacts {
        let manifest = try? await manifest()
        var offered: [String: [String]] = [:]
        var bytes: [String: Int64] = [:]

        for package in manifest?.packages ?? [] where Self.localPackages.contains(package.name) {
            offered[package.name, default: []].append(package.line)
            bytes["\(package.name)-\(package.line)"] = package.size.map(Int64.init)
        }

        let installed = await installer.installedRuntimes()

        for runtime in installed where Self.localPackages.contains(runtime.name) && !(offered[runtime.name] ?? []).contains(runtime.line) {
            offered[runtime.name, default: []].append(runtime.line)
        }

        offered = offered.mapValues { lines in Array(Set(lines)).sorted { VersionLine.isOlder($0, than: $1) } }

        let state = await stateStore.current()
        let sites = setup.sites
        let files = await onOwnThread { Self.localSiteFiles(sites, home: home) }

        return LocalMoveFacts(
            home: home,
            localRuns: Self.isRunning(.local),
            offered: offered,
            installed: Set(installed.map { "\($0.name)-\($0.line)" }),
            packageBytes: bytes,
            running: files.running,
            dataBytes: files.dataBytes,
            dumpDates: files.dumpDates,
            hasDataFolder: files.hasDataFolder,
            hasWPConfig: files.hasWPConfig,
            hasEnvrc: files.hasEnvrc,
            direnv: files.direnv,
            trusted: files.trusted,
            nexusHosts: Set(resolvedSites(state).flatMap(\.site.hosts)),
            nexusSiteCount: resolvedSites(state).count,
            nexusTLD: state.tld
        )
    }

    struct LocalSiteFiles: Sendable {
        var running: Set<String> = []
        var dataBytes: [String: Int64] = [:]
        var dumpDates: [String: Date] = [:]
        var hasDataFolder: Set<String> = []
        var hasWPConfig: Set<String> = []
        var hasEnvrc: Set<String> = []
        var direnv = false
        var trusted: Set<String> = []
    }

    // The files of each site, and the servers that answer. It reads only, and it runs on its own
    // thread, because a large data folder takes a while.
    static func localSiteFiles(_ sites: [LocalSetup.Site], home: URL) -> LocalSiteFiles {
        let manager = FileManager.default
        var files = LocalSiteFiles()

        for site in sites {
            if UnixSocket.answers(site.socket.path(percentEncoded: false)) {
                files.running.insert(site.id)
            }

            let data = site.dataFolder

            if manager.fileExists(atPath: data.appending(path: "mysql").path(percentEncoded: false)) {
                files.hasDataFolder.insert(site.id)
                files.dataBytes[site.id] = folderSize(data)
            }

            if let date = (try? manager.attributesOfItem(atPath: site.dump.path(percentEncoded: false)))?[.modificationDate] as? Date {
                files.dumpDates[site.id] = date
            }

            if manager.fileExists(atPath: site.wpConfig.path(percentEncoded: false)) {
                files.hasWPConfig.insert(site.id)
            }

            if manager.fileExists(atPath: site.envrc.path(percentEncoded: false)) {
                files.hasEnvrc.insert(site.id)
            }

            let certificate = site.runFolder.deletingLastPathComponent().appending(path: "router/nginx/certs/\(site.domain).crt")

            if manager.fileExists(atPath: certificate.path(percentEncoded: false)), programStatus("/usr/bin/security", ["find-certificate", "-c", site.domain, "/Library/Keychains/System.keychain"]) == 0 {
                files.trusted.insert(site.domain)
            }
        }

        files.direnv = hasDirenv(home: home)
        return files
    }

    // direnv changes the PATH in a folder with .envrc only when the shell loads its hook.
    static func hasDirenv(home: URL) -> Bool {
        let shellFiles = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".config/fish/config.fish"].map { home.appending(path: $0) }

        return shellFiles.contains { file in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("direnv hook")
        }
    }

    static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0

        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }

        return total
    }

    static func programStatus(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        return process.terminationStatus
    }

    // Local runs as an app. Its router and the servers of its sites stop some seconds after it quits.
    // A helper of Local stays 10 seconds longer and then kills each process with "Local Sites" in its
    // command line, also WP-CLI of Nexus with --path (seen in the VM, 2026-11-26). So each process
    // in Local.app counts.
    static func localRuns() -> Bool {
        runningExecutables().contains { path in
            path.contains("/Local.app/Contents/")
                || path.contains("/Application Support/Local/lightning-services/")
        }
    }

    // MARK: The move

    func moveFromLocal(_ request: HerdMoveRequest, home: URL) async throws -> String {
        guard let setup = LocalReader.read(home: home) else {
            throw RuntimeError.unsupported("Nexus found no Local on this Mac. Nexus changed nothing.")
        }

        let facts = await localMoveFacts(setup: setup, home: home)
        let plan = LocalMovePlanner.applying(request, to: LocalMovePlanner.plan(setup: setup, facts: facts), facts: facts)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let report = paths.moves.appending(path: "local-\(formatter.string(from: .now))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report.appending(path: "copies"), withIntermediateDirectories: true)

        let log = report.appending(path: "move.log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let record = HerdMoveRecord()
        let steps = localMoveSteps(plan, setup: setup, report: report, log: log, record: record)
        let progress = TaskProgress()
        progress.update { values in
            values.steps = steps.map { TaskStep(title: $0.title) }
            values.logFile = log
        }

        do {
            try await runTask(.moveFromHerd, id: Self.herdMoveTaskID, progress: progress, stopped: {
                "The move from Local stopped. Local still has your sites. The report is in \(report.path(percentEncoded: false))."
            }) { progress in
                for (index, step) in steps.enumerated() {
                    try Task.checkCancellation()
                    progress.start(step: index)
                    Self.appendLine("== \(step.title)", to: log)
                    try await step.run()
                }

                progress.finishSteps()
            }
        } catch {
            progress.failRunningStep()
            Self.writeHerdReport(plan: plan, record: record, failure: ErrorText.plain(error), home: home, to: report)
            throw error
        }

        Self.writeHerdReport(plan: plan, record: record, failure: nil, home: home, to: report)

        let databases = plan.databases.isEmpty ? "" : " and \(Count.text(plan.databases.count, "database"))"
        return "Nexus moved \(Count.text(plan.sites.count, "site"))\(databases) from Local. The report is in \(report.appending(path: "report.md").path(percentEncoded: false))."
    }

    func localMoveSteps(_ plan: HerdMovePlan, setup: LocalSetup, report: URL, log: URL, record: HerdMoveRecord) -> [HerdMoveStep] {
        var steps: [HerdMoveStep] = []

        if !plan.packages.isEmpty {
            steps.append(HerdMoveStep(title: "Install \(EnglishList.joined(plan.packages.map { Self.packageTitle($0.name, $0.line) }))") {
                for package in plan.packages {
                    try await self.herdMoveInstall(package.name, package.line, log: log)
                }
            })
        }

        if !plan.ini.isEmpty {
            steps.append(HerdMoveStep(title: "php.ini lines") {
                try await self.herdMoveIniLines(plan, log: log, record: record)
            })
        }

        if !plan.databases.isEmpty {
            steps.append(HerdMoveStep(title: "Databases of \(Count.text(plan.databases.count, "site"))") {
                try await self.localMoveDatabases(plan, log: log, record: record)
            })
        }

        steps.append(HerdMoveStep(title: MoveSource.local.stopStep) {
            while Self.localRuns() {
                try await Task.sleep(for: .seconds(1))
            }

            record.done("Local quit.")
        })

        steps.append(HerdMoveStep(title: "Ports 80 and 443") {
            try await self.localMoveTakeOver(plan, log: log, record: record)
        })

        if !plan.sites.isEmpty {
            steps.append(HerdMoveStep(title: "Sites: \(plan.sites.count), with their names in /etc/hosts") {
                try await self.localMoveSites(plan, setup: setup, log: log, record: record)
            })
        }

        if !plan.wpConfigs.isEmpty {
            steps.append(HerdMoveStep(title: "wp-config.php of \(Count.text(plan.wpConfigs.count, "site"))") {
                try await self.localMoveConfigs(plan, report: report, log: log, record: record)
            })
        }

        if !plan.httpsSites.isEmpty {
            steps.append(HerdMoveStep(title: "URLs to HTTPS") {
                await self.localMoveURLs(plan, log: log, record: record)
            })
        }

        if plan.sites.contains(where: { !$0.ownLines.isEmpty }) {
            steps.append(HerdMoveStep(title: "nginx lines") {
                try await self.herdMoveSiteLines(plan, log: log, record: record)
            })
        }

        let envrc = plan.files.filter { $0.kind == .envrc }

        if !envrc.isEmpty {
            steps.append(HerdMoveStep(title: ".envrc files") {
                Self.localMoveEnvrc(envrc, report: report, log: log, record: record)
            })
        }

        if !plan.sites.isEmpty {
            steps.append(HerdMoveStep(title: "Open each site once") {
                await self.herdMoveChecks(plan, log: log, record: record)
            })
        }

        return steps
    }

    // MARK: The databases

    func localMoveDatabases(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for database in plan.databases {
            let site = database.sites.first ?? database.name

            guard let line = database.line, let id = ServiceID.of(package: database.kind, line: line) else {
                record.note("Nexus has no server for the database of \(site), so it did not copy it.")
                continue
            }

            guard await databaseRuntime(id) != nil else {
                throw RuntimeError.unsupported("\(Self.packageTitle(database.kind, line)) is not installed, so Nexus cannot copy the database of \(site).")
            }

            let name = await freeDatabaseName(database.targetName, on: id)

            do {
                let way = try await localCopy(database, into: id, as: name, log: log)
                record.update { values in
                    values.copied[database.id] = id
                    values.names[database.id] = name
                }
                record.done("The database of \(site) as \(name) on \(Self.packageTitle(database.kind, line)), \(way)")
            } catch let stopped as TaskStopped {
                throw stopped
            } catch {
                throw RuntimeError.unsupported("Nexus could not copy the database of \(site). \(ErrorText.plain(error))")
            }
        }
    }

    // A name that the instance has already gets _2, _3 and so on.
    func freeDatabaseName(_ base: String, on id: String) async -> String {
        var name = base
        var number = 2

        while await runningDatabaseExists(name, on: id) == true {
            name = "\(base)_\(number)"
            number += 1
        }

        return name
    }

    // The way that worked, for the report. A running server of Local gives the data of this moment.
    // A stopped site gives a copy of its data folder. local.sql is the last fallback.
    func localCopy(_ database: HerdMovePlan.DatabaseItem, into id: String, as name: String, log: URL) async throws -> String {
        var problems: [String] = []

        if let socket = database.socket, UnixSocket.answers(socket) {
            Self.appendLine("$ nexus db copy \(database.name) --to \(id) --as \(name) --from-socket \(socket)", to: log)

            do {
                Self.appendLine(try await copyDatabase(DatabaseCopy(source: DatabaseServer(host: "localhost", account: database.account, socket: socket), database: database.name, instance: id, name: name)), to: log)
                return "from the running server of Local"
            } catch let stopped as TaskStopped {
                throw stopped
            } catch {
                problems.append("The copy from the running server failed: \(ErrorText.plain(error))")
                Self.appendLine(problems.last ?? "", to: log)
            }
        }

        if let folder = database.dataFolder, let reader = database.readerLine {
            do {
                try await copyFromDataFolder(database, folder: URL(filePath: folder, directoryHint: .isDirectory), reader: reader, into: id, as: name, log: log)
                return "from a copy of its data folder"
            } catch let stopped as TaskStopped {
                throw stopped
            } catch {
                problems.append("The copy of the data folder did not open: \(ErrorText.plain(error))")
                Self.appendLine(problems.last ?? "", to: log)
            }
        }

        if let dump = database.dump, FileManager.default.fileExists(atPath: dump) {
            Self.appendLine("$ nexus db import \(dump) --to \(id) --as \(name)", to: log)
            _ = try await importDump(DumpImport(file: dump, target: .instance(id), name: name))
            let date = database.dumpDate.map { " of \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "from local.sql\(date). Changes after the last stop of the site in Local are not in it"
        }

        throw RuntimeError.unsupported((problems + ["Nexus found no data that it can read."]).joined(separator: " "))
    }

    // Nexus copies the data folder and starts its own server of the same line on the copy, with no
    // network. A newer patch version upgrades the copy, and MySQL 8.0 also upgrades the data of
    // 5.7. The files of Local do not change. The socket path must stay below 104 bytes.
    func copyFromDataFolder(_ database: HerdMovePlan.DatabaseItem, folder: URL, reader: String, into id: String, as name: String, log: URL) async throws {
        guard let readerID = ServiceID.of(package: database.kind, line: reader), let tools = await databaseRuntime(readerID) else {
            throw RuntimeError.unsupported("\(Self.packageTitle(database.kind, reader)) is not installed.")
        }

        let work = URL(filePath: "/tmp/nexus-move-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let data = work.appending(path: "data", directoryHint: .isDirectory)
        Self.appendLine("$ cp -R \(folder.path(percentEncoded: false)) \(data.path(percentEncoded: false))", to: log)
        try await onOwnThread { () -> Result<Void, Error> in
            Result { try FileManager.default.copyItem(at: folder, to: data) }
        }.get()

        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false))) ?? [] where leftover.hasSuffix(".pid") || leftover.contains(".sock") {
            try? FileManager.default.removeItem(at: data.appending(path: leftover))
        }

        let socket = work.appending(path: "m.sock").path(percentEncoded: false)
        let server = Process()
        server.executableURL = tools.bin(tools.kind == .mysql ? "mysqld" : "mariadbd")
        server.arguments = [
            "--no-defaults",
            "--basedir=\(tools.runtime.folder.path(percentEncoded: false))",
            "--datadir=\(data.path(percentEncoded: false))",
            "--socket=\(socket)",
            "--pid-file=\(work.appending(path: "m.pid").path(percentEncoded: false))",
            "--log-error=\(work.appending(path: "error.log").path(percentEncoded: false))",
            "--skip-networking",
            "--innodb-buffer-pool-size=64M",
        ] + (tools.kind == .mysql ? ["--mysqlx=OFF", "--skip-log-bin"] : [])
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        Self.appendLine("$ \(server.executableURL?.lastPathComponent ?? "mysqld") \(server.arguments?.joined(separator: " ") ?? "")", to: log)
        try server.run()

        defer {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }

        let deadline = ContinuousClock.now + .seconds(180)

        while !UnixSocket.answers(socket), server.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
        }

        guard UnixSocket.answers(socket) else {
            let errors = (try? String(contentsOf: work.appending(path: "error.log"), encoding: .utf8)) ?? ""
            let last = errors.components(separatedBy: "\n").filter { $0.contains("[ERROR]") }.suffix(3).joined(separator: " ")
            throw RuntimeError.unsupported("\(Self.packageTitle(database.kind, reader)) did not open the copy. \(last)")
        }

        Self.appendLine("$ nexus db copy \(database.name) --to \(id) --as \(name) --from-socket \(socket)", to: log)
        Self.appendLine(try await copyDatabase(DatabaseCopy(source: DatabaseServer(host: "localhost", account: database.account, socket: socket), database: database.name, instance: id, name: name)), to: log)

        server.terminate()
        await onOwnThread { server.waitUntilExit() }
    }

    // MARK: Ports, sites and files

    func localMoveTakeOver(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        await herdMoveWaitForWebPorts(.local, log: log)
        Self.appendLine("$ nexus restart nginx", to: log)

        do {
            Self.appendLine(try await restart(ServiceCatalog.nginxID, cause: "The move from Local"), to: log)
        } catch {
            Self.appendLine("nginx did not restart: \(ErrorText.plain(error))", to: log)
        }

        if let devTLD = plan.devTLD {
            Self.appendLine("$ nexus tld \(devTLD.tld)", to: log)

            do {
                Self.appendLine(try await setTLD(devTLD.tld), to: log)
                record.done("New sites get .\(devTLD.tld).")
            } catch {
                record.note("Nexus kept its dev TLD: \(ErrorText.plain(error))")
            }
        }

        await writeSystemFiles()
    }

    func localMoveSites(_ plan: HerdMovePlan, setup: LocalSetup, log: URL, record: HerdMoveRecord) async throws {
        let existing = Set(await stateStore.current().sites.flatMap(\.hosts))

        for site in plan.sites {
            let host = site.hosts[0]

            guard !existing.contains(host) else {
                record.note("\(host) is a site of Nexus already, so Nexus kept it as it is.")
                continue
            }

            var aliases = Array(site.hosts.dropFirst())

            if site.network == .subdomains, let database = plan.databases.first(where: { $0.sites.contains(host) }) {
                aliases = Array(Set(aliases + (await localSubsites(of: host, folder: site.folder, database: database, record: record)))).sorted()
            }

            let server = site.server ?? .nginx
            Self.appendLine("$ nexus site add \(site.folder) --host \(host)\(aliases.isEmpty ? "" : " --alias \(aliases.joined(separator: ","))")\(site.php.map { " --php \($0)" } ?? "") --server \(server.rawValue)", to: log)
            Self.appendLine(try await addSite(folder: site.folder, host: host, aliases: aliases, php: site.php, server: server), to: log)
            record.done("\(host) from \(site.folder)\(aliases.isEmpty ? "" : ", with \(EnglishList.joined(aliases))")")
        }
    }

    // The subsites of a network on subdomains are in the blogs table. Local does not always list
    // them in sites.json (seen in the VM, 2026-11-26).
    func localSubsites(of host: String, folder: String, database: HerdMovePlan.DatabaseItem, record: HerdMoveRecord) async -> [String] {
        let values = record.current

        guard let id = values.copied[database.id], let name = values.names[database.id] else {
            return []
        }

        let config = (try? String(contentsOf: URL(filePath: folder).appending(path: "wp-config.php"), encoding: .utf8)) ?? ""
        let prefix = config.firstMatch(of: #/\$table_prefix\s*=\s*['"]([A-Za-z0-9_]+)['"]/#).map { String($0.1) } ?? "wp_"

        do {
            let (_, client, work) = try await runningClient(id)
            defer { try? FileManager.default.removeItem(at: work) }

            let output = try await client.query("SELECT domain FROM `\(prefix)blogs`", database: name)
            return output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != host && $0 != "domain" }
        } catch {
            record.note("Nexus could not read the subsites of \(host): \(ErrorText.plain(error))")
            return []
        }
    }

    // wp-config.php gets the database of Nexus: its name, the account and DB_HOST with the port.
    // The old lines stay as comment lines, and a copy of the file goes into the report folder.
    func localMoveConfigs(_ plan: HerdMovePlan, report: URL, log: URL, record: HerdMoveRecord) async throws {
        for item in plan.wpConfigs {
            guard let database = plan.databases.first(where: { $0.sites.contains(item.host) }), let id = record.current.copied[database.id], let name = record.current.names[database.id], let tools = await databaseRuntime(id) else {
                record.note("wp-config.php of \(item.host) did not change, because its database did not move.")
                continue
            }

            let port = try await connectionPort(of: tools)
            let account = try await account(of: tools)
            let file = URL(filePath: item.file)
            Self.keepCopy(of: item.file, in: report, record: record)

            var text = try String(contentsOf: file, encoding: .utf8)
            let values = ["DB_NAME": name, "DB_USER": account.user, "DB_PASSWORD": account.password, "DB_HOST": "127.0.0.1:\(port)"]

            for key in ["DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"] {
                guard let value = values[key], let changed = WordPressFiles.settingConstant(key, to: value, in: text) else {
                    throw RuntimeError.unsupported("wp-config.php of \(item.host) has no single line that defines \(key). Nexus changed nothing in it.")
                }

                text = changed
            }

            try Data(text.utf8).write(to: file)
            Self.appendLine("Changed \(item.file): DB_NAME, DB_USER, DB_PASSWORD and DB_HOST", to: log)
            record.done("wp-config.php of \(item.host): the database \(name) on \(id)")
        }
    }

    // Nexus serves each site over HTTPS. Local installs WordPress with http://. A failure leaves the
    // site as it is, with a note.
    func localMoveURLs(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async {
        for host in plan.httpsSites {
            do {
                let info = try await wordPressSite(host: host)

                guard let urlPlan = info.urlPlan else {
                    Self.appendLine("The URLs of \(host) need no change.", to: log)
                    continue
                }

                let message = try await changeWordPressURLs(host: host, plan: urlPlan)
                Self.appendLine(message, to: log)
                record.done("URLs of \(host): \(message)")
            } catch {
                record.note("The URLs of \(host) did not change: \(ErrorText.plain(error))")
            }
        }
    }

    // Local writes .envrc again at the next start of the site in Local.
    static func localMoveEnvrc(_ files: [HerdMovePlan.FileItem], report: URL, log: URL, record: HerdMoveRecord) {
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            keepCopy(of: file.path, in: report, record: record)

            do {
                try FileManager.default.removeItem(atPath: file.path)
                appendLine("Moved \(file.path) into the report folder", to: log)
                record.done("\(file.path): moved into the report folder")
            } catch {
                record.note("\(file.path) stays: \(ErrorText.plain(error))")
            }
        }
    }
}

// connect() on a Unix socket, the way a client of MySQL starts. A stale socket file gives no answer.
enum UnixSocket {
    static func answers(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

        guard descriptor >= 0 else {
            return false
        }

        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)

        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return result == 0
    }
}
