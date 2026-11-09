import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

// nexus db connection, nexus db databases and nexus db create (owner, 2026-11-09, Herd item 19). A
// workspace uses the server of the workspace and never the instance of the main checkout (D48).
extension NexusEngine {
    func databaseConnections(host: String, workspace name: String?) async throws -> [DatabaseConnectionInfo] {
        guard let name else {
            return try await mainConnections(host: host)
        }

        let workspace = try await workspaceRecord(host: host, name: name)
        var connections: [DatabaseConnectionInfo] = []

        for database in workspace.databases {
            let server = workspace.servers.first { $0.instance == database.instance }
            let kind = await databaseRuntime(database.instance)?.kind

            connections.append(DatabaseConnectionInfo(connection: nil, database: database.name, host: "127.0.0.1", port: server?.port, instance: database.instance, kind: kind, account: server?.account))
        }

        return connections
    }

    func serverDatabases(_ target: DatabaseTarget) async throws -> [DatabaseSize] {
        let (tools, client, work) = try await client(for: target)
        defer { try? FileManager.default.removeItem(at: work) }

        return try await databaseSizes(tools: tools, client: client)
    }

    func createDatabase(_ name: String, on target: DatabaseTarget) async throws -> String {
        let validated = try DatabaseName.validated(name)
        let (tools, client, work) = try await client(for: target)
        defer { try? FileManager.default.removeItem(at: work) }

        let server = switch target {
        case .instance(let id): id
        case .workspace(_, let workspace, let instance): "the server of the workspace \(workspace) (\(instance))"
        }

        guard try await !client.exists(validated) else {
            throw RuntimeError.unsupported("The database \(validated) exists on \(server) already.")
        }

        try await client.query("CREATE DATABASE \(DatabaseConfig.identifier(validated, kind: tools.kind))")
        return "Nexus made the empty database \(validated) on \(server)."
    }

    // A Laravel site has the connections of its configuration. A WordPress site has the database of
    // its configuration file. Another site has no database that Nexus can find.
    private func mainConnections(host: String) async throws -> [DatabaseConnectionInfo] {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        let instances = try await databaseInstances()

        func connection(_ name: String?, database: String, host: String, port: Int?, instance id: String?) -> DatabaseConnectionInfo {
            let instance = instances.first { $0.id == id }

            return DatabaseConnectionInfo(connection: name, database: database, host: host, port: port, instance: instance?.id, kind: instance?.kind, account: instance?.account)
        }

        guard site.kind == .php, PHPProject.type(of: site).isWordPress else {
            return try await siteDatabases(host: host).map { connection($0.connection, database: $0.database, host: $0.host, port: $0.port, instance: $0.instance) }
        }

        guard let config = try await wordPressTarget(host).config, let database = config.database else {
            return []
        }

        let port = config.address?.localPort
        let instance = port.flatMap { port in instances.first { $0.kind.usesMySQLProtocol && $0.port == port } }

        return [connection(nil, database: database, host: config.host ?? "", port: port, instance: instance?.id)]
    }

    private func workspaceRecord(host: String, name: String) async throws -> Workspace {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        guard let workspace = state.worktrees[ProjectFolder.workspaceKey(of: site)]?.workspaces.first(where: { $0.name == name }) else {
            throw RuntimeError.unsupported("\(host) has no workspace \(name).")
        }

        return workspace
    }

    func client(for target: DatabaseTarget) async throws -> (DatabaseTools, DatabaseClient, URL) {
        switch target {
        case .instance(let id):
            return try await runningClient(id)
        case .workspace(let host, let name, let instance):
            return try await workspaceClient(host: host, name: name, instance: instance)
        }
    }

    private func workspaceClient(host: String, name: String, instance: String) async throws -> (DatabaseTools, DatabaseClient, URL) {
        let workspace = try await workspaceRecord(host: host, name: name)

        guard let tools = await databaseRuntime(instance) else {
            throw RuntimeError.unsupported("Nexus has no database instance \(instance). See: nexus db list")
        }

        guard let server = workspace.servers.first(where: { $0.instance == instance }) else {
            throw RuntimeError.unsupported("The workspace \(name) has no server of \(instance).")
        }

        guard PortInspector.acceptsConnections(server.port) else {
            throw RuntimeError.unsupported("The database server of the workspace \(name) does not run. See: nexus workspace list")
        }

        let (client, work) = try serverClient(tools, server)
        return (tools, client, work)
    }
}
