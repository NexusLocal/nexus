import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

public enum NexusCLI {
    public static func main() async {
        if let invocation = toolInvocation(CommandLine.arguments) {
            do {
                try await runTool(invocation.tool, invocation.arguments, throughLink: invocation.throughLink)
            } catch {
                NexusCommand.exit(withError: error)
            }
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
            SiteCommand.self, WorkspaceCommand.self, Park.self, Unpark.self, Ext.self, Ini.self, Module.self, Lan.self, TLD.self,
            Database.self, PHP.self, Composer.self, Node.self, NPM.self,
        ]
    )
}

// nexus php, composer, node and npm (D38). NexusCLI.main runs them before the parser. These
// commands put them in nexus --help.
struct PHP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "php",
        abstract: "Runs the PHP of the site in the current folder, for example: nexus php -v",
        discussion: "Outside a site, nexus php uses the PHP version of a new site. A folder in a git worktree of a site uses the versions of that site."
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

// nexusd says what to run. The nexus command then becomes that program. So the program gets the
// terminal, the signals and the exit code. The current folder is the real path, as getcwd gives
// it. When nexusd does not answer, a link in bin/ runs the next program with its name on the
// PATH. A terminal with the PATH setting then keeps a working php.
private func runTool(_ tool: ProjectTool, _ arguments: [String], throughLink: Bool = false) async throws {
    let response: NexusResponse
    let environment = ProcessInfo.processInfo.environment
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

    do {
        response = try await NexusClient().send(.tool(tool, folder: FileManager.default.currentDirectoryPath))
    } catch let error as NexusClientError where throughLink {
        guard let nexus = Bundle.main.executableURL.map(RealPath.of),
              let other = NexusCLI.nextProgram(named: tool.rawValue, path: path, nexus: nexus) else {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode.failure
        }

        var otherEnvironment = environment
        otherEnvironment["PATH"] = NexusCLI.path(path, without: nexus)

        FileHandle.standardError.write(Data("nexusd does not answer. This \(tool.rawValue) is \(other), the next one on the PATH. Open the Nexus app to use the versions of the site.\n".utf8))
        try execute(other, [other] + arguments, environment: otherEnvironment)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        throw ExitCode.failure
    }

    guard case .tool(let command) = response else {
        try finish(response)
        throw ExitCode.failure
    }

    var toolEnvironment = environment.merging(command.environment) { _, new in new }
    toolEnvironment["PATH"] = (command.path + [path]).joined(separator: ":")
    try execute(command.executable, [command.executable] + command.arguments + arguments, environment: toolEnvironment)
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
                print("    \(reason)")
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
    }
}

struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Shows the workspaces of the sites.",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the workspaces of the sites.")

        func run() async throws {
            let response = try await send(.sites)

            guard case .sites(let sites) = response else {
                try finish(response)
                return
            }

            let rows = sites.flatMap { site in
                (site.workspaces ?? []).map { (site: site.hosts.first ?? "", workspace: $0) }
            }

            if rows.isEmpty {
                print("Nexus has no workspaces. A new git worktree of a site gets one.")
                return
            }

            for row in rows {
                print([row.site.padding(to: 28), row.workspace.name.padding(to: 28), (row.workspace.url ?? "").padding(to: 44), row.workspace.folder].joined(separator: " "))

                if let problem = row.workspace.problem {
                    print("    does not run: \(problem)")
                }
            }
        }
    }
}

extension WebServer: ExpressibleByArgument {}

struct SiteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "site",
        abstract: "Adds, lists, changes and removes sites.",
        subcommands: [List.self, Add.self, Edit.self, Remove.self, Defaults.self, Probe.self],
        defaultSubcommand: List.self
    )

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
                print([site.url.padding(to: 36), "PHP \(site.php)".padding(to: 9), site.server.rawValue.padding(to: 7), origin.padding(to: 7), site.documentRoot].joined(separator: " "))

                if site.hosts.count > 1 {
                    print("    aliases: \(site.hosts.dropFirst().joined(separator: ", "))")
                }

                if let group = site.group {
                    print("    group: \(group)")
                }

                if let problem = site.problem {
                    print("    does not run: \(problem)")
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

        func run() async throws {
            try finish(try await send(.addSite(folder: absolutePath(folder), host: host, aliases: aliases, php: php, server: server, group: group)))
        }
    }

    struct Defaults: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows or changes the webserver, the PHP version and the Node version of a new site, for example: nexus site defaults --php 8.4")

        @Option(help: "The PHP version line of a new site, or newest for the newest installed one.") var php: String?
        @Option(help: "nginx or apache.") var server: WebServer?
        @Option(help: "The Node version line of a new site, or project for the version that the files of the project name.") var node: String?

        func run() async throws {
            let response = try await send(.siteDefaults)

            guard case .siteDefaults(var defaults) = response else {
                try finish(response)
                return
            }

            guard php != nil || server != nil || node != nil else {
                print(defaults.summary)
                return
            }

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
        static let configuration = CommandConfiguration(abstract: "Changes the PHP version, the Node version, the web server or the aliases of a site.")

        @Argument(help: "The host of the site.") var host: String
        @Option(help: "The PHP version line, for example 8.4.") var php: String?
        @Option(help: "The Node version line, for example 24, or project for the version that the files of the project name.") var node: String?
        @Option(help: "nginx or apache.") var server: WebServer?
        @Option(name: .customLong("alias"), help: "The aliases. They replace the current aliases.") var aliases: [String] = []
        @Flag(help: "Remove every alias.") var noAliases = false
        @Option(help: "on or off. With on, a new git worktree gets a workspace.") var workspaces: OnOff?

        func run() async throws {
            let aliasChange: [String]? = noAliases ? [] : (aliases.isEmpty ? nil : aliases)
            try finish(try await send(.editSite(host: host, change: SiteChange(php: php, server: server, aliases: aliasChange, node: node, automaticWorkspaces: workspaces.map { $0 == .on }))))
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
        abstract: "Lists the database instances, copies a database into one, and opens one in a database app.",
        subcommands: [List.self, Copy.self, Open.self, Account.self],
        defaultSubcommand: List.self
    )

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

private func absolutePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(filePath: expanded, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
        .standardizedFileURL
        .path(percentEncoded: false)
}

private func send(_ request: NexusRequest) async throws -> NexusResponse {
    do {
        return try await NexusClient().send(request)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        throw ExitCode.failure
    }
}

private func finish(_ response: NexusResponse) throws {
    switch response {
    case .done(let message):
        print(message)
    case .failure(let message):
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    case .portInUse(let conflict):
        FileHandle.standardError.write(Data("\(conflict)\n".utf8))
        throw ExitCode.failure
    case .invalidSettings(let error):
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        throw ExitCode.failure
    case .stopped(let message):
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    default:
        break
    }
}

extension String {
    func padding(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
