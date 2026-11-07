import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// The site URL and HTTPS of a WordPress site (Phase 4, 3d). Nexus changes the URLs only in a
// database on a Nexus instance (D37). A dump goes to the trash first (D53). So "Undo…" can put the
// database back until the trash removes the dump (owner, 2026-11-07).
extension NexusEngine {
    typealias WPCLI = @Sendable ([String]) async throws -> String

    private struct FileText {
        let path: String
        let text: String
    }

    // A value with ${ comes from another key of the .env. Nexus does not follow it.
    static func literalHome(of config: WordPressConfig) -> String? {
        config.home.flatMap { $0.isEmpty || $0.contains("${") ? nil : $0 }
    }

    // Nexus compares the home option of the database and WP_HOME of the configuration with its own
    // URL. A plan needs a database that Nexus can read on its own instance.
    func urlPlan(of target: WordPressTarget, config: WordPressConfig, check: DatabaseCheck, in state: EngineState) -> WordPressURLPlan? {
        guard check.instance != nil, check.exists == true, let home = check.home else {
            return nil
        }

        let url = Self.url(for: target.site.host, in: state)
        let address = WordPressURL.siteAddress(home: home, isBedrock: target.type == .bedrock, config: config)
        let databaseFrom = WordPressURL.same(address, url) ? nil : address
        let configFrom = Self.literalHome(of: config).flatMap { WordPressURL.same($0, url) ? nil : $0 }

        guard databaseFrom != nil || configFrom != nil else {
            return nil
        }

        return WordPressURLPlan(to: url, databaseFrom: databaseFrom, configFrom: configFrom, configFile: configFrom == nil ? nil : target.homeFile.map { Self.displayPath($0) })
    }

    // The trash removes a dump after the days of the setting. The change then has no way back. A
    // site that uses another database now has no way back either.
    func urlChange(of host: String, database: String?, instance: String?, in state: EngineState) -> WordPressURLChange? {
        guard var change = state.wordPressURLChanges[host], change.database == database, change.instance == instance else {
            return nil
        }

        if let dump = change.dump, !FileManager.default.fileExists(atPath: dump) {
            return nil
        }

        change.expires = change.date.addingTimeInterval(Double(state.workspaceSettings.dumpDays) * 86_400)
        return change.expires > .now ? change : nil
    }

    func changeWordPressURLs(host: String, plan: WordPressURLPlan) async throws -> String {
        let target = try await wordPressTarget(host)
        let state = await stateStore.current()

        guard let config = target.config, let database = config.database else {
            throw RuntimeError.unsupported("The configuration of \(host) names no database.")
        }

        let check = await databaseCheck(of: config, in: await mysqlInstances())

        guard let instance = check.instance, check.exists == true else {
            throw RuntimeError.unsupported(check.problem ?? "Nexus changes the URLs only in a database on a Nexus instance.")
        }

        guard let current = urlPlan(of: target, config: config, check: check, in: state) else {
            throw RuntimeError.unsupported("The URLs of \(host) need no change. Nexus changes nothing.")
        }

        guard current == plan else {
            throw RuntimeError.unsupported("The URLs of \(host) are not the same as at the check. Check the site again.")
        }

        guard let core = target.core else {
            throw RuntimeError.unsupported("Nexus does not find the files of WordPress in \(host).")
        }

        let name = try DatabaseName.validated(database)
        let wpCLI = try await wpCLICommand(in: core, failure: "WP-CLI did not change the URLs.")
        let networkDomain: String?

        // WP-CLI connects with the account of wp-config.php. A wrong account stops here, before the
        // dump. The domain of a network comes from WordPress, because Bedrock can set MULTISITE in
        // its PHP configuration.
        do {
            let domain = try await wpCLI(["eval", "echo is_multisite() ? get_network()->domain : '';", "--skip-plugins", "--skip-themes"]).trimmingCharacters(in: .whitespacesAndNewlines)
            networkDomain = domain.isEmpty ? nil : domain
        } catch {
            throw RuntimeError.unsupported("WordPress cannot read the database \(name) with DB_USER and DB_PASSWORD of \(target.configName). Nexus changed nothing. \(error)")
        }

        let newDomain = WordPressURL.domain(of: plan.to)
        let changedDomain = networkDomain.flatMap { $0 == newDomain ? nil : $0 }

        // A file that Nexus cannot change stops the change here, before the dump.
        _ = try await fileTexts(of: target, config: config, plan: plan, networkDomain: changedDomain)

        let reserved = try reserveCopyTarget(name, on: instance, for: "change of the URLs")
        defer { copyTargets.remove(reserved) }

        let (tools, client, work) = try await runningClient(instance)
        defer { try? FileManager.default.removeItem(at: work) }

        let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)
        try copier.prepare()

        let dump = try await writeDump(of: name, as: "\(name)-before-url-change", with: copier, instance: instance, kind: tools.kind)
        var replacements = 0

        do {
            for from in plan.oldURLs {
                replacements += try await replaceURLs(from: from, to: plan.to, network: networkDomain != nil, with: wpCLI)
            }

            // WordPress finds a network by DOMAIN_CURRENT_SITE and wp_site. So the domain changes
            // last, after the last run of WP-CLI.
            if let changedDomain, let newDomain, let prefix = config.safeTablePrefix {
                try await changeNetworkDomain(from: changedDomain, to: newDomain, database: name, prefix: prefix, with: client)
            }
        } catch {
            throw await putBack(dump, into: name, instance: instance, with: copier, after: error)
        }

        let change = WordPressURLChange(plan: plan, database: name, instance: instance, dump: dump.path(percentEncoded: false), replacements: replacements, date: .now, expires: .now, networkDomain: changedDomain)

        try await stateStore.update { state in
            state.wordPressURLChanges = state.wordPressURLChanges.filter { $0.value.dump.map { FileManager.default.fileExists(atPath: $0) } ?? true }
            state.wordPressURLChanges[target.site.host] = change
        }

        var lines = ["Nexus replaced \(EnglishList.joined(plan.oldURLs)) with \(plan.to) in \(Self.count(replacements, "place")). The trash keeps the old database as \(dump.lastPathComponent)."]

        // The files are read again now, because a user can change them during a long change.
        do {
            let files = try await fileTexts(of: target, config: config, plan: plan, networkDomain: changedDomain)

            for file in files.texts {
                try Self.write(file.text, to: file.path)
            }

            if plan.configFrom != nil, let file = target.homeFile {
                lines.append("WP_HOME in \(file.lastPathComponent) is \(plan.to) now. The old line stays as a comment line.")
            }

            return (lines + files.notes).joined(separator: " ")
        } catch {
            throw RuntimeError.unsupported("\(lines.joined(separator: " ")) But Nexus did not change the configuration. \(error) \"Undo…\" puts back the database.")
        }
    }

    func undoWordPressURLChange(host: String, plan: WordPressURLPlan) async throws -> String {
        let target = try await wordPressTarget(host)
        var instance: String?

        if let config = target.config {
            instance = await databaseCheck(of: config, in: await mysqlInstances()).instance
        }

        guard let change = urlChange(of: target.site.host, database: target.config?.database, instance: instance, in: await stateStore.current()), change.plan == plan else {
            throw RuntimeError.unsupported("Nexus has no change of the URLs of \(host) that it can undo.")
        }

        var lines: [String] = []

        if let path = change.dump {
            let reserved = try reserveCopyTarget(change.database, on: change.instance, for: "undo")
            defer { copyTargets.remove(reserved) }

            let (tools, client, work) = try await runningClient(change.instance)
            defer { try? FileManager.default.removeItem(at: work) }

            let copier = DatabaseCopier(tools: tools, source: client.endpoint, target: client.endpoint, work: work)
            try copier.prepare()

            // Each drop gets a dump first (D53). So the undo has a way back too.
            if try await copier.exists(change.database) {
                let before = try await writeDump(of: change.database, as: "\(change.database)-before-undo", with: copier, instance: change.instance, kind: tools.kind)
                try await copier.drop(change.database)
                lines.append("The trash keeps the database of before the undo as \(before.lastPathComponent).")
            }

            do {
                try await copier.restore(URL(filePath: path), as: change.database)
            } catch {
                throw RuntimeError.unsupported("Nexus could not put back the database \(change.database). \(error) The dumps stay in the trash. See: nexus db dumps")
            }

            lines.insert("Nexus put back the database \(change.database) from the dump of \(Self.changeTime(change.date)).", at: 0)
        }

        lines += try restoreFiles(of: target, change: change)

        try await stateStore.update { $0.wordPressURLChanges[target.site.host] = nil }
        return lines.joined(separator: " ")
    }

    func wordPressCopySource(host: String) async throws -> WordPressCopySource {
        let target = try await wordPressTarget(host)

        guard let config = target.config, let database = config.database, case .tcp(let address, let port) = config.address else {
            throw RuntimeError.unsupported("DB_HOST of \(host) names no server that Nexus can copy from.")
        }

        guard let instance = await databaseCheck(of: config, in: await mysqlInstances()).copyInstance else {
            throw RuntimeError.unsupported("The database of \(host) needs no copy. Check the site again.")
        }

        let account = DatabaseAccount(user: config.user ?? DatabaseAccount.standard.user, password: config.password ?? "")
        return WordPressCopySource(server: DatabaseServer(host: address, port: port, account: account), database: database, instance: instance)
    }

    // https comes before http in each form, so no pass finds the text of the pass before it.
    private func replaceURLs(from: String, to: String, network: Bool, with wpCLI: WPCLI) async throws -> Int {
        var count = 0

        for pass in WordPressURL.replacements(from: from, to: to) {
            count += try await searchReplace(pass, options: ["--all-tables-with-prefix", "--skip-columns=guid"] + (network ? ["--network"] : []), with: wpCLI)
        }

        return count
    }

    // The domain of the network, and the domain of each site of a subdomain network. These columns
    // hold a plain domain, so SQL changes them without WordPress.
    private func changeNetworkDomain(from old: String, to new: String, database: String, prefix: String, with client: DatabaseClient) async throws {
        let blogs = "\(Self.sqlName(database)).\(Self.sqlName("\(prefix)blogs"))"
        let site = "\(Self.sqlName(database)).\(Self.sqlName("\(prefix)site"))"
        let oldText = Self.sqlText(old)
        let newText = Self.sqlText(new)

        try await client.query("UPDATE \(blogs) SET domain = \(newText) WHERE domain = \(oldText)")
        try await client.query("UPDATE \(blogs) SET domain = CONCAT(LEFT(domain, CHAR_LENGTH(domain) - CHAR_LENGTH(\(oldText))), \(newText)) WHERE CHAR_LENGTH(domain) > CHAR_LENGTH(\(oldText)) AND RIGHT(domain, CHAR_LENGTH(\(oldText)) + 1) = CONCAT('.', \(oldText))")
        try await client.query("UPDATE \(site) SET domain = \(newText) WHERE domain = \(oldText)")
    }

    private func searchReplace(_ pass: TextReplacement, options: [String], with wpCLI: WPCLI) async throws -> Int {
        let output = try await wpCLI(["search-replace", pass.search, pass.replace] + options + ["--skip-plugins", "--skip-themes", "--format=count"])
        let count = output.split(whereSeparator: \.isNewline).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0

        return pass.counts ? count : 0
    }

    // A failed pass leaves a half change. So the dump comes back at once.
    private func putBack(_ dump: URL, into name: String, instance: String, with copier: DatabaseCopier, after error: any Error) async -> RuntimeError {
        do {
            try await copier.drop(name)
            try await copier.restore(dump, as: name)
            return RuntimeError.unsupported("\(error) Nexus put back the database \(name) from the dump.")
        } catch let restoreError {
            return RuntimeError.unsupported("\(error) Nexus could not put back the database \(name) either. \(restoreError) Put it back with: nexus db restore \(dump.lastPathComponent) --to \(instance) --as \(name)")
        }
    }

    private struct FileTexts {
        var texts: [FileText] = []
        var notes: [String] = []
    }

    // WP_HOME, WP_SITEURL when it starts with the old WP_HOME, and DOMAIN_CURRENT_SITE of a network.
    // The old lines stay as comment lines (owner, 2026-11-07). A comment line of an earlier change
    // goes, so "Undo…" puts back the value of just before this change. DOMAIN_CURRENT_SITE changes
    // only in a file that git does not see (D50). Else a note says what to change.
    private func fileTexts(of target: WordPressTarget, config: WordPressConfig, plan: WordPressURLPlan, networkDomain: String?) async throws -> FileTexts {
        var texts: [String: String] = [:]
        var notes: [String] = []
        let isBedrock = target.type == .bedrock

        func text(of file: URL) throws -> String {
            let path = file.path(percentEncoded: false)
            return try texts[path] ?? String(contentsOfFile: path, encoding: .utf8)
        }

        if let from = plan.configFrom {
            guard let file = target.homeFile else {
                throw RuntimeError.unsupported("Nexus does not find the file that sets WP_HOME of \(target.site.host).")
            }

            let current = try text(of: file)

            if isBedrock {
                var keys = ["WP_HOME": plan.to]

                if let siteURL = EnvFile.values(in: current)["WP_SITEURL"].flatMap({ Self.moved($0, from: from, to: plan.to) }) {
                    keys["WP_SITEURL"] = siteURL
                }

                texts[file.path(percentEncoded: false)] = EnvRewrite.applyKeepingOldValues(to: EnvRewrite.removingOldValues(in: current, keys: Set(keys.keys)), keys: keys)
            } else {
                guard var changed = WordPressFiles.settingConstant("WP_HOME", to: plan.to, in: current, replacingOldLine: true) else {
                    throw RuntimeError.unsupported("\(file.lastPathComponent) of \(target.site.host) has no single line that defines WP_HOME. Change it there yourself. Nexus changed nothing.")
                }

                if let siteURL = config.siteURL.flatMap({ Self.moved($0, from: from, to: plan.to) }), let withSiteURL = WordPressFiles.settingConstant("WP_SITEURL", to: siteURL, in: changed, replacingOldLine: true) {
                    changed = withSiteURL
                }

                texts[file.path(percentEncoded: false)] = changed
            }
        }

        if networkDomain != nil, let domain = WordPressURL.domain(of: plan.to) {
            let file = target.domainFile
            var changed: String?

            if let file, await Self.gitDoesNotSee(file) {
                let current = try text(of: file)

                changed = isBedrock
                    ? EnvRewrite.applyKeepingOldValues(to: EnvRewrite.removingOldValues(in: current, keys: ["DOMAIN_CURRENT_SITE"]), keys: ["DOMAIN_CURRENT_SITE": domain])
                    : WordPressFiles.settingConstant("DOMAIN_CURRENT_SITE", to: domain, in: current, replacingOldLine: true)
            }

            if let file, let changed {
                texts[file.path(percentEncoded: false)] = changed
            } else {
                notes.append("Set DOMAIN_CURRENT_SITE in \(file?.lastPathComponent ?? target.configName) to \(domain) yourself.")
            }
        }

        return FileTexts(texts: texts.map { FileText(path: $0.key, text: $0.value) }, notes: notes)
    }

    private static func gitDoesNotSee(_ file: URL) async -> Bool {
        guard let git = await GitTool.executable() else {
            return false
        }

        let folder = file.deletingLastPathComponent().path(percentEncoded: false)

        if (try? await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "rev-parse", "--is-inside-work-tree"]))) == nil {
            return true
        }

        return (try? await GitTool.ignores(file.lastPathComponent, in: folder, git: git)) == true
    }

    private func restoreFiles(of target: WordPressTarget, change: WordPressURLChange) throws -> [String] {
        var lines: [String] = []

        if change.plan.configFrom != nil, let file = target.homeFile, try restore(["WP_HOME", "WP_SITEURL"], in: file, isBedrock: target.type == .bedrock) {
            lines.append("WP_HOME in \(file.lastPathComponent) has its old value again.")
        }

        if change.networkDomain != nil, let file = target.domainFile, try restore(["DOMAIN_CURRENT_SITE"], in: file, isBedrock: target.type == .bedrock) {
            lines.append("DOMAIN_CURRENT_SITE in \(file.lastPathComponent) has its old value again.")
        }

        return lines
    }

    private func restore(_ names: [String], in file: URL, isBedrock: Bool) throws -> Bool {
        let path = file.path(percentEncoded: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var restored = text

        if isBedrock {
            restored = EnvRewrite.restoringOldValues(in: text, keys: Set(names)).text
        } else {
            for name in names {
                restored = WordPressFiles.restoringConstant(name, in: restored) ?? restored
            }
        }

        guard restored != text else {
            return false
        }

        try Self.write(restored, to: path)
        return true
    }

    // A URL below the old WP_HOME moves below the new one, for example WP_SITEURL of Bedrock.
    static func moved(_ url: String, from old: String, to new: String) -> String? {
        let base = old.hasSuffix("/") ? String(old.dropLast()) : old
        let rest = url.dropFirst(base.count)

        guard url.hasPrefix(base), rest.isEmpty || rest.hasPrefix("/"), !url.contains("${") else {
            return nil
        }

        return (new.hasSuffix("/") ? String(new.dropLast()) : new) + rest
    }

    static func changeTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM 'at' HH:mm"
        return formatter.string(from: date)
    }
}
