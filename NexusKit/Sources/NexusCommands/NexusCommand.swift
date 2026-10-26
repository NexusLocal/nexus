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
            let ports = service.ports.map(String.init).joined(separator: ", ")
            print([service.id.padding(to: 14), state(service.state).padding(to: 22), "port \(ports)".padding(to: 12), service.displayName].joined(separator: " "))

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
