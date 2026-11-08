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

            return envFile(setting: "DB_HOST") ?? bedrockFiles.first
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

        // The last file of Bedrock that sets this key.
        func envFile(setting key: String) -> URL? {
            bedrockFiles.last { EnvFile.values(of: $0)[key] != nil }
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
            suggestedUser: Self.suggestedAccount(for: database, config: config, in: instances)?.user,
            url: Self.url(for: target.site.host, in: state),
            configHome: Self.literalHome(of: config),
            configHomeFile: Self.literalHome(of: config) == nil ? nil : target.homeFile.map { Self.displayPath($0) },
            urlPlan: urlPlan(of: target, config: config, check: database, in: state),
            urlChange: urlChange(of: target.site.host, database: config.database, instance: database.instance, in: state),
            copyInstance: database.copyInstance,
            workspaceLines: await workspaceLines(of: target),
            network: Self.network(count: database.blogCount, blogs: database.blogs, site: target.site, configName: target.configName, tld: state.tld)
        )
    }

    // The kind of a network comes from its configuration, as for nginx (3g). A second site on a
    // subdomain of the main site without that kind means that Nexus cannot read SUBDOMAIN_INSTALL.
    // The example has no port, as the address bar shows it.
    static func network(count: Int?, blogs: [[String]]?, site: Site, configName: String, tld: String) -> WordPressNetwork? {
        let sites = (blogs ?? []).compactMap { $0.count == 2 ? (domain: Self.withoutPort($0[0]), path: $0[1]) : nil }

        guard let count, let main = sites.first else {
            return nil
        }

        let second = sites.dropFirst().first
        let layout = SiteLayout(of: site)
        let onSubdomain = second.map { $0.domain.hasSuffix(".\(main.domain)") } ?? false
        let subdomains = layout.subdomainNetwork || onSubdomain
        let served = layout.hosts(of: site, tld: tld).contains("*.\(site.host)")
        let example = second.map { subdomains ? $0.domain : $0.domain + ($0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path) }
        var problem: String?

        if subdomains, !served {
            problem = site.host.hasSuffix(".\(tld)")
                ? "The sites of this network are on subdomains, but Nexus cannot read SUBDOMAIN_INSTALL in \(configName) as plain text. Add *.\(site.host) as an alias of this site."
                : "The sites of this network need the names below \(site.host). Only a name in the dev domain .\(tld) can have them. Give the site a host in .\(tld)."
        }

        return WordPressNetwork(host: site.host, subdomains: subdomains, sites: count, example: example, problem: problem)
    }

    private static func withoutPort(_ domain: String) -> String {
        domain.split(separator: ":").first.map(String.init) ?? domain
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
    // With user, DB_USER and DB_PASSWORD get the account of the instance too, because a copy from
    // MAMP PRO keeps the account of MAMP PRO (owner, 2026-11-07). The password never leaves nexusd.
    func setWordPressDBHost(host: String, value: String, user: String?) async throws -> String {
        let target = try await wordPressTarget(host)

        guard let config = target.config, let file = target.shownFile else {
            throw RuntimeError.unsupported("\(host) has no \(target.configName).")
        }

        let instances = await mysqlInstances()
        let check = await databaseCheck(of: config, in: instances)

        guard let suggested = check.suggestedDBHost else {
            throw RuntimeError.unsupported("DB_HOST of \(host) needs no change. Nexus changes nothing.")
        }

        let account = Self.suggestedAccount(for: check, config: config, in: instances)

        guard suggested == value, account?.user == user else {
            throw RuntimeError.unsupported("Nexus would now set DB_HOST of \(host) to \(suggested)\(account.map { " with the user \($0.user)" } ?? ""). Set DB_HOST again to confirm this.")
        }

        var keys: [String: String] = [:]

        // When only the account is wrong, DB_HOST keeps its line.
        if config.host != value {
            keys["DB_HOST"] = value
        }

        if let account, config.user != account.user {
            keys["DB_USER"] = account.user
        }

        if let account, (config.password ?? "") != account.password {
            keys["DB_PASSWORD"] = account.password
        }

        var texts: [URL: String] = [:]

        if target.type == .bedrock {
            let env = EnvFile.values(of: target.project.appending(path: ".env")).merging(EnvFile.values(of: target.project.appending(path: ".env.local"))) { _, local in local }

            guard env["DATABASE_URL"]?.isEmpty != false else {
                throw RuntimeError.unsupported("\(host) sets DATABASE_URL, which wins over DB_HOST. Change the host in DATABASE_URL yourself.")
            }

            // Each key goes into the file that sets it, because .env.local wins over .env.
            for (key, keyValue) in keys {
                let keyFile = target.envFile(setting: key) ?? file
                let text = try texts[keyFile] ?? String(contentsOf: keyFile, encoding: .utf8)
                texts[keyFile] = EnvRewrite.applyKeepingOldValues(to: text, keys: [key: keyValue])
            }
        } else {
            var text = try String(contentsOf: file, encoding: .utf8)

            for key in ["DB_HOST", "DB_USER", "DB_PASSWORD"] {
                guard let keyValue = keys[key] else {
                    continue
                }

                guard let changed = WordPressFiles.settingConstant(key, to: keyValue, in: text) else {
                    throw RuntimeError.unsupported("wp-config.php of \(host) has no single line that defines \(key), or the value needs a quote. Change it there yourself. Nexus changed nothing.")
                }

                text = changed
            }

            texts[file] = text
        }

        try Self.writeAll(texts)

        let changed = ["DB_HOST", "DB_USER", "DB_PASSWORD"].filter { keys[$0] != nil }
        let files = EnglishList.joined(texts.keys.map(\.lastPathComponent).sorted())
        let old = changed.count == 1 ? "The old line stays in \(files) as a comment line." : "The old lines stay in \(files) as comment lines."
        return "Nexus changed \(EnglishList.joined(changed)) of \(host). \(old)"
    }

    // All files or none: a failed write puts back the files that this call wrote already. A file
    // that was not there goes again, for example a new .gitignore (3e).
    static func writeAll(_ texts: [URL: String]) throws {
        var written: [(URL, String?)] = []

        for (file, text) in texts {
            let path = file.path(percentEncoded: false)

            do {
                let old = FileManager.default.fileExists(atPath: path) ? try String(contentsOf: file, encoding: .utf8) : nil

                if old == nil {
                    try Data(text.utf8).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
                } else {
                    try write(text, to: path)
                }

                written.append((file, old))
            } catch {
                for (writtenFile, old) in written {
                    if let old {
                        try? write(old, to: writtenFile.path(percentEncoded: false))
                    } else {
                        try? FileManager.default.removeItem(at: writtenFile)
                    }
                }

                throw RuntimeError.unsupported("Nexus could not write \(file.lastPathComponent). \(error) Nexus changed nothing.")
            }
        }
    }

    // The account of the instance that DB_HOST gets, when the configuration has another account.
    static func suggestedAccount(for check: DatabaseCheck, config: WordPressConfig, in instances: [DatabaseInstance]) -> DatabaseAccount? {
        guard let value = check.suggestedDBHost, let port = DatabaseAddress(dbHost: value).localPort, let instance = instances.first(where: { $0.port == port }) else {
            return nil
        }

        let account = instance.account
        return config.user == account.user && (config.password ?? "") == account.password ? nil : account
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
    // The closure gives the output of WP-CLI. A worktree is no site of Nexus. So the setup of its
    // workspace gives the PHP version of the site.
    func wpCLICommand(in core: URL, failure: String, php line: String? = nil) async throws -> @Sendable ([String]) async throws -> String {
        let folder = core.path(percentEncoded: false)
        let tool: ToolCommand

        do {
            if let line {
                tool = try await wpCLITool(php: line)
            } else {
                tool = try await toolCommand(.wp, folder: folder)
            }
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
        // The number of sites of a network, and the domain and the path of its first two sites, from
        // wp_blogs (3g).
        var blogCount: Int?
        var blogs: [[String]]?
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
            // A site that is no network has no table of sites (3g). The row needs the number and two
            // sites.
            let blogTable = "\(Self.sqlName(name)).\(Self.sqlName("\(prefix)blogs"))"
            let blogCount = (try? await client.query("SELECT COUNT(*) FROM \(blogTable)")).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let blogs = blogCount == nil ? nil : try? await client.rows("SELECT domain, path FROM \(blogTable) ORDER BY blog_id LIMIT 2")

            // A copy from MAMP PRO keeps its account in wp-config.php, also when DB_HOST is right.
            guard await logsIn(config, on: instance) else {
                return DatabaseCheck(
                    instance: instance.id,
                    exists: true,
                    home: values["home"],
                    siteURL: values["siteurl"],
                    problem: "WordPress cannot log in to \(instance.id) with DB_USER and DB_PASSWORD of the configuration. Set them to the account of \(instance.id).",
                    suggestedDBHost: "127.0.0.1:\(instance.port)",
                    blogCount: blogCount,
                    blogs: blogs
                )
            }

            return DatabaseCheck(instance: instance.id, exists: true, home: values["home"], siteURL: values["siteurl"], blogCount: blogCount, blogs: blogs)
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

    // The account of the instance always works. Another account can exist on the instance, so
    // Nexus tries it before it calls it wrong.
    private func logsIn(_ config: WordPressConfig, on instance: DatabaseInstance) async -> Bool {
        let account = DatabaseAccount(user: config.user ?? "", password: config.password ?? "")

        guard account != instance.account, let tools = await databaseRuntime(instance.id), let (client, work) = try? preparedClient(tools, port: instance.port, account: account) else {
            return true
        }

        defer { try? FileManager.default.removeItem(at: work) }

        return (try? await client.query("SELECT 1")) != nil
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
