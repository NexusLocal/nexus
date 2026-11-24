import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import Synchronization

// The task of the move from Herd. Each step changes only Nexus and the files that the plan names.
// Each file gets a copy in the report folder before its change. The report tells how to go back.
final class HerdMoveRecord: Sendable {
    struct Values: Sendable {
        var lines: [String] = []
        var notes: [String] = []
        var copies: [(original: String, copy: String)] = []
        // The instances that got a free port, with their standard port.
        var movedPorts: [String: Int] = [:]
        // The instance of each copied database, by the id of the plan item.
        var copied: [String: String] = [:]
        var checks: [(host: String, result: String)] = []
    }

    private let values = Mutex(Values())

    var current: Values {
        values.withLock { $0 }
    }

    func update(_ change: (inout Values) -> Void) {
        values.withLock { change(&$0) }
    }

    func done(_ line: String) {
        update { $0.lines.append(line) }
    }

    func note(_ line: String) {
        update { $0.notes.append(line) }
    }
}

extension NexusEngine {
    struct HerdMoveStep: Sendable {
        let title: String
        let run: @Sendable () async throws -> Void
    }

    func moveFromHerd(_ request: HerdMoveRequest) async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser

        guard let setup = HerdReader.read(herd: HerdReader.folder(home: home)) else {
            throw RuntimeError.unsupported("Nexus found no Herd on this Mac. Nexus changed nothing.")
        }

        let facts = await herdMoveFacts(setup: setup, home: home)
        let plan = HerdMovePlanner.applying(request, to: HerdMovePlanner.plan(setup: setup, facts: facts), facts: facts)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let report = paths.moves.appending(path: "herd-\(formatter.string(from: .now))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report.appending(path: "copies"), withIntermediateDirectories: true)

        let log = report.appending(path: "move.log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let record = HerdMoveRecord()
        let steps = herdMoveSteps(plan, home: home, report: report, log: log, record: record)
        let progress = TaskProgress()
        progress.update { values in
            values.steps = steps.map { TaskStep(title: $0.title) }
            values.logFile = log
            values.secrets = plan.databases.map(\.account.password).filter { $0.count >= 6 } + plan.redis.compactMap(\.password)
        }

        do {
            try await runTask(.moveFromHerd, id: Self.herdMoveTaskID, progress: progress, stopped: {
                "The move from Herd stopped. Herd still has your sites. The report is in \(report.path(percentEncoded: false))."
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

        let sites = Count.text(plan.sites.count, "site")
        let databases = plan.databases.isEmpty ? "" : " and \(Count.text(plan.databases.count, "database"))"
        return "Nexus moved \(sites)\(databases) from Herd. The report is in \(report.appending(path: "report.md").path(percentEncoded: false))."
    }

    func herdMoveSteps(_ plan: HerdMovePlan, home: URL, report: URL, log: URL, record: HerdMoveRecord) -> [HerdMoveStep] {
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
            steps.append(HerdMoveStep(title: "Databases: \(EnglishList.joined(plan.databases.map(\.name)))") {
                try await self.herdMoveDatabases(plan, log: log, record: record)
            })
        }

        if !plan.redis.isEmpty {
            steps.append(HerdMoveStep(title: "Redis keys") {
                try await self.herdMoveRedis(plan, log: log, record: record)
            })
        }

        steps.append(HerdMoveStep(title: HerdMoveText.quitHerdStep) {
            while Self.herdIsRunning() {
                try await Task.sleep(for: .seconds(1))
            }

            record.done("Herd stopped.")
        })

        steps.append(HerdMoveStep(title: "Ports 80 and 443 and the domain .\(plan.tld)") {
            try await self.herdMoveTakeOver(plan, log: log, record: record)
        })

        // A new site changes the configuration of nginx, and nginx can start only after Herd
        // gave back ports 80 and 443. So the sites come after the quit of Herd.
        if !plan.sites.isEmpty {
            steps.append(HerdMoveStep(title: "Sites: \(plan.sites.count)") {
                try await self.herdMoveSites(plan, log: log, record: record)
            })
        }

        if plan.sites.contains(where: { !$0.ownLines.isEmpty }) {
            steps.append(HerdMoveStep(title: "nginx lines") {
                try await self.herdMoveSiteLines(plan, log: log, record: record)
            })
        }

        if !plan.envFiles.isEmpty {
            steps.append(HerdMoveStep(title: ".env of \(EnglishList.joined(plan.envFiles.map { $0.host }))") {
                try await self.herdMoveEnvFiles(plan, report: report, log: log, record: record)
            })
        }

        if !plan.files.isEmpty {
            steps.append(HerdMoveStep(title: EnglishList.joined(plan.files.map { Self.shortPath($0.path, home: home) })) {
                try await self.herdMoveFiles(plan, home: home, report: report, log: log, record: record)
            })
        }

        if !plan.sites.isEmpty {
            steps.append(HerdMoveStep(title: "Open each site once") {
                await self.herdMoveChecks(plan, log: log, record: record)
            })
        }

        return steps
    }

    static func packageTitle(_ name: String, _ line: String) -> String {
        HerdMoveText.packageTitle(name, line)
    }

    static func shortPath(_ path: String, home: URL) -> String {
        HerdMoveText.shortPath(path, home: home.path(percentEncoded: false))
    }

    static func appendLine(_ line: String, to log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else {
            return
        }

        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: The steps

    // The first run can still install the same package when the move starts. Then the move waits
    // for that install and does not start a second one.
    func herdMoveInstall(_ name: String, _ line: String, log: URL) async throws {
        guard await installer.installed(name: name, line: line) == nil else {
            Self.appendLine("\(Self.packageTitle(name, line)) is installed already.", to: log)
            return
        }

        Self.appendLine("$ nexus install \(name) \(line)", to: log)

        do {
            Self.appendLine(try await install(name: name, line: line), to: log)
        } catch {
            for _ in 0..<600 where await installer.installed(name: name, line: line) == nil {
                try await Task.sleep(for: .seconds(1))
            }

            guard await installer.installed(name: name, line: line) != nil else {
                throw error
            }

            Self.appendLine("\(Self.packageTitle(name, line)) is installed now.", to: log)
        }
    }

    func herdMoveSites(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        let existing = Set(await stateStore.current().sites.flatMap(\.hosts))

        for folder in plan.parked {
            Self.appendLine("$ nexus park \(folder.folder) --php \(folder.php)", to: log)

            Self.appendLine(try await park(folder: folder.folder, php: folder.php, server: nil), to: log)
        }

        for site in plan.sites {
            let host = site.hosts[0]

            if site.parkedIn != nil {
                let parkedPHP = plan.parked.first { $0.folder == site.parkedIn }?.php

                if let line = site.php, line != parkedPHP {
                    Self.appendLine("$ nexus site edit \(host) --php \(line)", to: log)
                    Self.appendLine(try await editSite(host, change: SiteChange(php: line)), to: log)
                }

                record.done("\(host) from \(site.folder)")
                continue
            }

            guard !existing.contains(host) else {
                record.note("\(host) is a site of Nexus already, so Nexus kept it as it is.")
                continue
            }

            if site.kind == .proxy, let address = site.address {
                let folder = paths.proxies.appending(path: host, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                Self.appendLine("$ nexus site add \(folder.path(percentEncoded: false)) --host \(host) --runs-as proxy --address \(address)", to: log)
                Self.appendLine(try await addSite(folder: folder.path(percentEncoded: false), host: host, aliases: [], php: nil, server: nil, settings: SiteChange(runsAs: .proxy, address: address)), to: log)
                record.done("\(host) as a proxy to \(address)")
                continue
            }

            let aliases = Array(site.hosts.dropFirst())
            Self.appendLine("$ nexus site add \(site.folder) --host \(host)\(aliases.isEmpty ? "" : " --alias \(aliases.joined(separator: ","))")\(site.php.map { " --php \($0)" } ?? "")", to: log)
            Self.appendLine(try await addSite(folder: site.folder, host: host, aliases: aliases, php: site.php, server: nil), to: log)
            record.done("\(host) from \(site.folder)")
        }
    }

    func herdMoveIniLines(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for item in plan.ini {
            let current = (try? await customSettings(line: item.line)) ?? []
            let keys = Set(item.lines.map(Self.iniKey))
            let merged = current.filter { !keys.contains(Self.iniKey($0)) } + item.lines
            Self.appendLine("$ nexus ini \(item.line): \(item.lines.joined(separator: ", "))", to: log)

            do {
                Self.appendLine(try await setCustomSettings(line: item.line, lines: merged), to: log)
                record.done("php.ini of PHP \(item.line): \(item.lines.joined(separator: ", "))")
            } catch {
                record.note("Nexus did not take the php.ini lines of PHP \(item.herdPHP): \(ErrorText.plain(error))")
            }
        }
    }

    func herdMoveSiteLines(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for site in plan.sites where !site.ownLines.isEmpty && site.kind == .php {
            let host = site.hosts[0]
            let current = (try? await siteLines(host: host)) ?? []
            Self.appendLine("$ nexus site lines \(host): \(site.ownLines.joined(separator: " "))", to: log)

            do {
                Self.appendLine(try await setSiteLines(host: host, lines: current + site.ownLines.filter { !current.contains($0) }), to: log)
                record.done("nginx lines of \(host): \(site.ownLines.joined(separator: " "))")
            } catch {
                record.note("Nexus did not take the nginx lines of \(host): \(ErrorText.plain(error))")
            }
        }
    }

    static func iniKey(_ line: String) -> String {
        let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
        return key == "extension" || key == "zend_extension" ? line : key
    }

    func herdMoveDatabases(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for database in plan.databases {
            guard let line = database.line, let id = ServiceID.of(package: database.kind, line: line) else {
                record.note("Nexus has no server for the database \(database.name), so it did not copy it.")
                continue
            }

            guard let tools = await databaseRuntime(id) else {
                throw RuntimeError.unsupported("\(Self.packageTitle(database.kind, line)) is not installed, so Nexus cannot copy \(database.name).")
            }

            let port = try await port(of: tools)

            // The other app often uses the standard port too. The instance of Nexus moves to a free
            // port for the copy, and back after the other app quits.
            if port == database.port, record.current.movedPorts[id] == nil {
                let free = Self.freePort(from: port + 10_000)
                Self.appendLine("$ nexus port \(id) \(free)", to: log)
                Self.appendLine(try await setPort(id, free), to: log)
                record.update { $0.movedPorts[id] = port }
            }

            let source = DatabaseServer(host: "127.0.0.1", port: database.port, account: database.account, socket: database.socket)
            Self.appendLine("$ nexus db copy \(database.name) --to \(id) --from-port \(database.port.map(String.init) ?? "-")", to: log)

            do {
                Self.appendLine(try await copyDatabase(DatabaseCopy(source: source, database: database.name, instance: id, name: database.name)), to: log)
                record.update { $0.copied[database.id] = id }
                record.done("The database \(database.name) on \(Self.packageTitle(database.kind, line))")
            } catch let stopped as TaskStopped {
                throw stopped
            } catch {
                if await runningDatabaseExists(database.name, on: id) == true {
                    record.update { $0.copied[database.id] = id }
                    record.note("\(Self.packageTitle(database.kind, line)) has a database \(database.name) already, so Nexus kept it and did not copy it.")
                    continue
                }

                throw RuntimeError.unsupported("Nexus could not copy the database \(database.name). \(ErrorText.plain(error))")
            }
        }
    }

    func herdMoveRedis(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for item in plan.redis {
            guard let id = ServiceID.of(package: "redis", line: item.line), let runtime = await installer.installed(name: "redis", line: item.line) else {
                throw RuntimeError.unsupported("Redis \(item.line) is not installed, so Nexus cannot copy the Redis keys.")
            }

            var port = try await ports(for: runtime)[id] ?? 6379

            if port == item.port, record.current.movedPorts[id] == nil {
                let free = Self.freePort(from: port + 10_000)
                Self.appendLine("$ nexus port \(id) \(free)", to: log)
                Self.appendLine(try await setPort(id, free), to: log)
                record.update { $0.movedPorts[id] = port }
                port = free
            }

            Self.appendLine(try await start(id), to: log)

            for _ in 0..<50 where !PortInspector.acceptsLoopbackConnections(port) {
                try await Task.sleep(for: .milliseconds(200))
            }

            let target = port
            let result = await onOwnThread { () -> Result<(copied: Int, problems: [String]), RedisWire.Failure> in
                do {
                    let source = try RedisWire(port: item.port, password: item.password)
                    let destination = try RedisWire(port: target)
                    return .success(try RedisWire.copyKeys(from: source, to: destination))
                } catch {
                    return .failure(RedisWire.Failure(description: String(describing: error)))
                }
            }

            switch result {
            case .success(let copy):
                Self.appendLine("Copied \(copy.copied) keys from port \(item.port) to port \(target).", to: log)
                record.done("\(Count.text(copy.copied, "Redis key")) from \(item.valkey ? "Valkey" : "Redis") on port \(item.port)")

                if !copy.problems.isEmpty {
                    record.note("Some Redis keys did not copy: \(copy.problems.joined(separator: "; "))")
                }
            case .failure(let failure):
                record.note("Nexus could not copy the Redis keys from port \(item.port): \(failure.description)")
            }
        }
    }

    // Herd stops its nginx some seconds after its app quits.
    func herdMoveWaitForWebPorts(log: URL) async {
        guard await supervisor.state(of: ServiceCatalog.nginxID)?.isActive != true else {
            return
        }

        let state = await stateStore.current()
        let ports = [state.ports[ServiceCatalog.httpPortKey] ?? 80, state.ports[ServiceCatalog.httpsPortKey] ?? 443]

        for port in ports {
            let isFree = await PortInspector.becomesFree(port, within: .seconds(30))

            if !isFree {
                Self.appendLine("Port \(port) is still in use 30 seconds after the quit of Herd.", to: log)
            }
        }
    }

    func herdMoveTakeOver(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async throws {
        for (id, standard) in record.current.movedPorts.sorted(by: { $0.key < $1.key }) {
            guard await PortInspector.becomesFree(standard, within: .seconds(5)) else {
                record.note("\(id) keeps its free port, because another program still uses port \(standard). The .env files get that port.")
                continue
            }

            Self.appendLine("$ nexus port \(id) \(standard)", to: log)
            Self.appendLine(try await setPort(id, standard), to: log)
        }

        await herdMoveWaitForWebPorts(log: log)
        Self.appendLine("$ nexus restart nginx", to: log)

        do {
            Self.appendLine(try await restart(ServiceCatalog.nginxID, cause: "The move from Herd"), to: log)
        } catch {
            Self.appendLine("nginx did not restart: \(ErrorText.plain(error))", to: log)
        }

        if let port = resolverPort(for: plan.tld) {
            do {
                try await helper.send(.takeOverResolver(tld: plan.tld, port: port))
                record.done("The domain .\(plan.tld) uses the DNS server of Nexus.")
            } catch {
                record.note("Nexus could not take over the domain .\(plan.tld): \(ErrorText.plain(error))")
            }
        }

        await writeSystemFiles()
    }

    func herdMoveEnvFiles(_ plan: HerdMovePlan, report: URL, log: URL, record: HerdMoveRecord) async throws {
        for item in plan.envFiles {
            Self.keepCopy(of: item.file, in: report, record: record)

            let database = plan.databases.first { $0.sites.contains(item.host) }
            let instance = database.flatMap { record.current.copied[$0.id] }

            if let setup = try await useNexusSetup(host: item.host) {
                let changes = setup.plan.changes(choosing: instance)
                Self.appendLine("$ Use Nexus for \(item.host): \(changes.map(\.key).joined(separator: ", "))", to: log)
                Self.appendLine(try await useNexus(UseNexusRequest(host: item.host, instance: instance, copy: false, changes: changes)), to: log)
                record.done(".env of \(item.host): \(changes.map(\.key).joined(separator: ", "))")
            }

            if EnvFile.values(of: URL(filePath: item.file))["MAIL_PORT"] == "2525" {
                Self.appendLine("$ Send the mail of \(item.host) to Nexus", to: log)
                Self.appendLine((try? await sendMailToNexus(host: item.host)) ?? "The mail settings of \(item.host) did not change.", to: log)
            }
        }
    }

    func herdMoveFiles(_ plan: HerdMovePlan, home: URL, report: URL, log: URL, record: HerdMoveRecord) async throws {
        for item in plan.files {
            let file = URL(filePath: item.path).resolvingSymlinksInPath()

            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            Self.keepCopy(of: item.path, in: report, record: record)
            let changed = item.kind == .shell ? Self.removingLines(item.lines, from: text) : Self.usingNexusPHP(in: text, bin: paths.bin)

            guard changed != text else {
                continue
            }

            try Data(changed.utf8).write(to: file)
            Self.appendLine("Changed \(item.path)", to: log)
            record.done(item.kind == .shell ? "\(Self.shortPath(item.path, home: home)): the lines of Herd are gone" : "\(Self.shortPath(item.path, home: home)): the PHP of Nexus")
        }

        let pathLine = ShellPathLine.standard

        if pathLine.state() == .notLast {
            try? pathLine.turnOn()
        }
    }

    // Removes each line once, and more than one empty line in a row that the removal leaves.
    static func removingLines(_ lines: [String], from text: String) -> String {
        var remaining = lines
        var kept: [String] = []

        for line in text.components(separatedBy: "\n") {
            if let index = remaining.firstIndex(of: line) {
                remaining.remove(at: index)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty, kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                continue
            }

            kept.append(line)
        }

        return kept.joined(separator: "\n")
    }

    // ".../Herd/bin/php84" becomes ".../Nexus/bin/php", which follows the PHP of the project.
    static func usingNexusPHP(in text: String, bin: URL) -> String {
        let nexusBin = bin.path(percentEncoded: false).hasSuffix("/") ? String(bin.path(percentEncoded: false).dropLast()) : bin.path(percentEncoded: false)

        return text.replacing(#/[^"'\s]*/Library/Application Support/Herd/bin/([a-z]+?)(\d*)\b/#) { match in
            "\(nexusBin)/\(match.1)"
        }
    }

    static func keepCopy(of path: String, in report: URL, record: HerdMoveRecord) {
        let name = path.replacingOccurrences(of: "/", with: "_")
        let copy = report.appending(path: "copies/\(name)")

        guard !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) else {
            return
        }

        if (try? FileManager.default.copyItem(at: URL(filePath: path).resolvingSymlinksInPath(), to: copy)) != nil {
            record.update { $0.copies.append((path, copy.path(percentEncoded: false))) }
        }
    }

    static func freePort(from start: Int) -> Int {
        (start..<(start + 200)).first(where: PortInspector.isFree) ?? start
    }

    func herdMoveChecks(_ plan: HerdMovePlan, log: URL, record: HerdMoveRecord) async {
        for site in plan.sites {
            let host = site.hosts[0]
            let result = await Self.check(host: host)
            Self.appendLine("https://\(host): \(result)", to: log)
            record.update { $0.checks.append((host, result)) }
        }
    }

    static func check(host: String) async -> String {
        guard let url = URL(string: "https://\(host)/") else {
            return "not a valid address"
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status < 500 ? "opens (status \(status))" : "gives an error (status \(status))"
        } catch {
            return "does not open: \(error.localizedDescription)"
        }
    }

    // MARK: The report

    static func writeHerdReport(plan: HerdMovePlan, record: HerdMoveRecord, failure: String?, home: URL, to folder: URL) {
        let values = record.current
        var text = "# The move from Herd\n\n"

        if let failure {
            text += "The move stopped: \(failure)\n\n"
        }

        text += "## What moved\n\n" + values.lines.map { "- \($0)\n" }.joined()

        if !values.notes.isEmpty || !plan.notes.isEmpty {
            text += "\n## Notes\n\n" + (plan.notes + values.notes).map { "- \($0)\n" }.joined()
        }

        if !values.checks.isEmpty {
            text += "\n## The check of each site\n\n" + values.checks.map { "- https://\($0.host) \($0.result)\n" }.joined()
        }

        if !values.copies.isEmpty {
            text += "\n## Copies of the files that Nexus changed\n\n" + values.copies.map { "- \(shortPath($0.original, home: home)): \($0.copy)\n" }.joined()
        }

        text += """

        ## How to go back to Herd

        1. Quit Nexus, or stop all its services in the menu bar.
        2. Put back each file from its copy above, for example the .env of each site and ~/.zshrc.
        3. Open Herd. Herd writes its files for the domain .\(plan.tld) again.

        Nexus changed nothing in Herd. The databases of Herd still have their data.

        """

        try? Data(text.utf8).write(to: folder.appending(path: "report.md"))
    }
}
