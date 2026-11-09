import ArgumentParser
import Foundation
import NexusCore
import NexusIPC

// nexus db connection, nexus db databases and nexus db create (owner, 2026-11-09, Herd item 19).
// They follow the site or the workspace of the current folder. No command drops a database, so an
// agent cannot remove one by mistake.
extension Database {
    struct Connection: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Shows the database connection of the site or the workspace of the current folder, also as a URL.",
            discussion: "A Laravel site shows the connections of its configuration. A WordPress site shows the database of its configuration file. A workspace shows the databases on its own server."
        )

        @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?
        @Flag(help: "Prints JSON for a script.") var json = false

        func run() async throws {
            let target = try await siteTarget(host: host, example: "nexus db connection shop.test")
            let connections = try await databaseConnections(of: target)

            if json {
                print(try ConnectionDetails.json(connections))
                return
            }

            print(target.workspace.map { "Workspace  \($0.name) of \(target.siteHost)" } ?? "Site       \(target.siteHost)")

            if connections.isEmpty {
                print("Nexus finds no database of \(target.host).")
                return
            }

            for connection in connections {
                ConnectionDetails.lines(connection, inWorkspace: target.workspace != nil).forEach { print($0) }
            }
        }
    }

    struct Databases: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the databases on the server of the site or the workspace of the current folder.")

        @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?
        @Option(help: "An instance instead of a site, as nexus db list shows it.") var instance: String?

        func run() async throws {
            let response = try await send(.serverDatabases(try await serverTarget(host: host, instance: instance, command: "db databases", hostOption: "")))

            guard case .databaseSizes(let databases) = response else {
                try finish(response)
                return
            }

            if databases.isEmpty {
                print("The server has no databases.")
                return
            }

            for database in databases {
                print(database.name.padding(to: 64), ByteCountFormatter.string(fromByteCount: database.bytes, countStyle: .file))
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Makes an empty database on the server of the site or the workspace of the current folder, for example: nexus db create shop_testing",
            discussion: "In a workspace, the database goes on the server of the workspace. So the main checkout does not see it."
        )

        @Argument(help: "The name of the new database.") var name: String
        @Option(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var site: String?
        @Option(help: "An instance instead of a site, as nexus db list shows it.") var instance: String?

        func run() async throws {
            let server = try await serverTarget(host: site, instance: instance, command: "db create \(name)", hostOption: "--site ")

            try finish(try await send(.createDatabase(server, name: name)))
        }
    }
}

// What nexus db connection prints. A script reads the JSON keys, so a key without a value is null
// and does not go away.
struct ConnectionDetails: Encodable {
    let connection: String?
    let database: String
    let host: String
    let port: Int?
    let instance: String?
    let kind: String?
    let user: String?
    let password: String?
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case connection, database, host, port, instance, kind, user, password, url
    }

    init(_ info: DatabaseConnectionInfo) {
        connection = info.connection
        database = info.database
        host = info.host
        port = info.port
        instance = info.instance
        kind = info.kind?.rawValue
        user = info.account?.user
        password = info.account?.password
        url = info.url?.absoluteString
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(connection, forKey: .connection)
        try container.encode(database, forKey: .database)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(instance, forKey: .instance)
        try container.encode(kind, forKey: .kind)
        try container.encode(user, forKey: .user)
        try container.encode(password, forKey: .password)
        try container.encode(url, forKey: .url)
    }

    static func json(_ connections: [DatabaseConnectionInfo]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(connections.map(ConnectionDetails.init)), as: UTF8.self)
    }

    static func lines(_ connection: DatabaseConnectionInfo, inWorkspace: Bool) -> [String] {
        let name = connection.database.isEmpty ? "no database name" : connection.database
        let port = connection.port.map { ", port \($0)" } ?? ""
        let label = connection.connection.map { " (connection \($0))" } ?? ""

        guard let instance = connection.instance else {
            return ["Database   \(name) on \(connection.host)\(port)\(label). This server is not part of Nexus."]
        }

        let server = inWorkspace ? "the server of the workspace (\(instance))" : instance
        let url = connection.url.map { ["URL        \($0.absoluteString)"] } ?? []

        return ["Database   \(name) on \(server)\(port)\(label)"] + url
    }
}

extension DatabaseTarget {
    // The server of the first connection on a server of Nexus. A workspace uses its own server.
    static func server(of target: SiteTarget, connections: [DatabaseConnectionInfo]) -> DatabaseTarget? {
        guard let instance = connections.lazy.compactMap(\.instance).first else {
            return nil
        }

        guard let workspace = target.workspace else {
            return .instance(instance)
        }

        return .workspace(site: target.siteHost, name: workspace.name, instance: instance)
    }
}

private func databaseConnections(of target: SiteTarget) async throws -> [DatabaseConnectionInfo] {
    let response = try await send(.databaseConnections(host: target.siteHost, workspace: target.workspace?.name))

    guard case .databaseConnections(let connections) = response else {
        try finish(response)
        throw ExitCode.failure
    }

    return connections
}

private func serverTarget(host: String?, instance: String?, command: String, hostOption: String) async throws -> DatabaseTarget {
    if let instance {
        return .instance(instance)
    }

    let target = try await siteTarget(host: host, example: "nexus \(command) \(hostOption)shop.test")

    guard let server = DatabaseTarget.server(of: target, connections: try await databaseConnections(of: target)) else {
        FileHandle.standardError.write(Data("Nexus finds no database of \(target.host) on a server of Nexus. Give an instance, for example: nexus \(command) --instance mysql-8.4\n".utf8))
        throw ExitCode.failure
    }

    return server
}
