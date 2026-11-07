import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// The configuration and the database of a WordPress site (Phase 4, 3b). The Site screen asks for it
// when it opens. The probe runs PHP and the check runs the client of the instance. So the list of the
// sites does not get these values. The three actions change something only after a click. An
// action gets the values that the user confirmed, and nexusd refuses when they are not true any
// more.
extension NexusEngine {
    struct WordPressTarget {
        let site: Site
        let type: PHPProjectType
        let project: URL
        let core: URL?
        let configFile: URL?
        let result: WordPressProbe.Result

        // Bedrock reads .env and then .env.local. A project without both files has no configuration.
        var config: WordPressConfig? {
            guard type == .bedrock else {
                return result.config
            }

            return bedrockFiles.isEmpty ? nil : WordPressFiles.bedrockConfig(project: project)
        }

        // The file that holds DB_HOST. For Bedrock that is .env.local when it sets DB_HOST.
        var shownFile: URL? {
            guard type == .bedrock else {
                return configFile
            }

            return bedrockFiles.last { EnvFile.values(of: $0)["DB_HOST"] != nil } ?? bedrockFiles.first
        }

        var configName: String {
            shownFile?.lastPathComponent ?? (type == .bedrock ? ".env" : "wp-config.php")
        }

        // The file that sets WP_HOME (3d). For Bedrock that is .env.local when it sets WP_HOME.
        var homeFile: URL? {
            guard type == .bedrock else {
                return configFile
            }

            return bedrockFiles.last { EnvFile.values(of: $0)["WP_HOME"]?.isEmpty == false }
        }

        // The file that sets DOMAIN_CURRENT_SITE of a network.
        var domainFile: URL? {
            guard type == .bedrock else {
                return configFile
            }

            return bedrockFiles.last { EnvFile.values(of: $0)["DOMAIN_CURRENT_SITE"]?.isEmpty == false }
        }

        private var bedrockFiles: [URL] {
            [".env", ".env.local"]
                .map { project.appending(path: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        }
    }

    func wordPressSite(host: String) async throws -> WordPressSiteInfo {
        let target = try await wordPressTarget(host)
        let instances = await mysqlInstances()

        // A download of WordPress into an added site changes no folder that nexusd watches. The
        // screen of the site then writes the rules of WordPress into nginx.
        if await applyWorkspaceSites() {
            publishSites()
        }

        guard let config = target.config else {
            do {
                let setUp = try await setUpPlan(for: target, in: instances)
                return WordPressSiteInfo(type: target.type, version: target.result.version, setUpDatabase: setUp?.name, setUpInstance: setUp?.instance.id)
            } catch {
                return WordPressSiteInfo(type: target.type, version: target.result.version, problem: "Nexus cannot read the databases for the set-up. \(error)")
            }
        }

        let database = await databaseCheck(of: config, in: instances)
        let state = await stateStore.current()

        return WordPressSiteInfo(
            type: target.type,
            version: target.result.version,
            configFile: target.shownFile.map { Self.displayPath($0) },
            database: config.database,
            dbHost: config.host,
            instance: database.instance,
            databaseExists: database.exists,
            home: database.home,
            siteURL: database.siteURL,
            problem: database.problem,
            suggestedDBHost: database.suggestedDBHost,
            url: Self.url(for: target.site.host, in: state),
            configHome: Self.literalHome(of: config),
            configHomeFile: Self.literalHome(of: config) == nil ? nil : target.homeFile.map { Self.displayPath($0) },
            urlPlan: urlPlan(of: target, config: config, check: database, in: state),
            urlChange: urlChange(of: target.site.host, database: config.database, instance: database.instance, in: state),
            copyInstance: database.copyInstance
        )
    }

    // A classic site without wp-config.php gets a new database with a free name on MySQL 8.4, or
    // else on the newest MySQL or MariaDB that runs (owner, 2026-11-06). Then WP-CLI writes
    // wp-config.php with salts of this Mac. A failure of WP-CLI removes only the database that
    // Nexus made here.
    func setUpWordPress(host: String, database: String, instance: String) async throws -> String {
        let target = try await wordPressTarget(host)

        guard target.type == .wordpress, let core = target.core else {
            throw RuntimeError.unsupported("Set up works only for a classic WordPress site. A Bedrock project reads its database from .env.")
        }

        guard target.configFile == nil else {
            throw RuntimeError.unsupported("\(host) has a wp-config.php already.")
        }

        let wpCLI = try await wpCLICommand(in: core, failure: "WP-CLI did not write wp-config.php.")

        guard let plan = try await setUpPlan(for: target, in: await mysqlInstances()) else {
            throw RuntimeError.unsupported("No MySQL or MariaDB of Nexus runs. Start MySQL 8.4 first.")
        }

        guard plan.name == database, plan.instance.id == instance else {
            throw RuntimeError.unsupported("Nexus would now make the database \(plan.name) on \(plan.instance.id). Set up WordPress again to confirm this.")
        }

        let (tools, client, work) = try await runningClient(plan.instance.id)
        defer { try? FileManager.default.removeItem(at: work) }
        let account = try await account(of: tools)

        try await client.query("CREATE DATABASE \(Self.sqlName(plan.name))")

        do {
            _ = try await wpCLI(["config", "create", "--dbname=\(plan.name)", "--dbuser=\(account.user)", "--dbpass=\(account.password)", "--dbhost=127.0.0.1:\(plan.instance.port)", "--skip-check"])
            _ = try await wpCLI(["config", "set", "WP_ENVIRONMENT_TYPE", "local", "--type=constant"])
        } catch {
            try? FileManager.default.removeItem(at: core.appending(path: "wp-config.php"))
            try? await client.query("DROP DATABASE \(Self.sqlName(plan.name))")
            throw error
        }

        return "Nexus made the database \(plan.name) on \(plan.instance.id) and wrote wp-config.php. Open \(Self.url(for: host, in: await stateStore.current())) to install WordPress."
    }

    func createWordPressDatabase(host: String) async throws -> String {
        let target = try await wordPressTarget(host)

        guard let config = target.config, let name = config.database else {
            throw RuntimeError.unsupported("The configuration of \(host) names no database.")
        }

        guard let port = config.address?.localPort, let instance = await mysqlInstances().first(where: { $0.port == port }) else {
            throw RuntimeError.unsupported("DB_HOST of \(host) names no MySQL or MariaDB of Nexus.")
        }

        let checked = try DatabaseName.validated(name)
        let (_, client, work) = try await runningClient(instance.id)
        defer { try? FileManager.default.removeItem(at: work) }

        guard try await !client.exists(checked) else {
            throw RuntimeError.unsupported("The database \(checked) exists on \(instance.id) already.")
        }

        for other in await mysqlInstances() where other.running && other.id != instance.id {
            if await holds(checked, instance: other) {
                throw RuntimeError.unsupported("The database \(checked) is on \(other.id). An empty database on \(instance.id) would show the installer of WordPress. Set DB_HOST to the port of \(other.id) instead: nexus site wordpress \(host) --set-db-host")
            }
        }

        try await client.query("CREATE DATABASE \(Self.sqlName(checked))")
        return "Nexus made the empty database \(checked) on \(instance.id). Open \(Self.url(for: host, in: await stateStore.current())) to install WordPress."
    }

    // DB_HOST gets the port of the instance that holds the database. The old line stays as a comment
    // line, as with "Send mail to Nexus" (D44). A DB_HOST that needs no change stays.
    func setWordPressDBHost(host: String, value: String) async throws -> String {
        let target = try await wordPressTarget(host)

        guard let config = target.config, let file = target.shownFile else {
            throw RuntimeError.unsupported("\(host) has no \(target.configName).")
        }

        guard let suggested = await databaseCheck(of: config, in: await mysqlInstances()).suggestedDBHost else {
            throw RuntimeError.unsupported("DB_HOST of \(host) needs no change. Nexus changes nothing.")
        }

        guard suggested == value else {
            throw RuntimeError.unsupported("Nexus would now set DB_HOST of \(host) to \(suggested). Set DB_HOST again to confirm this.")
        }

        let path = file.path(percentEncoded: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let changed: String?

        if target.type == .bedrock {
            let env = EnvFile.values(of: target.project.appending(path: ".env")).merging(EnvFile.values(of: target.project.appending(path: ".env.local"))) { _, local in local }

            guard env["DATABASE_URL"]?.isEmpty != false else {
                throw RuntimeError.unsupported("\(host) sets DATABASE_URL, which wins over DB_HOST. Change the host in DATABASE_URL yourself.")
            }

            changed = EnvRewrite.applyKeepingOldValues(to: text, keys: ["DB_HOST": value])
        } else {
            changed = WordPressFiles.settingDBHost(value, in: text)
        }

        guard let changed else {
            throw RuntimeError.unsupported("wp-config.php of \(host) has no single line that defines DB_HOST. Change it there yourself.")
        }

        try Self.write(changed, to: path)
        return "DB_HOST of \(host) is \(value) now. The old line stays in \(file.lastPathComponent) as a comment line."
    }

    func wordPressTarget(_ host: String) async throws -> WordPressTarget {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)

        guard let site = sites.first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let project = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)
        let type = PHPProject.type(of: site)

        guard type.isWordPress else {
            throw RuntimeError.unsupported("\(host) is no WordPress site.")
        }

        let core = PHPProject.wordPressFolder(in: project)
        let configFile = type == .bedrock ? nil : core.flatMap(WordPressFiles.configFile(core:))
        let installed = await installer.installedRuntimes()
        let php = try await phpCommand(installedPHP(try phpLine(for: ProjectFolder.locate(project, in: sites), state: state, installed: installed), in: installed))
        let probe = WordPressProbe(php: URL(filePath: php.executable), environment: php.environment)
        let result = try await probe.run(config: configFile, version: WordPressFiles.versionFile(core: core ?? project))

        return WordPressTarget(site: site, type: type, project: project, core: core, configFile: configFile, result: result)
    }

    // The command comes before a change, so a missing WP-CLI stops the set-up before the database.
    // The closure gives the output of WP-CLI.
    func wpCLICommand(in core: URL, failure: String) async throws -> @Sendable ([String]) async throws -> String {
        let folder = core.path(percentEncoded: false)
        let tool: ToolCommand

        do {
            tool = try await toolCommand(.wp, folder: folder)
        } catch let missing as ToolNotInstalled {
            throw RuntimeError.unsupported(missing.description)
        }

        var environment = ChildEnvironment.base().merging(tool.environment) { _, own in own }
        environment["PATH"] = (tool.path + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        let command: @Sendable ([String]) -> Command = { [environment] arguments in
            Command(
                executable: URL(filePath: tool.executable),
                arguments: tool.arguments + ["--path=\(RealPath.trimmed(folder))"] + arguments,
                environment: environment,
                workingDirectory: core
            )
        }

        return { arguments in
            do {
                return try await CommandRunner.run(command(arguments)).standardOutput
            } catch let error as CommandError {
                throw RuntimeError.unsupported("\(failure) \(error)")
            }
        }
    }

    struct DatabaseCheck {
        var instance: String?
        var exists: Bool?
        var home: String?
        var siteURL: String?
        var problem: String?
        var suggestedDBHost: String?
        var copyInstance: String?
    }

    func mysqlInstances() async -> [DatabaseInstance] {
        ((try? await databaseInstances()) ?? []).filter(\.kind.usesMySQLProtocol)
    }

    // Nexus reads only an instance of its own. It connects with the account of the instance and not
    // with the account of wp-config.php.
    func databaseCheck(of config: WordPressConfig, in instances: [DatabaseInstance]) async -> DatabaseCheck {
        guard let address = config.address else {
            return DatabaseCheck(problem: "wp-config.php gives no DB_HOST that Nexus can read.")
        }

        guard let port = address.localPort else {
            guard case .socket = address else {
                if let other = await otherServer(config, in: instances) {
                    return other
                }

                // After a copy from another host, DB_HOST moves to the Nexus instance.
                if let name = config.database, let holder = await holder(of: name, in: instances) {
                    return DatabaseCheck(problem: "DB_HOST is \(config.host ?? ""). The database \(name) is on \(holder.id). \(Self.fixText(holder))", suggestedDBHost: "127.0.0.1:\(holder.port)")
                }

                return DatabaseCheck(problem: "DB_HOST is \(config.host ?? ""). Nexus checks only a database on this Mac.")
            }

            let suggested = await suggestedInstance(for: config.database, in: instances)
            return DatabaseCheck(problem: "DB_HOST is \(config.host ?? "localhost"). With this value PHP uses a socket. No Nexus instance listens on a socket. \(Self.fixText(suggested))", suggestedDBHost: suggested.map { "127.0.0.1:\($0.port)" })
        }

        guard let instance = instances.first(where: { $0.port == port }) else {
            if let other = await otherServer(config, in: instances) {
                return other
            }

            let suggested = await suggestedInstance(for: config.database, in: instances)
            return DatabaseCheck(problem: "DB_HOST names port \(port). No MySQL or MariaDB of Nexus listens on that port. \(Self.fixText(suggested))", suggestedDBHost: suggested.map { "127.0.0.1:\($0.port)" })
        }

        guard instance.running else {
            return DatabaseCheck(instance: instance.id, problem: "Start \(instance.id) to check the database.")
        }

        guard let name = config.database else {
            return DatabaseCheck(instance: instance.id)
        }

        do {
            let (_, client, work) = try await runningClient(instance.id)
            defer { try? FileManager.default.removeItem(at: work) }

            guard try await client.query(Self.countOfSchema(name)) == "1" else {
                return await missingDatabase(name, on: instance, in: instances)
            }

            guard let prefix = config.safeTablePrefix else {
                return DatabaseCheck(instance: instance.id, exists: true)
            }

            let options = (try? await client.rows("SELECT option_name, option_value FROM \(Self.sqlName(name)).\(Self.sqlName("\(prefix)options")) WHERE option_name IN ('home', 'siteurl')")) ?? []
            let values = Dictionary(options.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }) { first, _ in first }

            return DatabaseCheck(instance: instance.id, exists: true, home: values["home"], siteURL: values["siteurl"])
        } catch {
            return DatabaseCheck(instance: instance.id, problem: "Nexus cannot read the databases of \(instance.id). \(error)")
        }
    }

    // A database on another instance is the data of the site, for example after an import there.
    // So DB_HOST changes then, and Nexus makes no empty database.
    private func missingDatabase(_ name: String, on instance: DatabaseInstance, in instances: [DatabaseInstance]) async -> DatabaseCheck {
        for other in instances where other.running && other.id != instance.id {
            if await holds(name, instance: other) {
                return DatabaseCheck(
                    instance: instance.id,
                    exists: false,
                    problem: "The database \(name) is on \(other.id). DB_HOST names \(instance.id). \(Self.fixText(other))",
                    suggestedDBHost: "127.0.0.1:\(other.port)"
                )
            }
        }

        return DatabaseCheck(instance: instance.id, exists: false)
    }

    // DB_HOST names a server that Nexus did not make, for example MAMP PRO, and no Nexus instance
    // holds the database. Nexus does not change that server (D37). So the database comes to Nexus
    // first, and DB_HOST changes after the copy (owner, 2026-11-07). Without a running instance the
    // old text applies.
    private func otherServer(_ config: WordPressConfig, in instances: [DatabaseInstance]) async -> DatabaseCheck? {
        guard let name = config.database, let address = config.address, case .tcp = address, let target = Self.instanceForNewDatabase(in: instances) else {
            return nil
        }

        // A port on this Mac where nothing listens is no server, for example an old port of Nexus.
        if let port = address.localPort, !PortInspector.acceptsConnections(port) {
            return nil
        }

        guard await holder(of: name, in: instances) == nil else {
            return nil
        }

        return DatabaseCheck(
            problem: "DB_HOST names \(config.host ?? ""). Nexus did not make that server. So Nexus does not change the URLs there. Copy the database \(name) to \(target.id) first. Then set DB_HOST to its port. Change the URLs after that.",
            copyInstance: target.id
        )
    }

    private func holder(of database: String, in instances: [DatabaseInstance]) async -> DatabaseInstance? {
        for instance in instances where instance.running {
            if await holds(database, instance: instance) {
                return instance
            }
        }

        return nil
    }

    private static func fixText(_ suggested: DatabaseInstance?) -> String {
        guard let suggested else {
            return "Install MySQL 8.4 on the Packages screen. Then set DB_HOST to 127.0.0.1 with its port."
        }

        return "Set DB_HOST to 127.0.0.1:\(suggested.port), the port of \(suggested.id)."
    }

    // The running instance that holds the database of the site. Else the instance that a new
    // database gets.
    private func suggestedInstance(for database: String?, in instances: [DatabaseInstance]) async -> DatabaseInstance? {
        if let database {
            for instance in instances where instance.running {
                if await holds(database, instance: instance) {
                    return instance
                }
            }
        }

        return Self.instanceForNewDatabase(in: instances) ?? instances.first
    }

    // MySQL 8.4 when it runs, else the newest MySQL that runs, else the newest MariaDB that runs
    // (owner, 2026-11-06).
    static func instanceForNewDatabase(in instances: [DatabaseInstance]) -> DatabaseInstance? {
        let running = instances.filter(\.running).sorted { first, second in
            guard (first.kind == .mysql) == (second.kind == .mysql) else {
                return first.kind == .mysql
            }

            return first.version.compare(second.version, options: .numeric) == .orderedDescending
        }

        return running.first { $0.id == "mysql-8.4" } ?? running.first
    }

    private struct SetUpPlan {
        let instance: DatabaseInstance
        let name: String
    }

    // The name comes from the host. A name that the instance has gets a number. Nil means that no
    // instance runs.
    private func setUpPlan(for target: WordPressTarget, in instances: [DatabaseInstance]) async throws -> SetUpPlan? {
        guard target.type == .wordpress, target.core != nil, target.configFile == nil else {
            return nil
        }

        guard let instance = Self.instanceForNewDatabase(in: instances) else {
            return nil
        }

        let (_, client, work) = try await runningClient(instance.id)
        defer { try? FileManager.default.removeItem(at: work) }

        let taken = Set(try await client.rows("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA").compactMap(\.first))
        let base = Self.databaseBase(of: target.site.host)
        let name = ([base] + (2...99).map { "\(base)_\($0)" }).first { !taken.contains($0) }

        guard let name else {
            throw RuntimeError.unsupported("\(instance.id) has the databases \(base) to \(base)_99 already.")
        }

        return SetUpPlan(instance: instance, name: name)
    }

    static func databaseBase(of host: String) -> String {
        let label = host.split(separator: ".").first.map(String.init) ?? "wordpress"
        let name = String(label.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }.prefix(50))
        return name.isEmpty ? "wordpress" : name.lowercased()
    }

    private func holds(_ database: String, instance: DatabaseInstance) async -> Bool {
        guard let (_, client, work) = try? await runningClient(instance.id) else {
            return false
        }

        defer { try? FileManager.default.removeItem(at: work) }

        return (try? await client.query(Self.countOfSchema(database))) == "1"
    }

    // DatabaseClient.exists needs a name without quotes. The name of wp-config.php can have any
    // character.
    static func countOfSchema(_ name: String) -> String {
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(sqlText(name))"
    }

    static func sqlText(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''"))'"
    }

    static func sqlName(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }
}
