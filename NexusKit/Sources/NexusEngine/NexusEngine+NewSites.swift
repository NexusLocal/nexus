import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces
import Synchronization

struct DatabaseLeftover: Sendable, Equatable {
    let instance: String
    let name: String
}

struct SiteLeftovers: Sendable, Equatable {
    var folder: URL
    var database: DatabaseLeftover?
}

struct SiteCreationFailed: Error {
    let failure: SiteCreationFailure
}

// What a new site made so far. The steps write it. A failure keeps it for "Move to trash", and a
// stop removes it at once.
final class NewSiteMade: Sendable {
    private let state: Mutex<SiteLeftovers>

    init(folder: URL) {
        state = Mutex(SiteLeftovers(folder: folder))
    }

    var current: SiteLeftovers {
        state.withLock { $0 }
    }

    func update(_ change: (inout SiteLeftovers) -> Void) {
        state.withLock { change(&$0) }
    }
}

private struct NewSiteStep: Sendable {
    let title: String
    let run: @Sendable () async throws -> Void
}

private struct NewSiteDatabase: Sendable {
    let instance: DatabaseInstance
    let name: String
    let account: DatabaseAccount

    var title: String {
        "Database \(name) on \(NexusEngine.instanceName(instance))"
    }
}

// The values that each step of one new site uses. project is the folder of the tool inside the
// hidden work folder. final is the folder of the site after the last step.
private struct NewSiteContext: Sendable {
    let site: NewSite
    let host: String
    let url: String
    let work: URL
    let project: URL
    let final: URL
    let log: URL
    let environment: [String: String]
    let php: InstalledRuntime?
    let node: InstalledRuntime?
    let database: NewSiteDatabase?
    let made: NewSiteMade
}

// A new site from a template (Phase 4, 3i to 3l). The tool runs in a hidden folder next to the new
// site, with the PHP, Composer and Node of Nexus first on the PATH. The steps, the log and Cancel
// show in the app. A failed site keeps its folder, its database and its log. Nexus never removes a
// folder or a database that it did not make.
extension NexusEngine {
    func createSite(_ request: NewSite) async throws -> CreatedSite {
        var site = request
        site.name = try NewSiteName.validated(request.name)

        let parent = try Self.validatedFolder(request.parent)
        let state = await stateStore.current()
        let host = try HostName.validated("\(site.name).\(state.tld)")
        let final = parent.appending(path: site.name, directoryHint: .isDirectory)
        let work = parent.appending(path: NewSiteName.workFolder(of: site.name), directoryHint: .isDirectory)
        try WebConfigPath.validate(final)

        if FileManager.default.fileExists(atPath: final.path(percentEncoded: false)) {
            throw RuntimeError.unsupported("\(Self.shortPath(final)) exists. Choose another name or another folder.")
        }

        if FileManager.default.fileExists(atPath: work.path(percentEncoded: false)) {
            throw RuntimeError.unsupported("\(Self.shortPath(work)) is left from an earlier new site. Move it to the Trash first.")
        }

        if resolvedSites(state).contains(where: { $0.site.hosts.contains(host) }) {
            throw RuntimeError.unsupported("\(host) belongs to a site already. Choose another name.")
        }

        // The host, the log and the database come from the name. So a second site with that name
        // waits, also in another folder.
        guard creatingSites.insert(host).inserted else {
            throw RuntimeError.unsupported("Nexus makes a site \(host) already. Wait until it is ready, or choose another name.")
        }

        defer { creatingSites.remove(host) }

        if site.template == .wordpress {
            site.adminUser = try Self.validatedAdminUser(site.adminUser)
            site.adminEmail = try Self.validatedAdminEmail(site.adminEmail, host: host)
        }

        let id = UUID().uuidString
        let bin = paths.run.appending(path: "new-site-\(id)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: bin) }

        let installed = await installer.installedRuntimes()
        let php = try await newSitePHP(site, installed: installed)
        let node = try newSiteNode(site, installed: installed)
        let environment = try await newSiteEnvironment(site, php: php, node: node, installed: installed, bin: bin)
        let database = try await newSiteDatabase(site)
        let log = paths.log("new-site-\(site.name)")

        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil) else {
            throw RuntimeError.unsupported("Nexus cannot write the log \(log.path(percentEncoded: false)).")
        }

        let context = NewSiteContext(
            site: site,
            host: host,
            url: Self.url(for: host, in: state),
            work: work,
            project: work.appending(path: site.name, directoryHint: .isDirectory),
            final: final,
            log: log,
            environment: environment,
            php: php,
            node: node,
            database: database,
            made: NewSiteMade(folder: work)
        )

        let password = Self.newPassword()
        let steps = try await newSiteSteps(context, password: password, installed: installed)
        let progress = TaskProgress()
        progress.update { values in
            values.steps = steps.map { TaskStep(title: $0.title) }
            values.logFile = log
            values.secrets = [password]
        }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)

            let name = site.name

            try await runTask(.createSite(name: name, template: site.template), id: id, progress: progress, stopped: {
                "The new site \(name) stopped. Nexus removed what it made."
            }) { progress in
                do {
                    for (index, step) in steps.enumerated() {
                        try Task.checkCancellation()
                        progress.start(step: index)
                        try await step.run()
                    }

                    progress.finishSteps()
                } catch where error is CancellationError || Task.isCancelled {
                    // A stopped program can end with an error of its own. The removal runs in a
                    // task of its own, because the stopped task would stop its programs too.
                    let made = context.made.current
                    let problems = await Task { await self.removeLeftovers(made) }.value

                    guard problems.isEmpty else {
                        throw RuntimeError.unsupported("The new site \(name) stopped, but Nexus could not remove all that it made. \(problems.joined(separator: " "))")
                    }

                    throw CancellationError()
                }
            }
        } catch let stopped as TaskStopped {
            throw stopped
        } catch {
            progress.failRunningStep()
            let (failedSteps, lines) = progress.stepsAndLog(lines: RunningTask.logLines)
            let made = context.made.current
            siteLeftovers[id] = made
            Self.removeFromLog(password, log)

            throw SiteCreationFailed(failure: SiteCreationFailure(
                id: id,
                message: String(describing: error),
                steps: failedSteps ?? [],
                log: lines ?? [],
                logFile: log.path(percentEncoded: false),
                folder: made.folder.path(percentEncoded: false),
                database: made.database.map { "\($0.name) on \($0.instance)" }
            ))
        }

        let wordPress = site.template == .wordpress
        return CreatedSite(
            host: host,
            url: context.url,
            folder: final.path(percentEncoded: false),
            message: "Nexus made \(site.template.displayName) in \(Self.shortPath(final)). Open \(context.url)",
            adminUser: wordPress ? site.adminUser : nil,
            adminPassword: wordPress ? password : nil
        )
    }

    func removeSiteLeftovers(id: String) async throws -> String {
        guard let leftovers = siteLeftovers[id] else {
            throw RuntimeError.unsupported("Nexus has nothing left of this new site. It was removed already, or nexusd started again.")
        }

        let problems = await removeLeftovers(leftovers)

        guard problems.isEmpty else {
            throw RuntimeError.unsupported(problems.joined(separator: " "))
        }

        siteLeftovers[id] = nil
        let database = leftovers.database.map { " and dropped the database \($0.name) on \($0.instance)" } ?? ""

        return "Nexus moved \(Self.shortPath(leftovers.folder)) to the Trash\(database)."
    }

    // Removes only what the new site made: its folder goes to the Trash, so the user can get it
    // back. The database is new and empty but for the migrations of the tool.
    private func removeLeftovers(_ leftovers: SiteLeftovers) async -> [String] {
        var problems: [String] = []

        if FileManager.default.fileExists(atPath: leftovers.folder.path(percentEncoded: false)) {
            do {
                try FileManager.default.trashItem(at: leftovers.folder, resultingItemURL: nil)
            } catch {
                problems.append("Nexus could not move \(Self.shortPath(leftovers.folder)) to the Trash: \(error.localizedDescription)")
            }
        }

        if let database = leftovers.database {
            do {
                let (tools, client, work) = try await runningClient(database.instance)
                defer { try? FileManager.default.removeItem(at: work) }
                try await client.query("DROP DATABASE IF EXISTS \(DatabaseConfig.identifier(database.name, kind: tools.kind))")
            } catch {
                problems.append("Nexus could not drop the database \(database.name) on \(database.instance): \(error)")
            }
        }

        return problems
    }

    private func newSiteSteps(_ context: NewSiteContext, password: String, installed: [InstalledRuntime]) async throws -> [NewSiteStep] {
        var steps: [NewSiteStep] = []

        switch context.site.template {
        case .laravel:
            if !Self.hasLaravelInstaller(at: paths.laravelInstaller) {
                steps.append(NewSiteStep(title: "Laravel installer \(SiteTemplateCommands.laravelInstallerVersion.replacingOccurrences(of: ".*", with: ""))") {
                    try await self.installLaravelInstaller(context, installed: installed)
                })
            }

            steps += databaseSteps(context)
            steps.append(NewSiteStep(title: "laravel new") {
                try await self.runLaravelNew(context)
            })
            steps.append(NewSiteStep(title: context.database == nil ? "APP_URL in .env" : "Database keys and APP_URL in .env") {
                try Self.writeLaravelEnv(context)
            })
        case .wordpress:
            let wpCLI = try await wpCLITool(php: context.php?.line ?? "")

            steps.append(NewSiteStep(title: "WordPress download") {
                try FileManager.default.createDirectory(at: context.project, withIntermediateDirectories: true)
                try await self.runWP(SiteTemplateCommands.wordPressDownload(context.site, path: context.project.path(percentEncoded: false)), wpCLI: wpCLI, context: context)
            })
            steps += databaseSteps(context)
            steps.append(NewSiteStep(title: "wp-config.php") {
                try await self.writeWordPressConfig(context, wpCLI: wpCLI)
            })
            steps.append(NewSiteStep(title: context.site.network == nil ? "WordPress install" : "Network install") {
                let arguments = SiteTemplateCommands.wordPressInstall(context.site, url: context.url, path: context.project.path(percentEncoded: false))
                defer { Self.removeFromLog(password, context.log) }

                do {
                    try await self.runWP(arguments, wpCLI: wpCLI, context: context, input: Data("\(password)\n".utf8))
                } catch CommandError.failed(let program, let status, let output) {
                    // The text of the error goes to errors.log, to the app and to a report.
                    throw CommandError.failed(program: program, status: status, output: output.replacingOccurrences(of: password, with: "…"))
                }

                Self.appendToLog("WordPress is installed. The admin user is \(context.site.adminUser).\n", context.log)
            })
        case .next, .nuxt, .vite, .astro:
            let creator = context.site.template.creator ?? ""
            let manager = context.site.packageManager.rawValue

            steps.append(NewSiteStep(title: creator.replacingOccurrences(of: "@", with: " ")) {
                try await self.runCreator(context)
            })
            steps.append(NewSiteStep(title: "\(manager) install") {
                try await self.runPackageInstall(context)
            })
        }

        if context.site.git {
            steps.append(NewSiteStep(title: "Git repository with a first commit") {
                try await self.makeRepository(context)
            })
        }

        steps.append(NewSiteStep(title: "Site on \(context.url)") {
            try await self.addNewSite(context)
        })

        return steps
    }

    private func databaseSteps(_ context: NewSiteContext) -> [NewSiteStep] {
        guard let database = context.database else {
            return []
        }

        return [NewSiteStep(title: database.title) {
            try await self.createNewSiteDatabase(database, context: context)
        }]
    }

    private func createNewSiteDatabase(_ database: NewSiteDatabase, context: NewSiteContext) async throws {
        let (tools, client, work) = try await runningClient(database.instance.id)
        defer { try? FileManager.default.removeItem(at: work) }

        Self.appendToLog("Nexus makes the database \(database.name) on \(database.instance.id).\n", context.log)
        try await client.query("CREATE DATABASE \(DatabaseConfig.identifier(database.name, kind: tools.kind))")
        context.made.update { $0.database = DatabaseLeftover(instance: database.instance.id, name: database.name) }
    }

    static func hasLaravelInstaller(at folder: URL) -> Bool {
        let manifest = folder.appending(path: "composer.json")
        let installer = folder.appending(path: "vendor/bin/laravel")

        guard FileManager.default.fileExists(atPath: installer.path(percentEncoded: false)),
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let require = json["require"] as? [String: String] else {
            return false
        }

        return require[SiteTemplateCommands.laravelInstaller] == SiteTemplateCommands.laravelInstallerVersion
    }

    // A second new Laravel site waits for the install that runs, because both would write the same
    // vendor folder. A stop of the other site does not count as a stop of this one.
    private func installLaravelInstaller(_ context: NewSiteContext, installed: [InstalledRuntime]) async throws {
        if let running = laravelInstallerInstall {
            Self.appendToLog("Another new site installs the Laravel installer. Nexus waits for it.\n", context.log)

            do {
                try await running.value
            } catch is CancellationError where !Task.isCancelled {
                throw RuntimeError.unsupported("The install of the Laravel installer for another new site stopped. Try again.")
            }

            return
        }

        if Self.hasLaravelInstaller(at: paths.laravelInstaller) {
            return
        }

        guard let php = context.php, let composer = Self.newest("composer", in: installed) else {
            throw RuntimeError.unsupported("Composer is not installed. Run: nexus install composer 2")
        }

        let folder = paths.laravelInstaller
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let arguments = [composer.pharFile.path(percentEncoded: false), "require", "\(SiteTemplateCommands.laravelInstaller):\(SiteTemplateCommands.laravelInstallerVersion)", "--no-interaction", "--no-progress"]
        let command = Command(executable: Self.phpBinary(php), arguments: arguments, environment: context.environment, workingDirectory: folder, name: "Composer")
        let install = Task {
            try await self.runLogged(command, display: "composer \(arguments.dropFirst().joined(separator: " "))", context: context)
        }

        laravelInstallerInstall = install
        defer { laravelInstallerInstall = nil }

        try await withTaskCancellationHandler {
            try await install.value
        } onCancel: {
            install.cancel()
        }
    }

    // laravel new runs artisan migrate with the .env that it writes, and that .env names port 3306.
    // On this Mac that can be MAMP PRO. Laravel does not replace an environment variable with a
    // value of the .env, so the database keys of Nexus go into the environment of the installer.
    private func runLaravelNew(_ context: NewSiteContext) async throws {
        guard let php = context.php else {
            return
        }

        var environment = context.environment

        if let database = context.database {
            environment.merge(Self.laravelDatabaseKeys(database)) { _, new in new }
        }

        let installer = paths.laravelInstaller.appending(path: "vendor/bin/laravel").path(percentEncoded: false)
        let arguments = SiteTemplateCommands.laravelNew(context.site, database: context.database?.instance.kind, hasNode: context.node != nil)

        try await runLogged(Command(executable: Self.phpBinary(php), arguments: [installer] + arguments, environment: environment, workingDirectory: context.work, name: "laravel new"), display: "laravel \(arguments.joined(separator: " "))", context: context)
    }

    static func laravelDatabaseKeys(_ database: some NewSiteDatabaseValues) -> [String: String] {
        [
            "DB_CONNECTION": SiteTemplateCommands.laravelConnection(database.kind),
            "DB_HOST": "127.0.0.1",
            "DB_PORT": String(database.port),
            "DB_DATABASE": database.databaseName,
            "DB_USERNAME": database.user,
            "DB_PASSWORD": database.password,
        ]
    }

    private static func writeLaravelEnv(_ context: NewSiteContext) throws {
        let file = context.project.appending(path: ".env")
        let text = try String(contentsOf: file, encoding: .utf8)
        var keys = ["APP_URL": context.url]

        if let database = context.database {
            keys.merge(Self.laravelDatabaseKeys(database)) { _, new in new }
        }

        Self.appendToLog("Nexus writes \(keys.keys.sorted().joined(separator: ", ")) into .env.\n", context.log)
        try Data(EnvRewrite.apply(to: text, hosts: [], keys: keys).utf8).write(to: file, options: .atomic)
    }

    private func runWP(_ arguments: [String], wpCLI: ToolCommand, context: NewSiteContext, input: Data? = nil, display: String? = nil) async throws {
        let environment = context.environment.merging(wpCLI.environment) { _, new in new }

        try await runLogged(Command(executable: URL(filePath: wpCLI.executable), arguments: wpCLI.arguments + arguments, environment: environment, workingDirectory: context.work, name: "WP-CLI"), display: display ?? "wp \(arguments.joined(separator: " "))", context: context, input: input)
    }

    private func writeWordPressConfig(_ context: NewSiteContext, wpCLI: ToolCommand) async throws {
        guard let database = context.database else {
            throw RuntimeError.unsupported("WordPress needs a MySQL or MariaDB of Nexus.")
        }

        let path = "--path=\(context.project.path(percentEncoded: false))"
        let shared = ["config", "create", path, "--dbname=\(database.name)", "--dbuser=\(database.account.user)", "--dbhost=127.0.0.1:\(database.instance.port)", "--skip-check"]

        try await runWP(shared + ["--dbpass=\(database.account.password)"], wpCLI: wpCLI, context: context, display: "wp \((shared + ["--dbpass=…"]).joined(separator: " "))")
        try await runWP(["config", "set", "WP_ENVIRONMENT_TYPE", "local", "--type=constant", path], wpCLI: wpCLI, context: context)
    }

    private func runCreator(_ context: NewSiteContext) async throws {
        guard let node = context.node, let arguments = SiteTemplateCommands.create(context.site) else {
            return
        }

        let npx = node.folder.appending(path: "lib/node_modules/npm/bin/npx-cli.js").path(percentEncoded: false)
        try await runLogged(Command(executable: Self.nodeBinary(node), arguments: [npx] + arguments, environment: context.environment, workingDirectory: context.work, name: context.site.template.creator ?? "npx"), display: "npx \(arguments.joined(separator: " "))", context: context)
    }

    private func runPackageInstall(_ context: NewSiteContext) async throws {
        guard let node = context.node else {
            return
        }

        let manager = context.site.packageManager
        let command: Command

        switch manager {
        case .npm:
            let npm = node.folder.appending(path: "lib/node_modules/npm/bin/npm-cli.js").path(percentEncoded: false)
            command = Command(executable: Self.nodeBinary(node), arguments: [npm, "install"], environment: context.environment, workingDirectory: context.project, name: "npm install")
        case .pnpm, .yarn:
            command = Command(executable: paths.corepackLinks.appending(path: manager.rawValue), arguments: ["install"], environment: context.environment, workingDirectory: context.project, name: "\(manager.rawValue) install")
        case .bun:
            throw RuntimeError.unsupported("Nexus makes a new site with npm, pnpm or yarn.")
        }

        try await runLogged(command, display: "\(manager.rawValue) install", context: context)
    }

    // Workspaces need git (open decision 5). The first commit skips the hooks and the signature of
    // the user, because nexusd cannot answer a prompt. A user without a name in git gets the name
    // of the Mac account in this one commit.
    private func makeRepository(_ context: NewSiteContext) async throws {
        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported("Nexus needs git for the repository. Run: xcode-select --install")
        }

        if context.site.template == .wordpress {
            try Self.addWordPressIgnore(in: context.project)
        }

        let gitCommand: @Sendable ([String], String) -> Command = { arguments, name in
            Command(executable: git, arguments: arguments, environment: context.environment, workingDirectory: context.project, name: name)
        }

        let hasIdentity = (try? await CommandRunner.run(gitCommand(["config", "user.email"], "git config"))) != nil
        let identity = hasIdentity ? [] : ["-c", "user.name=\(NSFullUserName())", "-c", "user.email=\(NSUserName())@localhost"]

        try await runLogged(gitCommand(["init", "-q"], "git init"), display: "git init", context: context)
        try await runLogged(gitCommand(["add", "-A"], "git add"), display: "git add -A", context: context)
        try await runLogged(gitCommand(identity + ["-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "Initial commit"], "git commit"), display: "git commit -m \"Initial commit\"", context: context)
    }

    // The repository of a new WordPress site ignores wp-config.php and the uploads. So a workspace of
    // the site gets its own wp-config.php at once (3e).
    static func addWordPressIgnore(in project: URL) throws {
        let file = project.appending(path: ".gitignore")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"

        try Data((existing + separator + SiteTemplateCommands.wordPressIgnore).utf8).write(to: file, options: .atomic)
    }

    private func addNewSite(_ context: NewSiteContext) async throws {
        try FileManager.default.moveItem(at: context.project, to: context.final)
        context.made.update { $0.folder = context.final }
        try? FileManager.default.removeItem(at: context.work)

        let site = context.site
        let settings = SiteChange(node: site.template.kind == .node ? context.node?.line : nil, runsAs: site.template.kind)
        let php = context.php?.line
        let message = try await serialWeb {
            try await self.addSite(folder: context.final.path(percentEncoded: false), host: context.host, aliases: [], php: php, server: nil, settings: settings)
        }

        Self.appendToLog("\(message)\n", context.log)
    }

    // Laravel 13 needs PHP 8.3 or newer (B.2), and Nexus also has PHP 8.2 (D13). A new WordPress
    // site gets the PHP of the WordPress defaults (owner, 2026-11-06).
    private func newSitePHP(_ site: NewSite, installed: [InstalledRuntime]) async throws -> InstalledRuntime? {
        let lines = installed.filter { $0.name == "php" }.map(\.line)

        switch site.template {
        case .laravel:
            let fitting = lines.filter { !VersionLine.isOlder($0, than: Self.laravelMinimumPHP) }
            let line = site.php ?? VersionLine.newest(fitting)

            guard let line, fitting.contains(line) else {
                throw RuntimeError.unsupported("Laravel 13 needs PHP \(Self.laravelMinimumPHP) or newer. Run: nexus install php 8.5")
            }

            return try installedPHP(line, in: installed)
        case .wordpress:
            let defaults = await stateStore.current().siteDefaults.forWordPress.installed(phpLines: lines, hasApache: Self.newest("httpd", in: installed) != nil)
            return try installedPHP(try await phpLine(site.php ?? defaults.php), in: installed)
        case .next, .nuxt, .vite, .astro:
            return nil
        }
    }

    static let laravelMinimumPHP = "8.3"

    private func newSiteNode(_ site: NewSite, installed: [InstalledRuntime]) throws -> InstalledRuntime? {
        let nodes = installed.filter { $0.name == "node" }

        if let line = site.node {
            guard let node = nodes.first(where: { $0.line == line }) else {
                throw RuntimeError.unsupported("Node \(line) is not installed. Run: nexus install node \(line)")
            }

            return node
        }

        let newest = Self.newest("node", in: installed)

        switch site.template {
        case .wordpress:
            return nil
        case .laravel:
            if newest == nil, site.starterKit != .none {
                throw RuntimeError.unsupported("The starter kit \(site.starterKit.displayName) needs Node.js. Run: nexus install node 24")
            }

            return newest
        case .next, .nuxt, .vite, .astro:
            guard let newest else {
                throw RuntimeError.unsupported("\(site.template.displayName) needs Node.js. Run: nexus install node 24")
            }

            return newest
        }
    }

    // The folder bin holds php and composer of the chosen PHP version. Composer scripts and the
    // Laravel installer find them on the PATH, before the links of Nexus that follow the folder.
    private func newSiteEnvironment(_ site: NewSite, php: InstalledRuntime?, node: InstalledRuntime?, installed: [InstalledRuntime], bin: URL) async throws -> [String: String] {
        var environment = ChildEnvironment.base()
        var path: [String] = []

        if let php {
            environment.merge(try await phpCommand(php).environment) { _, new in new }
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bin.appending(path: "php"), withDestinationURL: Self.phpBinary(php))

            if let composer = Self.newest("composer", in: installed) {
                let script = "#!/bin/sh\nexec \(WorkspaceKeys.shellWord(Self.phpBinary(php).path(percentEncoded: false))) \(WorkspaceKeys.shellWord(composer.pharFile.path(percentEncoded: false))) \"$@\"\n"
                let file = bin.appending(path: "composer")
                try Data(script.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
            }

            path += [bin.path(percentEncoded: false), php.folder.appending(path: "bin").path(percentEncoded: false)]
        }

        if let node {
            path.append(node.folder.appending(path: "bin").path(percentEncoded: false))
        }

        if site.template.kind == .node, site.packageManager.usesCorepack {
            if !FileManager.default.fileExists(atPath: paths.corepackLinks.appending(path: "pnpm").path(percentEncoded: false)) {
                try await installCorepack()
            }

            path.append(paths.corepackLinks.path(percentEncoded: false))
        }

        environment["PATH"] = (path + [ChildEnvironment.path]).joined(separator: ":")
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        environment["NO_UPDATE_NOTIFIER"] = "1"
        environment["npm_config_update_notifier"] = "false"
        environment["npm_config_fund"] = "false"

        return environment
    }

    // The database comes before the tool, with a free name (3b), because the Laravel installer and
    // WordPress need it during their run. A stopped instance starts first.
    private func newSiteDatabase(_ site: NewSite) async throws -> NewSiteDatabase? {
        guard site.template.isPHP else {
            return nil
        }

        guard let id = try await newSiteInstance(site) else {
            return nil
        }

        guard let instance = try await databaseInstances().first(where: { $0.id == id }) else {
            throw RuntimeError.unsupported("Nexus has no database instance \(id). See: nexus db list")
        }

        if site.template == .wordpress, !instance.kind.usesMySQLProtocol {
            throw RuntimeError.unsupported("WordPress needs MySQL or MariaDB. \(id) is \(instance.kind.displayName).")
        }

        if !instance.running {
            _ = try await serialWeb { try await self.start(id) }
        }

        let (tools, client, work) = try await runningClient(id)
        defer { try? FileManager.default.removeItem(at: work) }

        let name = try await freeDatabaseName(base: NewSiteName.databaseBase(of: site.name), on: client, kind: tools.kind, instance: id)
        return NewSiteDatabase(instance: instance, name: name, account: try await account(of: tools))
    }

    // WordPress without a choice gets the instance of "Set up WordPress": MySQL 8.4 when it runs,
    // else the newest MySQL or MariaDB that runs (owner, 2026-11-06), else one that is installed.
    private func newSiteInstance(_ site: NewSite) async throws -> String? {
        if let id = site.database {
            return id
        }

        guard site.template == .wordpress else {
            return nil
        }

        let instances = await mysqlInstances()

        guard let instance = Self.instanceForNewDatabase(in: instances) ?? instances.first(where: { $0.id == "mysql-8.4" }) ?? instances.first else {
            throw RuntimeError.unsupported("WordPress needs MySQL or MariaDB. Run: nexus install mysql 8.4")
        }

        return instance.id
    }

    static func instanceName(_ instance: DatabaseInstance) -> String {
        let line = instance.id.split(separator: "-").last.map(String.init) ?? instance.version
        return "\(instance.kind.displayName) \(line)"
    }

    private func runLogged(_ command: Command, display: String, context: NewSiteContext, input: Data? = nil) async throws {
        Self.appendToLog("$ \(display)\n", context.log)
        try await CommandRunner.run(command, appendingTo: context.log, input: input)
    }

    static func appendToLog(_ text: String, _ log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else {
            return
        }

        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    // A second guard after --quiet: a later WP-CLI can print the password in another line.
    static func removeFromLog(_ secret: String, _ log: URL) {
        guard let text = try? String(contentsOf: log, encoding: .utf8), text.contains(secret) else {
            return
        }

        try? Data(text.replacingOccurrences(of: secret, with: "…").utf8).write(to: log, options: .atomic)
    }

    private static func phpBinary(_ php: InstalledRuntime) -> URL {
        php.folder.appending(path: "bin/php")
    }

    private static func nodeBinary(_ node: InstalledRuntime) -> URL {
        node.folder.appending(path: "bin/node")
    }

    static func validatedAdminUser(_ user: String) throws -> String {
        let user = user.trimmingCharacters(in: .whitespaces)

        guard (1...60).contains(user.count), user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }) else {
            throw RuntimeError.unsupported("\(user.isEmpty ? "An empty name" : user) cannot be the admin user of WordPress. Use letters, digits, ., _, - and @.")
        }

        return user
    }

    static func validatedAdminEmail(_ email: String, host: String) throws -> String {
        let email = email.trimmingCharacters(in: .whitespaces)

        guard !email.isEmpty else {
            return "admin@\(host)"
        }

        let parts = email.split(separator: "@", omittingEmptySubsequences: false)

        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !email.contains(where: \.isWhitespace) else {
            throw RuntimeError.unsupported("\(email) is not an email address.")
        }

        return email
    }

    // 24 characters without the ones that look alike, such as l and 1, or O and 0.
    static func newPassword() -> String {
        let characters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+=?@^_")
        var generator = SystemRandomNumberGenerator()

        return String((0..<24).map { _ in characters.randomElement(using: &generator)! })
    }

    static func shortPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

// The values that a Laravel site gets for its database. The tests give them without a running
// instance.
protocol NewSiteDatabaseValues {
    var kind: DatabaseKind { get }
    var port: Int { get }
    var databaseName: String { get }
    var user: String { get }
    var password: String { get }
}

extension NewSiteDatabase: NewSiteDatabaseValues {
    var kind: DatabaseKind { instance.kind }
    var port: Int { instance.port }
    var databaseName: String { name }
    var user: String { account.user }
    var password: String { account.password }
}
