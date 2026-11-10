import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusMCP

// nexus db connection, nexus db databases, nexus db create and nexus db import (owner, 2026-11-09,
// Herd item 19). They follow the site or the workspace of the current folder. Only an import with
// a replace changes a database that exists, and Nexus puts a copy of it in the trash first.
extension Database {
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Loads a dump file into the database of the site or the workspace of the current folder, for example: nexus db import ~/Downloads/shop.sql.gz",
            discussion: "Nexus reads a .sql or .sql.gz file, and a .zip, .tar or .tar.gz file with such a dump in it. For PostgreSQL it also reads a file of pg_dump -Fc. A database that exists changes only with --replace-tables or --replace-database. Nexus then puts a copy of the old database in the trash first."
        )

        @Argument(help: "The dump file.") var file: String
        @Option(help: "The database. The default is the database of the site or the workspace.") var into: String?
        @Option(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var site: String?
        @Option(help: "An instance instead of a site, as nexus db list shows it. Give the database with --into.") var instance: String?
        @Option(help: "The dump in a .zip or .tar file that holds more than one.") var dump: String?
        @Flag(help: "The tables of the dump replace their old tables. The other tables stay.") var replaceTables = false
        @Flag(help: "Nexus drops the database first and loads the dump into an empty database.") var replaceDatabase = false

        func validate() throws {
            if replaceTables, replaceDatabase {
                throw ValidationError("Use --replace-tables or --replace-database, not both.")
            }

            if instance != nil, into == nil {
                throw ValidationError("Give the database with --into, for example: nexus db import shop.sql.gz --instance mysql-8.4 --into shop")
            }
        }

        func run() async throws {
            let (target, name) = try await importTarget()
            let existing: DumpExisting? = replaceTables ? .replaceTables : replaceDatabase ? .replaceDatabase : nil

            print("Nexus loads the dump into \(name) now. A large dump can take some minutes.")
            try finish(try await send(.importDump(DumpImport(file: absolutePath(file), dump: dump, target: target, name: name, existing: existing))))
        }

        private func importTarget() async throws -> (DatabaseTarget, String) {
            if let instance, let into {
                return (.instance(instance), into)
            }

            let target = try await siteTarget(host: site, example: "nexus db import shop.sql.gz --site shop.test")
            let connections = try await databaseConnections(of: target)
            let main = connections.first { $0.instance != nil && !$0.database.isEmpty }

            // The server and the name come from the same connection. The first connection can be on
            // another instance without a database name.
            guard let server = DatabaseTarget.server(of: target, connections: main.map { [$0] } ?? connections), let name = into ?? main?.database else {
                FileHandle.standardError.write(Data("Nexus finds no database of \(target.host) on a server of Nexus. Give one, for example: nexus db import shop.sql.gz --instance mysql-8.4 --into shop\n".utf8))
                throw ExitCode.failure
            }

            return (server, name)
        }
    }

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
