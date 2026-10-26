import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

public enum NexusCLI {
    public static func main() async {
        await NexusCommand.main()
    }
}

struct NexusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nexus",
        abstract: "Controls the Nexus services from the terminal.",
        version: NexusVersion.current(),
        subcommands: [
            Status.self, Start.self, Stop.self, Port.self, Available.self, Runtimes.self, Install.self, Remove.self,
            Trust.self, Cert.self, Hosts.self, Uninstall.self,
            SiteCommand.self, Park.self, Unpark.self, Ext.self, Module.self, Lan.self,
            Database.self,
        ]
    )
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

    @Argument(help: "The service, as nexus status shows it.") var service: String

    func run() async throws {
        try finish(try await send(.start(service: service)))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stops a service.")

    @Argument(help: "The service, as nexus status shows it.") var service: String

    func run() async throws {
        try finish(try await send(.stop(service: service)))
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

struct Runtimes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists the installed packages.")

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

extension WebServer: ExpressibleByArgument {}

struct SiteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "site",
        abstract: "Adds, lists, changes and removes sites.",
        subcommands: [List.self, Add.self, Edit.self, Remove.self],
        defaultSubcommand: List.self
    )

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
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Adds a folder as a site, for example: nexus site add . --php 8.4 --server apache")

        @Argument(help: "The folder of the site.") var folder: String = "."
        @Option(help: "The host. The default is the folder name with the dev TLD, for example shop.test.") var host: String?
        @Option(name: .customLong("alias"), help: "Another host for the same site. Repeat it for more hosts.") var aliases: [String] = []
        @Option(help: "The PHP version line, for example 8.5. The default is the newest installed one.") var php: String?
        @Option(help: "nginx or apache. The default is nginx.") var server: WebServer?

        func run() async throws {
            try finish(try await send(.addSite(folder: absolutePath(folder), host: host, aliases: aliases, php: php, server: server)))
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Changes the PHP version, the web server or the aliases of a site.")

        @Argument(help: "The host of the site.") var host: String
        @Option(help: "The PHP version line, for example 8.4.") var php: String?
        @Option(help: "nginx or apache.") var server: WebServer?
        @Option(name: .customLong("alias"), help: "The aliases. They replace the current aliases.") var aliases: [String] = []
        @Flag(help: "Remove every alias.") var noAliases = false

        func run() async throws {
            let aliasChange: [String]? = noAliases ? [] : (aliases.isEmpty ? nil : aliases)
            try finish(try await send(.editSite(host: host, change: SiteChange(php: php, server: server, aliases: aliasChange))))
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
    @Option(help: "The PHP version line for these sites. The default is the newest installed one.") var php: String?
    @Option(help: "nginx or apache. The default is nginx.") var server: WebServer?

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

extension DatabaseApp: ExpressibleByArgument {}

struct Database: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Lists the database instances, copies a database into one, and opens one in a database app.",
        subcommands: [List.self, Copy.self, Open.self],
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
    default:
        break
    }
}

private extension String {
    func padding(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
