import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

public enum NexusCLI {
    // A link such as php or node runs its tool first, so node sendmail runs sendmail.js and not
    // nexus sendmail.
    public static func main() async {
        if let invocation = toolInvocation(CommandLine.arguments) {
            do {
                try await runTool(invocation.tool, invocation.arguments, throughLink: invocation.throughLink)
            } catch {
                NexusCommand.exit(withError: error)
            }
        }

        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "sendmail" {
            exit(SendmailRun.run(Array(CommandLine.arguments.dropFirst(2))))
        }

        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == DumpFilterRun.name {
            signal(SIGPIPE, SIG_IGN)
            exit(DumpFilterRun.run(Array(CommandLine.arguments.dropFirst(2))))
        }

        await NexusCommand.main()
    }

    struct ToolInvocation: Equatable {
        let tool: ProjectTool
        let arguments: [String]
        let throughLink: Bool
    }

    // A link in bin/ with the name php runs as nexus php (D39). The arguments of a tool go to the
    // tool as they are, also --help and -v. So they do not go through the parser.
    static func toolInvocation(_ arguments: [String]) -> ToolInvocation? {
        if let name = arguments.first.map({ URL(filePath: $0).lastPathComponent }), let tool = ProjectTool(rawValue: name) {
            return ToolInvocation(tool: tool, arguments: Array(arguments.dropFirst()), throughLink: true)
        }

        if arguments.count > 1, let tool = ProjectTool(rawValue: arguments[1]) {
            return ToolInvocation(tool: tool, arguments: Array(arguments.dropFirst(2)), throughLink: false)
        }

        return nil
    }

    // The first program with this name on the PATH that is not the nexus command. Each link in
    // bin/ is the nexus command.
    static func nextProgram(named name: String, path: String, nexus: String) -> String? {
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = URL(filePath: String(folder), directoryHint: .isDirectory).appending(path: name)
            let file = candidate.path(percentEncoded: false)

            if FileManager.default.isExecutableFile(atPath: file), RealPath.of(candidate) != nexus {
                return file
            }
        }

        return nil
    }

    // The PATH without the folders that hold a link to the nexus command. A script of the next
    // program then runs the next php or node too, and nexus does not try nexusd again for it.
    static func path(_ path: String, without nexus: String) -> String {
        path.split(separator: ":", omittingEmptySubsequences: false)
            .filter { folder in
                folder.isEmpty || CommandLinks.names.allSatisfy { name in
                    RealPath.of(URL(filePath: String(folder), directoryHint: .isDirectory).appending(path: name)) != nexus
                }
            }
            .joined(separator: ":")
    }
}

struct NexusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nexus",
        abstract: "Controls the Nexus services from the terminal.",
        version: NexusVersion.current(),
        subcommands: [
            Status.self, Start.self, Stop.self, Restart.self, Port.self, Available.self, Installed.self, Install.self, Remove.self,
            Trust.self, Cert.self, Hosts.self, Uninstall.self,
            SiteCommand.self, WorkspaceCommand.self, OpenSite.self, EditSite.self, New.self, Import.self, Park.self, Unpark.self, Ext.self, Ini.self, Module.self, Lan.self, TLD.self,
            Database.self, PHP.self, Composer.self, Node.self, NPM.self, WP.self, MailCommand.self, Sendmail.self,
        ]
    )
}

// nexus php, composer, node, npm and wp (D38). NexusCLI.main runs them before the parser. These
// commands put them in nexus --help.
struct PHP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "php",
        abstract: "Runs the PHP of the site in the current folder, for example: nexus php -v",
        discussion: "Outside a site, nexus php uses the PHP version of a new site. A folder in a git worktree of a site uses the versions of that site. A script in a site uses the PHP of that site, also from another folder, for example: php ~/Sites/shop/artisan. The same applies to the folder of composer --working-dir, npm --prefix and wp --path."
    )

    @Argument(parsing: .captureForPassthrough, help: "The arguments for PHP.") var arguments: [String] = []

    func run() async throws {
        try await runTool(.php, arguments)
    }
}

struct Composer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Runs Composer with the PHP of the site in the current folder, for example: nexus composer install")

    @Argument(parsing: .captureForPassthrough, help: "The arguments for Composer.") var arguments: [String] = []

    func run() async throws {
        try await runTool(.composer, arguments)
    }
}

struct Node: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Runs the Node of the site in the current folder, for example: nexus node -v",
        discussion: "The Node version comes from .nvmrc, .node-version, .tool-versions or \"engines\" in package.json. Without these files, Nexus uses the newest LTS version. Choose a version for a site with: nexus site edit shop.test --node 24"
    )

    @Argument(parsing: .captureForPassthrough, help: "The arguments for Node.") var arguments: [String] = []

    func run() async throws {
        try await runTool(.node, arguments)
    }
}

struct NPM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "npm", abstract: "Runs npm with the Node of the site in the current folder, for example: nexus npm ci")

    @Argument(parsing: .captureForPassthrough, help: "The arguments for npm.") var arguments: [String] = []

    func run() async throws {
        try await runTool(.npm, arguments)
    }
}

struct WP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wp",
        abstract: "Runs WP-CLI with the PHP of the site in the current folder, for example: nexus wp option get siteurl",
        discussion: "WP-CLI looks for WordPress from the current folder up. When the site holds WordPress in a subfolder, Nexus gives WP-CLI that folder with --path. Nexus gives no --path with an alias such as @prod, with --path, --ssh or --http of your own, and for wp core download."
    )

    @Argument(parsing: .captureForPassthrough, help: "The arguments for WP-CLI.") var arguments: [String] = []

    func run() async throws {
        try await runTool(.wp, arguments)
    }
}

// nexusd says what to run. The nexus command then becomes that program. So the program gets the
// terminal, the signals and the exit code. The current folder is the real path, as getcwd gives
// it. When nexusd does not answer, a link in bin/ runs the next program with its name on the
// PATH. A terminal with the PATH setting then keeps a working php. A link also runs the next
// program when nexusd says that Nexus has no package of the tool. So wp runs the WP-CLI of the
// user until Nexus has WP-CLI too. An older nexusd that cannot read the request gives the next
// program too. nexusd answers first, because it refuses php, Composer and wp in a workspace that
// it cannot isolate. The search on the PATH runs only for the next program.
private func runTool(_ tool: ProjectTool, _ arguments: [String], throughLink: Bool = false) async throws {
    let response: NexusResponse
    let environment = ProcessInfo.processInfo.environment
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let nexus = Bundle.main.executableURL.map(RealPath.of)

    func nextProgram() -> (file: String, nexus: String)? {
        guard throughLink, let nexus, let file = NexusCLI.nextProgram(named: tool.rawValue, path: path, nexus: nexus) else {
            return nil
        }

        return (file, nexus)
    }

    func run(_ other: (file: String, nexus: String)) throws -> Never {
        var otherEnvironment = environment
        otherEnvironment["PATH"] = NexusCLI.path(path, without: other.nexus)
        try execute(other.file, [other.file] + arguments, environment: otherEnvironment)
    }

    func fail(_ message: String) throws -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    }

    do {
        let folder = FileManager.default.currentDirectoryPath
        let argumentFolder = ToolArguments.folder(of: tool, in: arguments, currentFolder: folder)
        response = try await NexusClient().send(.tool(tool, folder: folder, argumentFolder: argumentFolder))
    } catch let error as NexusClientError {
        guard let other = nextProgram() else {
            try fail("\(ErrorText.plain(error))")
        }

        FileHandle.standardError.write(Data("nexusd does not answer. This \(tool.rawValue) is \(other.file), the next one on the PATH. Open the Nexus app to use the versions of the site.\n".utf8))
        try run(other)
    } catch {
        try fail("\(ErrorText.plain(error))")
    }

    switch response {
    case .toolNotInstalled(let message):
        guard let other = nextProgram() else {
            try fail(message)
        }

        try run(other)
    case NexusResponse.unreadableRequest:
        if let other = nextProgram() {
            try run(other)
        }
    default:
        break
    }

    guard case .tool(let command) = response else {
        try finish(response)
        throw ExitCode.failure
    }

    var toolEnvironment = environment.merging(command.environment) { _, new in new }
    toolEnvironment["PATH"] = (command.path + [path]).joined(separator: ":")
    let toolArguments = WordPressCore.arguments(arguments, core: command.wordPressCore, environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
    try execute(command.executable, [command.executable] + command.arguments + toolArguments, environment: toolEnvironment)
}

// The nexus command becomes the program. This throws when the program cannot start.
private func execute(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> Never {
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(executable, argv, envp)

    FileHandle.standardError.write(Data("Nexus cannot start \(executable): \(String(cString: strerror(errno)))\n".utf8))
    throw ExitCode.failure
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists the services and their state.")

    func run() async throws {
        let response = try await send(.status)

        guard case .services(let services) = response else {
            try finish(response)
            return
        }

        for service in services {
            let ports = service.ports.isEmpty ? "-" : "port \(service.ports.map(String.init).joined(separator: ", "))"
            print([service.id.padding(to: 14), state(service.state).padding(to: 26), ports.padding(to: 16), service.displayName].joined(separator: " "))

            if case .failed(let reason) = service.state {
                print("    \(withLogHint(reason))")
            }
        }

        if services.allSatisfy({ $0.id == NexusServiceID.dns }) {
            print("No package is installed. Install one with: nexus install redis 8.2")
        }
    }

    private func state(_ state: ServiceState) -> String {
        switch state {
        case .stopped: "stopped"
        case .running(let pid, _): "running (process \(pid))"
        case .restarting(let attempt): "restarting (\(attempt))"
        case .failed: "failed"
        }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Starts a service, for example redis-8.2.")

    @Argument(help: "The service, as nexus status shows it.") var service: String?
    @Flag(help: "Start the services that nexus stop --all stopped.") var stopped = false

    func validate() throws {
        if (service == nil) == !stopped {
            throw ValidationError("Give a service or --stopped.")
        }
    }

    func run() async throws {
        if let service {
            try finish(try await send(.start(service: service)))
            return
        }

        try finish(try await send(.startStopped))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stops a service.")

    @Argument(help: "The service, as nexus status shows it.") var service: String?
    @Flag(help: "Stop every service. nexus start --stopped starts them again.") var all = false

    func validate() throws {
        if (service == nil) == !all {
            throw ValidationError("Give a service or --all.")
        }
    }

    func run() async throws {
        if let service {
            try finish(try await send(.stop(service: service)))
            return
        }

        try finish(try await send(.stopAll))
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stops a service and starts it again.")

    @Argument(help: "The service, as nexus status shows it.") var service: String

    func run() async throws {
        try finish(try await send(.restart(service: service)))
    }
}

struct Port: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Gives a service another port.")

    @Argument(help: "The service, as nexus status shows it.") var service: String
    @Argument(help: "The new port.") var port: Int

    func run() async throws {
        try finish(try await send(.setPort(service: service, port: port)))
    }
}

struct Available: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists the packages that Nexus can install.")

    func run() async throws {
        let response = try await send(.available)

        guard case .available(let packages) = response else {
            try finish(response)
            return
        }

        for package in packages {
            print([package.name.padding(to: 12), package.line.padding(to: 8), package.version].joined(separator: " "))
        }
    }
}

struct Installed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists the installed packages.", aliases: ["runtimes"])

    func run() async throws {
        let response = try await send(.installed)

        guard case .installed(let runtimes) = response else {
            try finish(response)
            return
        }

        for runtime in runtimes {
            print([runtime.name.padding(to: 12), runtime.line.padding(to: 8), runtime.version].joined(separator: " "))
        }
    }
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Installs a package, for example: nexus install redis 8.2")

    @Argument(help: "The package, for example php, redis or mysql.") var name: String
    @Argument(help: "The version line, for example 8.5.") var line: String

    func run() async throws {
        try finish(try await send(.install(name: name, line: line)))
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Removes an installed package.")

    @Argument(help: "The package, for example php, redis or mysql.") var name: String
    @Argument(help: "The version line, for example 8.5.") var line: String

    func run() async throws {
        try finish(try await send(.remove(name: name, line: line)))
    }
}

struct Trust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Trusts the Nexus root CA, so browsers accept the certificates of Nexus. macOS asks for your password.")

    func run() async throws {
        try finish(try await send(.trust))
    }
}

struct Cert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Makes a certificate for one or more hosts, for example: nexus cert shop.test www.shop.test")

    @Argument(help: "The hosts. The first host names the files.") var hosts: [String]

    func run() async throws {
        try finish(try await send(.certificate(hosts: hosts)))
    }
}

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists the hosts outside the dev TLD that Nexus adds to /etc/hosts.",
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the hosts.")

        func run() async throws {
            let response = try await send(.hosts)

            guard case .hosts(let hosts) = response else {
                try finish(response)
                return
            }

            if hosts.isEmpty {
                print("Nexus adds no lines to /etc/hosts. Names in the dev TLD need none.")
                return
            }

            hosts.forEach { print($0) }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sends a host to 127.0.0.1 and ::1 through /etc/hosts, for example: nexus hosts add shop.local")

        @Argument(help: "The host.") var host: String

        func run() async throws {
            try finish(try await send(.addHost(host)))
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Removes the /etc/hosts line of a host.")

        @Argument(help: "The host.") var host: String

        func run() async throws {
            try finish(try await send(.removeHost(host)))
        }
    }
}

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Removes the changes that Nexus made to macOS: the resolver file, the /etc/hosts lines, the root CA and the background services.")

    @Flag(help: "Do not ask before the removal.") var yes = false

    func run() async throws {
        if !yes {
            print("Nexus stops every service and removes its resolver file, its /etc/hosts lines, its root CA and its background services. macOS asks for your password to remove the trust setting.")
            print("Type yes to continue: ", terminator: "")

            guard readLine()?.lowercased() == "yes" else {
                print("Nothing changed.")
                return
            }
        }

        try finish(try await send(.uninstall))
        UserDefaults.standard.removePersistentDomain(forName: NexusIdentifiers.app)
        print("Quit Nexus and move it to the Trash.")
    }
}

struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Makes, shows and removes the workspaces of the sites.",
        subcommands: [List.self, Create.self, Wait.self, Info.self, Remove.self, Env.self, Retry.self],
        defaultSubcommand: List.self
    )

    private static var currentFolder: String {
        RealPath.of(URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    }

    private static func sites() async throws -> [SiteInfo] {
        let response = try await send(.sites)

        guard case .sites(let sites) = response else {
            try finish(response)
            throw ExitCode.failure
        }

        return sites
    }

    private static func target(name: String?, site: String?) async throws -> WorkspaceTarget {
        try WorkspaceTarget.find(name: name, site: site, folder: currentFolder, in: try await sites())
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Makes a workspace for the current worktree. With a branch, it makes the git worktree first, for example: nexus workspace create fix-login",
            discussion: "With a branch, Nexus runs git worktree add in the place of Settings > Workspaces. The default place is .claude/worktrees/<branch> in the project, where Claude Code makes its worktrees too. A new branch starts from the current branch of the main checkout. This also works when the switch of the site is off."
        )

        @Argument(help: "A branch for a new worktree. The default is the worktree of the current folder.") var branch: String?
        @Option(help: "copy, empty or dump. dump loads the dump file of the site. The default is the choice of the site. A workspace that exists keeps its databases.") var databases: WorkspaceDatabaseKind?

        func run() async throws {
            guard let branch else {
                try finish(try await send(.createWorkspace(folder: WorkspaceCommand.currentFolder, databases: databases)))
                return
            }

            print("Nexus makes the worktree for \(branch). A large project can take some seconds.")
            try finish(try await send(.createWorktree(folder: WorkspaceCommand.currentFolder, branch: branch, databases: databases)))
        }
    }

    struct Wait: AsyncParsableCommand {
        // nexusd sees a new worktree after a moment. So a script can run this directly after git worktree add.
        private static let secondsForANewWorktree = 10

        static let configuration = CommandConfiguration(abstract: "Waits until the workspace is ready and prints its URL. It ends with an error when the workspace is not isolated.")

        @Argument(help: "The name of the workspace. The default is the workspace of the current folder.") var name: String?
        @Option(help: "The host of the site, when more sites have this name.") var site: String?
        @Option(help: "The number of seconds to wait.") var timeout = 3600

        func run() async throws {
            let start = ContinuousClock.now

            while true {
                let waited = (ContinuousClock.now - start).components.seconds

                do {
                    let workspace = try await WorkspaceCommand.target(name: name, site: site).workspace

                    if workspace.state == .ready {
                        guard let url = workspace.url else {
                            FileHandle.standardError.write(Data("\(withLogHint(workspace.problem ?? "The workspace \(workspace.name) has no URL."))\n".utf8))
                            throw ExitCode.failure
                        }

                        print(url)
                        return
                    }

                    if let message = workspace.isolationMessage {
                        FileHandle.standardError.write(Data("\(withLogHint(message))\n".utf8))
                        throw ExitCode.failure
                    }
                } catch let error as WorkspaceTargetError where error.canAppearLater && waited < Self.secondsForANewWorktree {
                }

                guard waited < timeout else {
                    FileHandle.standardError.write(Data("The workspace was not ready after \(timeout) seconds.\n".utf8))
                    throw ExitCode.failure
                }

                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Gives the URL, the databases and the ports of a workspace.")

        @Argument(help: "The name of the workspace. The default is the workspace of the current folder.") var name: String?
        @Option(help: "The host of the site, when more sites have this name.") var site: String?
        @Flag(help: "Prints JSON for a script.") var json = false

        func run() async throws {
            let details = WorkspaceDetails(try await WorkspaceCommand.target(name: name, site: site))

            if json {
                print(try details.json)
                return
            }

            print("Workspace  \(details.name) of \(details.site)")
            print("State      \(details.state)")
            print("URL        \(details.url ?? "none")")
            print("Worktree   \(details.worktree)")

            details.problem.map { print("Problem    \(withLogHint($0))") }
            details.databases.forEach { print("Database   \($0.name) on \($0.instance), port \($0.port.map(String.init) ?? "unknown")") }
            details.redisIndexes.sorted { $0.key < $1.key }.forEach { print("Redis      \($0.key)=\($0.value)") }
            details.ports.sorted { $0.key < $1.key }.forEach { print("Port       \($0.key)=\($0.value)") }
            details.warnings.forEach { print("Warning    \($0)") }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Removes the workspace and keeps a dump.",
            discussion: "Nexus first runs the commands of nexus site edit --removal-command in the workspace. Then it runs git worktree remove. git refuses a worktree with changes that are not committed. --force removes these changes too. Nexus then writes a dump of each database to the trash and removes the database server of the workspace."
        )

        @Argument(help: "The name of the workspace. The default is the workspace of the current folder.") var name: String?
        @Option(help: "The host of the site, when more sites have this name.") var site: String?
        @Flag(help: "Also remove a worktree with changes that are not committed. A locked worktree stays.") var force = false

        func run() async throws {
            let target = try await WorkspaceCommand.target(name: name, site: site)
            let host = target.site.hosts.first ?? ""

            print("Nexus removes the workspace \(target.workspace.name). A dump of a large database can take some minutes.")
            try finish(try await send(.removeWorkspace(host: host, name: target.workspace.name, force: force)))
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sets up a workspace again, for example after you fix the reason why it is not isolated.")

        @Argument(help: "The host of the site.") var host: String
        @Argument(help: "The name of the workspace.") var name: String

        func run() async throws {
            try finish(try await send(.retryWorkspace(host: host, name: name)))
        }
    }

    struct Env: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows which keys Nexus changes in the .env of each workspace of a site.")

        @Argument(help: "The host of the site.") var host: String

        func run() async throws {
            let response = try await send(.workspaceEnv(host: host))

            guard case .workspaceEnv(let keys) = response else {
                try finish(response)
                return
            }

            let width = keys.map(\.key.count).max() ?? 0
            keys.forEach { print("\($0.key.padding(to: width))  \($0.value)") }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the workspaces of the current site. Outside a site, it lists each workspace.")

        @Flag(help: "Lists the workspaces of each site.") var all = false

        func run() async throws {
            let sites = try await WorkspaceCommand.sites()
            let current = all ? nil : WorkspaceTarget.currentSite(folder: WorkspaceCommand.currentFolder, in: sites)
            let rows = (current.map { [$0] } ?? sites).flatMap { site in
                (site.workspaces ?? []).map { (site: site.hosts.first ?? "", workspace: $0) }
            }

            if rows.isEmpty {
                print(current.map { "\($0.hosts.first ?? "This site") has no workspaces. See: nexus workspace list --all" } ?? "Nexus has no workspaces. A new git worktree of a site gets one.")
                return
            }

            for row in rows {
                print([row.site.padding(to: 28), row.workspace.name.padding(to: 28), (row.workspace.url ?? "").padding(to: 44), row.workspace.folder].joined(separator: " "))

                if let problem = row.workspace.problem {
                    print("    does not run: \(withLogHint(problem))")
                }

                if let message = row.workspace.isolationMessage {
                    print("    \(withLogHint(message))")
                }

                for warning in row.workspace.warnings ?? [] {
                    print("    warning: \(warning)")
                }
            }
        }
    }
}

extension WebServer: ExpressibleByArgument {}

extension SiteKind: ExpressibleByArgument {}

extension WorkspaceDatabaseKind: ExpressibleByArgument {}

extension WorkspaceDatabaseChoice: ExpressibleByArgument {}

extension WorkspaceEnvKey: ExpressibleByArgument {
    public init?(argument: String) {
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
            return nil
        }

        self.init(key: String(argument[..<equals]), value: String(argument[argument.index(after: equals)...]))
    }
}

struct SiteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "site",
        abstract: "Adds, lists, changes and removes sites.",
        subcommands: [List.self, Add.self, Edit.self, Remove.self, Defaults.self, Probe.self, Mail.self, WordPress.self],
        defaultSubcommand: List.self
    )

    // The configuration and the database of a WordPress site (Phase 4, 3b).
    struct WordPress: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "wordpress", abstract: "Shows the WordPress version, the database and the site URL of a WordPress site, for example: nexus site wordpress blog.test")

        @Argument(help: "The host of the site, for example blog.test.") var host: String
        @Flag(help: "Without a wp-config.php: makes a database on MySQL 8.4 and writes wp-config.php.") var setUp = false
        @Flag(help: "Makes the database that wp-config.php names, empty, when it does not exist.") var createDatabase = false
        @Flag(name: .customLong("set-db-host"), help: "Sets DB_HOST to the port of the Nexus instance. The old line stays as a comment line.") var setDBHost = false
        @Flag(name: .customLong("copy-database"), help: "Copies the database from the server that DB_HOST names to a Nexus instance. Nexus only reads the other server.") var copyDatabase = false
        @Flag(name: .customLong("change-urls"), help: "Changes the URLs in the database and WP_HOME to the URL of Nexus. A dump of the database goes to the trash first.") var changeURLs = false
        @Flag(name: .customLong("undo-url-change"), help: "Puts back the database from the dump of the last URL change, and the old WP_HOME.") var undoURLChange = false
        @Flag(name: .customLong("add-workspace-lines"), help: "Adds the lines that load wp-config-nexus.php to a wp-config.php that git tracks, and that name to .gitignore. Commit the change. Each workspace then gets its own database.") var addWorkspaceLines = false

        func validate() throws {
            if [setUp, createDatabase, setDBHost, copyDatabase, changeURLs, undoURLChange, addWorkspaceLines].filter({ $0 }).count > 1 {
                throw ValidationError("Use one of --set-up, --create-database, --set-db-host, --copy-database, --change-urls, --undo-url-change and --add-workspace-lines.")
            }
        }

        func run() async throws {
            if createDatabase {
                try finish(try await send(.createWordPressDatabase(host: host)))
                return
            }

            let response = try await send(.wordPressSite(host: host))

            guard case .wordPressSite(let info) = response else {
                try finish(response)
                return
            }

            if setUp {
                guard let database = info.setUpDatabase, let instance = info.setUpInstance else {
                    FileHandle.standardError.write(Data("\(withLogHint(info.problem ?? "Nexus cannot set up \(host). It needs a classic WordPress site without wp-config.php and a running MySQL or MariaDB."))\n".utf8))
                    throw ExitCode.failure
                }

                try finish(try await send(.setUpWordPress(host: host, database: database, instance: instance)))
                return
            }

            if setDBHost {
                guard let value = info.suggestedDBHost else {
                    print("DB_HOST of \(host) needs no change. Nexus changes nothing.")
                    return
                }

                try finish(try await send(.setWordPressDBHost(host: host, value: value, user: info.suggestedUser)))
                return
            }

            if copyDatabase {
                let response = try await send(.wordPressCopySource(host: host))

                guard case .wordPressCopySource(let source) = response else {
                    try finish(response)
                    return
                }

                try finish(try await send(.copyDatabase(DatabaseCopy(source: source.server, database: source.database, instance: source.instance, name: source.database))))
                return
            }

            if changeURLs {
                guard let plan = info.urlPlan else {
                    print("The URLs of \(host) need no change. Nexus changes nothing.")
                    return
                }

                try finish(try await send(.changeWordPressURLs(host: host, plan: plan)))
                return
            }

            if undoURLChange {
                guard let change = info.urlChange else {
                    FileHandle.standardError.write(Data("Nexus has no change of the URLs of \(host) that it can undo.\n".utf8))
                    throw ExitCode.failure
                }

                try finish(try await send(.undoWordPressURLChange(host: host, plan: change.plan)))
                return
            }

            if addWorkspaceLines {
                guard let lines = info.workspaceLines, lines.state == .missing else {
                    print(info.workspaceLines == nil ? "wp-config.php of \(host) needs no lines for workspaces. Nexus changes nothing." : "wp-config.php of \(host) has the lines for workspaces. Commit the change.")
                    return
                }

                try finish(try await send(.addWordPressWorkspaceLines(host: host, lines: lines)))
                return
            }

            let database = info.database.map { name in
                let place = info.instance.map { " on \($0)" } ?? ""
                let state = info.databaseExists.map { $0 ? "" : " (it does not exist)" } ?? ""
                return "\(name)\(place)\(state)"
            }
            let rows = [
                ("Type", info.type.displayName),
                ("Version", info.version ?? "not found"),
                ("Configuration", info.configFile ?? (info.type == .bedrock ? "no .env" : "no wp-config.php")),
                ("Database", database ?? "not found"),
                ("DB_HOST", info.dbHost ?? "not found"),
                ("Home", info.home ?? "-"),
                ("Site URL", info.siteURL ?? "-"),
            ] + (info.configHome.map { [("WP_HOME", $0)] } ?? []) + (info.network.map { [("Network", $0.summary)] } ?? []) + [
                ("Nexus URL", info.url ?? "-"),
            ]

            for (label, value) in rows {
                print("\(label.padding(to: 14)) \(value)")
            }

            if let problem = info.problem {
                print(withLogHint(problem))
            }

            if let database = info.setUpDatabase, let instance = info.setUpInstance {
                print("nexus site wordpress \(host) --set-up makes the database \(database) on \(instance) and writes wp-config.php.")
            }

            if info.suggestedDBHost != nil {
                let account = info.suggestedUser == nil ? "" : info.suggestedDBHost == info.dbHost ? " DB_USER and DB_PASSWORD to the account of the instance" : " DB_HOST, DB_USER and DB_PASSWORD"
                print(account.isEmpty ? "nexus site wordpress \(host) --set-db-host changes DB_HOST." : "nexus site wordpress \(host) --set-db-host changes\(account).")
            }

            if info.databaseExists == false, info.suggestedDBHost == nil {
                print("nexus site wordpress \(host) --create-database makes the database.")
            }

            if info.copyInstance != nil {
                print("nexus site wordpress \(host) --copy-database copies the database to \(info.copyInstance ?? "").")
            }

            if let plan = info.urlPlan {
                print("nexus site wordpress \(host) --change-urls changes the URLs to \(plan.to).")
            } else if let change = info.urlChange {
                print("nexus site wordpress \(host) --undo-url-change puts back the URLs of before \(change.date.formatted(date: .abbreviated, time: .shortened)).")
            }

            if let text = info.network?.problem ?? info.network?.servedText {
                print(text)
            }

            switch info.workspaceLines?.state {
            case .missing where info.workspaceLines?.changes.isEmpty == true:
                print("git does not ignore wp-config-nexus.php. nexus site wordpress \(host) --add-workspace-lines adds it to .gitignore.")
            case .missing:
                print("git tracks \(info.workspaceLines?.configFile ?? "wp-config.php"), and it has no lines for workspaces. nexus site wordpress \(host) --add-workspace-lines adds them.")
            case .uncommitted:
                print("The lines for workspaces in \(info.workspaceLines?.configFile ?? "wp-config.php") are not committed yet.")
            case nil:
                break
            }
        }
    }

    // Where the main checkout sends its mail (Phase 3, 3c). Nexus changes its .env only with
    // --send-to-nexus or --restore (D44).
    struct Mail: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows where a site sends its mail. --send-to-nexus sends the mail of a Laravel site to the mail service of Nexus. --restore puts the old mail settings back. --turn-off-plugins turns off the mail plugins of a WordPress site.")

        @Argument(help: "The host of the site, for example shop.test.") var host: String
        @Flag(help: "Changes the mail keys in the .env of the main checkout. The old values stay there as comment lines.") var sendToNexus = false
        @Flag(help: "Puts back the old mail settings from the comment lines of Nexus in the .env.") var restore = false
        @Flag(help: "Turns off the plugins of a WordPress site that send the mail themselves. The live site does not change.") var turnOffPlugins = false

        func validate() throws {
            if [sendToNexus, restore, turnOffPlugins].filter({ $0 }).count > 1 {
                throw ValidationError("Use one of --send-to-nexus, --restore and --turn-off-plugins.")
            }
        }

        func run() async throws {
            if sendToNexus {
                try finish(try await send(.sendMailToNexus(host: host)))
                return
            }

            if restore {
                try finish(try await send(.restoreMailSettings(host: host)))
                return
            }

            let response = try await send(.siteMail(host: host))

            guard case .siteMail(let mail) = response else {
                try finish(response)
                return
            }

            if turnOffPlugins {
                let folders = mail.mailPlugins.filter(\.canTurnOff).map(\.folder)

                guard !folders.isEmpty else {
                    print("\(host) has no plugin that Nexus can turn off for its mail.")
                    return
                }

                try finish(try await send(.turnOffMailPlugins(host: host, folders: folders)))
                return
            }

            if let problem = mail.problem {
                FileHandle.standardError.write(Data("\(withLogHint("Nexus cannot read the mail settings of \(host). \(problem)"))\n".utf8))
                throw ExitCode.failure
            }

            print(mail.sendsToNexus ? "\(host) sends its mail to the mail service of Nexus." : mail.warning ?? "\(host) does not send its mail to the mail service of Nexus.")

            if mail.canSendToNexus {
                print("Send it to Nexus with: nexus site mail \(host) --send-to-nexus")
                print("This changes these keys in the .env. The old values stay there as comment lines.")

                for change in mail.changes {
                    print("    \(change.key)=\(change.value)\(change.isNew ? "    (a new line)" : "")")
                }
            }

            if mail.canRestore {
                print("Put the old mail settings back with: nexus site mail \(host) --restore")
            }

            if mail.mailPlugins.contains(where: \.canTurnOff) {
                print("Turn off these plugins in this copy with: nexus site mail \(host) --turn-off-plugins")
            }
        }
    }

    struct Probe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows which env key feeds each database, Redis, session, cache, queue and broadcast setting of a Laravel application. The probe only reads.")

        @Argument(help: "A folder in the application.") var folder: String = "."
        @Option(help: "The PHP version line, for example 8.4. The default is the PHP of the site.") var php: String?
        @Flag(help: "Print the full result as JSON.") var json = false

        func run() async throws {
            let response = try await send(.probe(folder: absolutePath(folder), php: php))

            guard case .configuration(let configuration) = response else {
                try finish(response)
                return
            }

            guard json else {
                ProbeSummary.lines(configuration).forEach { print($0) }
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(configuration), as: UTF8.self))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the sites.")

        func run() async throws {
            let response = try await send(.sites)

            guard case .sites(let sites) = response else {
                try finish(response)
                return
            }

            if sites.isEmpty {
                print("Nexus has no sites. Add one with: nexus site add <folder>, or park a folder with: nexus park <folder>")
                return
            }

            for site in sites {
                let origin = site.parked ? "parked" : "added"
                let backend = switch site.kind {
                case .php: ["PHP \(site.php)".padding(to: 9), site.server.rawValue.padding(to: 7)]
                case .node: ["Node.js".padding(to: 17)]
                case .proxy: ["proxy".padding(to: 17)]
                }

                print(([site.url.padding(to: 36)] + backend + [origin.padding(to: 7), site.kind == .php ? site.documentRoot : site.folder]).joined(separator: " "))

                if site.kind == .node {
                    print("    command: \(site.command ?? site.projectCommand ?? "none, because package.json has no dev or start script")")
                }

                if let framework = site.framework {
                    print("    framework: \(framework.displayName)")
                }

                if let app = site.app {
                    print("    app: \(app.summary). Log: \(app.log)")
                }

                if site.kind == .proxy, let address = site.address {
                    print("    address: \(address)")
                }

                if site.hosts.count > 1 {
                    print("    aliases: \(site.hosts.dropFirst().joined(separator: ", "))")
                }

                if let group = site.group {
                    print("    group: \(group)")
                }

                if let problem = site.problem {
                    print("    does not run: \(withLogHint(problem))")
                }
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Adds a folder as a site, for example: nexus site add . --php 8.4 --server apache")

        @Argument(help: "The folder of the site.") var folder: String = "."
        @Option(help: "The host. The default is the folder name with the dev TLD, for example shop.test.") var host: String?
        @Option(name: .customLong("alias"), help: "Another host for the same site. Repeat it for more hosts.") var aliases: [String] = []
        @Option(help: "The PHP version line, for example 8.5. The default comes from nexus site defaults.") var php: String?
        @Option(help: "nginx or apache. The default comes from nexus site defaults.") var server: WebServer?
        @Option(help: "The group of the site in the sidebar of the app.") var group: String?
        @Option(help: "php, node or proxy. A Node.js app runs its command. A proxy site sends its requests to a server that you start.") var runsAs: SiteKind?
        @Option(help: "The command of a Node.js app, for example \"npm run dev\". The default is the dev or start script of package.json.") var command: String?
        @Option(help: "The server of a proxy site: a port, for example 3000, or an address, for example http://127.0.0.1:3000.") var address: String?

        func run() async throws {
            try finish(try await send(.addSite(folder: absolutePath(folder), host: host, aliases: aliases, php: php, server: server, group: group, runsAs: runsAs, command: command, address: address)))
        }
    }

    struct Defaults: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows or changes the webserver, the PHP version and the Node version of a new site, for example: nexus site defaults --php 8.4 --wordpress-server apache")

        @Option(help: "The PHP version line of a new site, or newest for the newest installed one.") var php: String?
        @Option(help: "nginx or apache.") var server: WebServer?
        @Option(help: "The Node version line of a new site, or project for the version that the files of the project name.") var node: String?
        @Option(name: .customLong("wordpress-php"), help: "The PHP version line of a new WordPress site, or newest for the newest installed one.") var wordPressPHP: String?
        @Option(name: .customLong("wordpress-server"), help: "nginx or apache for a new WordPress site.") var wordPressServer: WebServer?

        func run() async throws {
            let response = try await send(.siteDefaults)

            guard case .siteDefaults(var defaults) = response else {
                try finish(response)
                return
            }

            guard php != nil || server != nil || node != nil || wordPressPHP != nil || wordPressServer != nil else {
                print(defaults.summary)
                return
            }

            var wordPress = defaults.forWordPress

            if let wordPressPHP {
                wordPress.php = wordPressPHP == "newest" ? nil : wordPressPHP
            }

            if let wordPressServer {
                wordPress.server = wordPressServer
            }

            defaults.wordPress = wordPress

            if let php {
                defaults.php = php == "newest" ? nil : php
            }

            if let server {
                defaults.server = server
            }

            if let node {
                defaults.node = node == NodeLines.fromProject ? nil : node
            }

            try finish(try await send(.setSiteDefaults(defaults)))
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Changes the kind, the PHP version, the Node version, the web server, the document root or the aliases of a site.")

        @Argument(help: "The host of the site.") var host: String
        @Option(help: "php, node or proxy.") var runsAs: SiteKind?
        @Option(help: "The command of a Node.js app, for example \"npm run dev\", or project for the dev or start script of package.json.") var command: String?
        @Option(help: "The server of a proxy site: a port, for example 3000, or an address, for example http://127.0.0.1:3000.") var address: String?
        @Option(help: "The PHP version line, for example 8.4.") var php: String?
        @Option(help: "The Node version line, for example 24, or project for the version that the files of the project name.") var node: String?
        @Option(help: "nginx or apache.") var server: WebServer?
        @Option(name: .customLong("alias"), help: "The aliases. They replace the current aliases.") var aliases: [String] = []
        @Flag(help: "Remove every alias.") var noAliases = false
        @Option(help: "on or off. With on, a new git worktree gets a workspace.") var workspaces: OnOff?
        @Option(name: .customLong("workspace-key"), help: "A key for the .env of each workspace, for example SCOUT_PORT={port:scout}. Repeat it for more keys. These replace the current keys.") var workspaceKeys: [WorkspaceEnvKey] = []
        @Flag(help: "Remove every key of the workspaces.") var noWorkspaceKeys = false
        @Option(name: .customLong("workspace-command"), help: "A command for a new workspace, after the database clone. It can use {workspace}, {host}, {database} and {port:<name>}. {port:database} is the port of the database server of the workspace. Repeat it for more commands. These replace the current commands.") var workspaceCommands: [String] = []
        @Flag(help: "Remove every command of new workspaces.") var noWorkspaceCommands = false
        @Option(name: .customLong("removal-command"), help: "A command that runs in a workspace before Nexus removes it, for example \"php artisan queue:clear\". It can use the same values as --workspace-command. Repeat it for more commands. These replace the current commands.") var removalCommands: [String] = []
        @Flag(help: "Remove every command before the removal of a workspace.") var noRemovalCommands = false
        @Option(name: .customLong("workspace-file"), help: "A path in the project folder that git ignores, for example .env.testing or auth.json. Each workspace gets a clone. A .env file gets the database, Redis and URL keys of the workspace. Repeat it for more paths. These replace the current paths.") var workspaceFiles: [String] = []
        @Flag(help: "Remove every extra file of the workspaces.") var noWorkspaceFiles = false
        @Option(name: .customLong("background-command"), help: "A background process of each workspace. It can use {workspace}, {host}, {database} and {port:<name>}. {port:database} is the port of the database server of the workspace. Repeat it for more processes. These replace the current processes.") var backgroundCommands: [String] = []
        @Flag(help: "Remove every background process.") var noBackgroundCommands = false
        @Option(name: .customLong("workspace-processes"), help: "on or off. With on, each workspace runs the background processes.") var workspaceProcesses: OnOff?
        @Option(name: .customLong("main-processes"), help: "on or off. With on, the main checkout runs the background processes.") var mainProcesses: OnOff?
        @Option(name: .customLong("workspace-databases"), help: "default, copy, empty or dump. What a new workspace gets: a copy of the main database, an empty database, or an empty database with the dump file of --workspace-dump. default follows Settings > Workspaces. A WordPress site gets a copy or the dump file.") var workspaceDatabases: WorkspaceDatabaseChoice?
        @Option(name: .customLong("workspace-dump"), help: "The dump file that each new workspace gets in its main database with --workspace-databases dump. The links of a WordPress dump to its live URL go to the workspace.") var workspaceDump: String?
        @Option(name: .customLong("live-url"), help: "WordPress: another URL of the live site in the dump, for example https://staging.shop.com. Its links go to the workspace too. Repeat it for more URLs. These replace the current URLs.") var liveURLs: [String] = []
        @Flag(help: "WordPress: remove each added live URL.") var noLiveURLs = false
        @Option(name: .customLong("workspace-seeders"), help: "on or off. With on, a Laravel site with an empty database runs php artisan db:seed in a new workspace.") var workspaceSeeders: OnOff?
        @Option(name: .customLong("document-root"), help: "The folder in the site folder that the web server serves, for example htdocs. Each workspace serves the same folder.") var documentRoot: String?
        @Flag(help: "Use the automatic document root again: public/ when the site folder has one.") var noDocumentRoot = false

        func validate() throws {
            if documentRoot != nil, noDocumentRoot {
                throw ValidationError("Give --document-root or --no-document-root, not both.")
            }

            if !liveURLs.isEmpty, noLiveURLs {
                throw ValidationError("Give --live-url or --no-live-urls, not both.")
            }
        }

        private var commandChange: [String]? {
            noWorkspaceCommands ? [] : (workspaceCommands.isEmpty ? nil : workspaceCommands)
        }

        private var filesChange: [String]? {
            noWorkspaceFiles ? [] : (workspaceFiles.isEmpty ? nil : workspaceFiles)
        }

        private var removalChange: [String]? {
            noRemovalCommands ? [] : (removalCommands.isEmpty ? nil : removalCommands)
        }

        private var backgroundChange: [String]? {
            noBackgroundCommands ? [] : (backgroundCommands.isEmpty ? nil : backgroundCommands)
        }

        private var keyChange: [WorkspaceEnvKey]? {
            noWorkspaceKeys ? [] : (workspaceKeys.isEmpty ? nil : workspaceKeys)
        }

        func run() async throws {
            let aliasChange: [String]? = noAliases ? [] : (aliases.isEmpty ? nil : aliases)
            let change = SiteChange(
                php: php,
                server: server,
                aliases: aliasChange,
                node: node,
                automaticWorkspaces: workspaces.map { $0 == .on },
                workspaceKeys: keyChange,
                workspaceCommands: commandChange,
                backgroundCommands: backgroundChange,
                workspaceProcesses: workspaceProcesses.map { $0 == .on },
                mainProcesses: mainProcesses.map { $0 == .on },
                runsAs: runsAs,
                command: command,
                address: address,
                workspaceDatabases: workspaceDatabases,
                workspaceSeeders: workspaceSeeders.map { $0 == .on },
                documentRoot: noDocumentRoot ? "" : documentRoot,
                removalCommands: removalChange,
                workspaceFiles: filesChange,
                workspaceDump: workspaceDump.map(absolutePath),
                workspaceDumpURLs: noLiveURLs ? [] : (liveURLs.isEmpty ? nil : liveURLs)
            )

            try finish(try await send(.editSite(host: host, change: change)))
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Removes an added site. The folder stays.")

        @Argument(help: "The host of the site.") var host: String

        func run() async throws {
            try finish(try await send(.removeSite(host: host)))
        }
    }
}

// A new site from a template (D38, Phase 4, 3i). The command waits until the site runs, and the
// steps show in the app at the same time.
struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Makes a new site from a template, for example: nexus new laravel shop --kit react")

    @Argument(help: "laravel, wordpress, next, nuxt, vite or astro.") var template: SiteTemplate
    @Argument(help: "The name of the site: the folder and the first part of the host, for example shop for shop.test.") var name: String
    @Option(help: "The folder that gets the new site. The default is the current folder.") var folder: String = "."
    @Flag(inversion: .prefixedNo, help: "Makes a git repository with a first commit. Workspaces need it.") var git = true
    @Option(help: "The database instance, for example mysql-8.4. A Laravel site without it uses SQLite. WordPress gets MySQL 8.4 or the newest MySQL that runs.") var database: String?
    @Option(help: "The PHP version line. The default is the newest that fits the template.") var php: String?
    @Option(help: "The Node version line. The default is the newest installed one.") var node: String?
    @Option(help: "Laravel: none, react, vue, svelte or livewire.") var kit: LaravelStarterKit = .none
    @Option(help: "Laravel with a starter kit: built_in, workos or none.") var auth: LaravelAuthentication = .builtIn
    @Flag(help: "Laravel with a starter kit: adds teams.") var teams = false
    @Option(help: "Laravel: pest or phpunit.") var tests: LaravelTests = .pest
    @Flag(inversion: .prefixedNo, help: "Laravel: installs Laravel Boost.") var boost = true
    @Option(help: "WordPress: the language, for example nl_NL.") var locale = WordPressLocale.english
    @Option(help: "WordPress: the admin user.") var adminUser = "admin"
    @Option(help: "WordPress: the email address of the admin user. The default is admin@ and the host.") var adminEmail = ""
    @Option(help: "WordPress: subfolders or subdomains for a network.") var network: WordPressNetworkKind?
    @Option(help: "Vite: react, vue or svelte.") var framework: ViteFramework = .react
    @Option(help: "Node.js: npm, pnpm or yarn.") var packageManager: PackageManager = .npm

    func run() async throws {
        let site = NewSite(
            template: template,
            name: name,
            parent: absolutePath(folder),
            git: git,
            database: database,
            php: php,
            node: node,
            starterKit: kit,
            authentication: auth,
            teams: teams,
            tests: tests,
            boost: boost,
            locale: locale,
            adminUser: adminUser,
            adminEmail: adminEmail,
            network: network,
            framework: framework,
            packageManager: packageManager
        )

        print("Nexus makes the site. This can take some minutes. The log is \(NexusPaths.standard.log("new-site-\(name)").path(percentEncoded: false))")
        let response = try await send(.createSite(site))

        switch response {
        case .siteCreated(let created):
            print(created.message)

            if let user = created.adminUser, let password = created.adminPassword {
                print("Admin user: \(user)")
                print("Password: \(password)")
                print("Nexus does not keep this password. Copy it now.")
            }
        case .siteNotCreated(let failure):
            Self.reportFailure(failure)
        default:
            try finish(response)
        }
    }

    static func reportFailure(_ failure: SiteCreationFailure) -> Never {
        var lines = [withLogHint(failure.message), ""]
        lines += failure.steps.map { "\(mark($0.state)) \($0.title)" }
        lines += ["", "The end of the log:"] + failure.log.map { "  \($0)" }
        lines += ["", "Nexus kept \(failure.site.map { "the site \($0), " } ?? "")\(failure.folder)\(failure.database.map { " and the database \($0)" } ?? ""), so you can look at them. The log is \(failure.logFile)"]
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        Foundation.exit(ExitCode.failure.rawValue)
    }

    private static func mark(_ state: TaskStepState) -> String {
        switch state {
        case .done: "done   "
        case .failed: "failed "
        case .running: "running"
        case .waiting: "-      "
        }
    }
}

// A WordPress site from a backup (Phase 4, 3f). nexusd reads the backup first and the command shows
// what it found.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Makes a WordPress site from a backup, for example: nexus import ~/Downloads/foo.wpress")

    @Argument(help: "A zip of Local, Jetpack or Studio, a .wpress file, or a folder with wp-content and a .sql or .sql.gz dump.") var backup: String
    @Option(help: "The name of the site. The default comes from the name of the backup.") var name: String?
    @Option(help: "The folder that gets the new site. The default is the current folder.") var folder: String = "."
    @Option(help: "The database instance, for example mysql-8.4. The default is MySQL 8.4 or the newest MySQL that runs.") var database: String?
    @Flag(inversion: .prefixedNo, help: "Makes a git repository with a first commit. It ignores wp-config.php and the uploads.") var git = true

    func run() async throws {
        let path = absolutePath(backup)
        let inspected = try await send(.inspectBackup(path: path))

        guard case .backup(let info) = inspected else {
            try finish(inspected)
            return
        }

        if let problem = info.problem {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
            throw ExitCode.failure
        }

        let found = [
            info.format.map { "Format: \($0.displayName)" },
            "WordPress: \(BackupText.wordPress(info))",
            info.dump.map { "Dump: \($0)" },
            "Table prefix: \(info.tablePrefix ?? "as in wp-config.php")",
            info.siteURL.map { "Site URL: \($0)" },
        ].compactMap { $0 }

        print(found.joined(separator: "\n"))

        if info.format == .localSiteFolder {
            print("Local writes this dump when the site stops. So it can be older than the site. For a current copy, use Export in Local.")
        }

        let siteName = name ?? info.suggestedName
        print("Nexus imports the site as \(siteName). This can take some minutes. The log is \(NexusPaths.standard.log("new-site-\(siteName)").path(percentEncoded: false))")
        let response = try await send(.importSite(SiteImport(backup: path, name: siteName, parent: absolutePath(folder), database: database, git: git)))

        switch response {
        case .siteCreated(let created):
            print(created.message)
        case .siteNotCreated(let failure):
            New.reportFailure(failure)
        default:
            try finish(response)
        }
    }
}

extension SiteTemplate: ExpressibleByArgument {}

extension LaravelStarterKit: ExpressibleByArgument {}

extension LaravelAuthentication: ExpressibleByArgument {}

extension LaravelTests: ExpressibleByArgument {}

extension WordPressNetworkKind: ExpressibleByArgument {}

extension ViteFramework: ExpressibleByArgument {}

extension PackageManager: ExpressibleByArgument {}

struct Park: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Makes each subfolder of a folder a site, for example ~/Sites/shop becomes shop.test.")

    @Argument(help: "The folder.") var folder: String = "."
    @Option(help: "The PHP version line for these sites and for new folders in it. The default comes from nexus site defaults.") var php: String?
    @Option(help: "nginx or apache. The default comes from nexus site defaults.") var server: WebServer?

    func run() async throws {
        try finish(try await send(.park(folder: absolutePath(folder), php: php, server: server)))
    }
}

struct Unpark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stops a parked folder. Its subfolders stay.")

    @Argument(help: "The folder.") var folder: String = "."

    func run() async throws {
        try finish(try await send(.unpark(folder: absolutePath(folder))))
    }
}

struct Ext: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists or turns on and off the shared extensions of one PHP version, for example: nexus ext 8.4 xdebug on")

    @Argument(help: "The PHP version line.") var php: String
    @Argument(help: "The extension.") var name: String?
    @Argument(help: "on or off.") var state: OnOff?

    func run() async throws {
        if let name, let state {
            try finish(try await send(.setExtension(php: php, name: name, enabled: state == .on)))
            return
        }

        try printToggles(try await send(.extensions(php: php)))
    }
}

struct Ini: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shows or replaces the custom php.ini lines of one PHP version.",
        discussion: "For example: nexus ini 8.4 \"memory_limit = 512M\" \"max_execution_time = 120\". PHP checks the lines first. When it refuses a line, the old lines stay."
    )

    @Argument(help: "The PHP version line.") var php: String
    @Argument(help: "The new lines. They replace all custom lines.") var lines: [String] = []
    @Flag(help: "Removes all custom lines.") var clear = false

    func validate() throws {
        if clear, !lines.isEmpty {
            throw ValidationError("Give new lines or --clear, not both.")
        }
    }

    func run() async throws {
        guard lines.isEmpty, !clear else {
            try finish(try await send(.setCustomSettings(php: php, lines: clear ? [] : lines)))
            return
        }

        let response = try await send(.customSettings(php: php))

        guard case .lines(let lines) = response else {
            try finish(response)
            return
        }

        print(lines.isEmpty ? "PHP \(php) has no custom lines." : lines.joined(separator: "\n"))
    }
}

struct Module: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists or turns on and off the modules of Apache or nginx, for example: nexus module apache rewrite off")

    @Argument(help: "apache or nginx.") var server: WebServer
    @Argument(help: "The module.") var name: String?
    @Argument(help: "on or off.") var state: OnOff?

    func run() async throws {
        if let name, let state {
            try finish(try await send(.setModule(server: server, name: name, enabled: state == .on)))
            return
        }

        try printToggles(try await send(.modules(server: server)))
    }
}

struct Lan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shows or changes whether other devices on the network can open the sites.")

    @Argument(help: "on or off.") var state: OnOff?

    func run() async throws {
        try finish(try await send(.lan(enabled: state.map { $0 == .on })))
    }
}

struct TLD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tld",
        abstract: "Shows or changes the dev TLD of the sites, for example: nexus tld internal",
        discussion: "The dev TLD can be test, internal or localhost. A change gives every site a new name, for example shop.test becomes shop.internal."
    )

    @Argument(help: "test, internal or localhost.") var tld: String?

    func run() async throws {
        try finish(try await send(.tld(tld)))
    }
}

extension DatabaseApp: ExpressibleByArgument {}

struct Database: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Lists the database instances, shows the database of a site, copies a database into an instance, and opens one in a database app.",
        subcommands: [List.self, Connection.self, Databases.self, Create.self, Import.self, Copy.self, Open.self, Account.self, Dumps.self, Restore.self],
        defaultSubcommand: List.self
    )

    struct Dumps: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the dumps of removed workspaces in the Nexus trash.")

        func run() async throws {
            let response = try await send(.dumps)

            guard case .dumps(let dumps) = response else {
                try finish(response)
                return
            }

            if dumps.isEmpty {
                print("The trash has no dumps.")
                return
            }

            for dump in dumps {
                print(dump.name.padding(to: 64), ByteCountFormatter.string(fromByteCount: dump.bytes, countStyle: .file))
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restores a dump from the Nexus trash into a new database, for example: nexus db restore <dump> --to mysql-8.4 --as shop_ticket_1")

        @Argument(help: "The name that nexus db dumps shows, or a path.") var dump: String
        @Option(help: "The Nexus instance that gets the database, as nexus db list shows it.") var to: String
        @Option(name: .customLong("as"), help: "The name of the new database.") var name: String

        func run() async throws {
            let isPath = dump.contains("/") || FileManager.default.fileExists(atPath: dump)

            try finish(try await send(.restoreDump(file: isPath ? absolutePath(dump) : dump, instance: to, name: name)))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the MySQL, MariaDB and PostgreSQL instances.")

        func run() async throws {
            let instances = try await databaseInstances()

            if instances.isEmpty {
                print("Nexus has no database instance. Install one with: nexus install mysql 8.4")
                return
            }

            for instance in instances {
                let state = instance.running ? "running" : "stopped"
                let account = "\(instance.account.user)/\(instance.account.password)"
                print([instance.id.padding(to: 14), state.padding(to: 8), "port \(instance.port)".padding(to: 11), account.padding(to: 10), instance.dataFolder].joined(separator: " "))
            }
        }
    }

    struct Copy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copies a database from another server into a Nexus instance, for example: nexus db copy shop --to mysql-8.4",
            discussion: "Nexus makes a dump on the other server and restores it into the instance. It only reads the other server. The default source is root/root on 127.0.0.1, on the standard port of the instance: 3306 for MySQL and MariaDB, 5432 for PostgreSQL."
        )

        @Argument(help: "The database on the other server.") var database: String
        @Option(help: "The Nexus instance that gets the copy, as nexus db list shows it.") var to: String
        @Option(name: .customLong("as"), help: "The name of the copy. The default is the name of the original.") var name: String?
        @Option(help: "The host of the other server.") var fromHost = "127.0.0.1"
        @Option(help: "The port of the other server.") var fromPort: Int?
        @Option(help: "The user on the other server.") var fromUser = DatabaseAccount.standard.user
        @Option(help: "The password on the other server.") var fromPassword = DatabaseAccount.standard.password
        @Flag(help: "Drop the database in the Nexus instance first when it exists.") var replace = false

        func run() async throws {
            let source = DatabaseServer(host: fromHost, port: fromPort, account: DatabaseAccount(user: fromUser, password: fromPassword))
            print("Nexus copies \(database) now. A large database can take some minutes.")
            try finish(try await send(.copyDatabase(DatabaseCopy(source: source, database: database, instance: to, name: name, replace: replace))))
        }
    }

    struct Account: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Changes the user and the password of a running instance, for example: nexus db account mysql-8.4 root --password secret")

        @Argument(help: "The instance, as nexus db list shows it.") var instance: String
        @Argument(help: "The user.") var user: String
        @Option(help: "The password. Leave it out for no password.") var password = ""

        func run() async throws {
            try finish(try await send(.setAccount(instance: instance, account: DatabaseAccount(user: user, password: password))))
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Opens an instance in TablePlus or Sequel Ace, for example: nexus db open mysql-8.4 shop")

        @Argument(help: "The instance, as nexus db list shows it.") var instance: String
        @Argument(help: "The database to open.") var database: String?
        @Option(help: "table_plus or sequel_ace. The default is the first one that is installed.") var app: DatabaseApp?

        func run() async throws {
            guard let found = try await databaseInstances().first(where: { $0.id == instance }) else {
                FileHandle.standardError.write(Data("Nexus has no database instance \(instance). See: nexus db list\n".utf8))
                throw ExitCode.failure
            }

            guard let url = found.url(database: database) else {
                FileHandle.standardError.write(Data("\(database ?? instance) is not a valid database name.\n".utf8))
                throw ExitCode.failure
            }

            if let app, !app.opens(found.kind) {
                FileHandle.standardError.write(Data("\(app.name) cannot open \(found.kind.displayName). Use: --app table_plus\n".utf8))
                throw ExitCode.failure
            }

            let apps = (app.map { [$0] } ?? DatabaseApp.allCases).filter { $0.opens(found.kind) }

            for candidate in apps where open(url, with: candidate) {
                print("\(candidate.name) opens \(instance)\(database.map { " with the database \($0)" } ?? "").")
                return
            }

            FileHandle.standardError.write(Data("No app opened the instance. Install \(apps.map(\.name).joined(separator: " or ")), or connect to \(url.absoluteString)\n".utf8))
            throw ExitCode.failure
        }

        private func open(_ url: URL, with app: DatabaseApp) -> Bool {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/open")
            process.arguments = ["-b", app.bundleIdentifier, url.absoluteString]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else {
                return false
            }

            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}

private func databaseInstances() async throws -> [DatabaseInstance] {
    let response = try await send(.databases)

    guard case .databases(let instances) = response else {
        try finish(response)
        return []
    }

    return instances
}

enum OnOff: String, ExpressibleByArgument {
    case on
    case off
}

private func printToggles(_ response: NexusResponse) throws {
    guard case .toggles(let toggles) = response else {
        try finish(response)
        return
    }

    for toggle in toggles {
        let state = toggle.required ? "on (needed)" : (toggle.enabled ? "on" : "off")
        print([toggle.name.padding(to: 32), state].joined(separator: " "))
    }
}

func absolutePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(filePath: expanded, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
        .standardizedFileURL
        .path(percentEncoded: false)
}

func send(_ request: NexusRequest) async throws -> NexusResponse {
    do {
        return try await NexusClient().send(request)
    } catch {
        FileHandle.standardError.write(Data("\(ErrorText.plain(error))\n".utf8))
        throw ExitCode.failure
    }
}

func finish(_ response: NexusResponse) throws {
    switch response {
    case .done(let message):
        print(message)
    case .failure(let message), .toolNotInstalled(let message):
        FileHandle.standardError.write(Data("\(withLogHint(message))\n".utf8))
        throw ExitCode.failure
    case .portInUse(let conflict):
        FileHandle.standardError.write(Data("\(conflict)\n".utf8))
        throw ExitCode.failure
    case .invalidSettings(let error):
        FileHandle.standardError.write(Data("\(ErrorText.plain(error))\n".utf8))
        throw ExitCode.failure
    case .stopped(let message):
        FileHandle.standardError.write(Data("\(withLogHint(message))\n".utf8))
        throw ExitCode.failure
    default:
        break
    }
}

// A message with a reference to errors.log gets the path of that file (owner, 2026-11-07).
func withLogHint(_ message: String) -> String {
    guard ErrorDetails.split(message).id != nil else {
        return message
    }

    let log = (NexusPaths.standard.errorLog.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    return "\(message)\nThe full output is in \(log)."
}

extension String {
    func padding(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
