import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

// An empty database or a copy for a workspace (step 3 of the order of the work). The workspace gets
// its server on a clone of the instance as with a copy (D66). So the accounts and the settings of the
// instance stay the same, and the .env of the main site works. With an empty database, Nexus then
// drops each database of the application on that server and makes it again, with the same character
// set and collation. That server belongs to the workspace. Nexus drops nothing on the instance.
extension NexusEngine {
    // A WordPress site always gets a copy, because WordPress has no migrations (owner, 2026-11-08).
    // Sites that share a project share their workspaces, so the first choice of these sites counts.
    static func newWorkspaceDatabases(of sites: [Site], settings: WorkspaceSettings) -> WorkspaceDatabaseKind {
        guard !isWordPress(sites) else {
            return .copy
        }

        return sites.lazy.compactMap(\.workspaceDatabases).first ?? settings.newWorkspaceDatabases
    }

    // The first setup chooses, and the workspace keeps that choice. A workspace from before the
    // choice has its clone already, so it keeps its copy.
    func chooseDatabaseKind(of workspace: inout Workspace, key: String) async {
        guard workspace.databaseKind == nil else {
            return
        }

        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }
        let kind = workspace.servers.isEmpty ? Self.newWorkspaceDatabases(of: sites, settings: state.workspaceSettings) : .copy

        workspace.databaseKind = kind
        try? await updateRecord(of: workspace.name, key: key) { record in
            record.databaseKind = record.databaseKind ?? kind
        }
    }

    // The record names the server after the last statement (markEmptied). So a stop of nexusd in
    // between gives a new run, and a retry later keeps the tables that the commands made.
    func emptyDatabases(_ names: [String], tools: DatabaseTools, client: DatabaseClient) async throws {
        for name in Set(names).sorted() {
            let validated = try DatabaseName.validated(name)
            let settings = DatabaseClient.rows(in: try await client.query(EmptyDatabase.settingsQuery(validated, kind: tools.kind))).first ?? []

            for statement in EmptyDatabase.statements(validated, kind: tools.kind, settings: settings) {
                try await client.query(statement)
            }
        }
    }

    func markEmptied(_ server: WorkspaceDatabaseServer, workspace: String, key: String) async throws {
        try await updateRecord(of: workspace, key: key) { record in
            if !record.emptiedServers.contains(server.folder) {
                record.emptiedServers.append(server.folder)
            }
        }
    }
}

// The statements that make a database again without tables. A setting that the catalog gives in
// another form is left out, and the server then uses its default.
enum EmptyDatabase {
    static func settingsQuery(_ name: String, kind: DatabaseKind) -> String {
        kind.usesMySQLProtocol
            ? "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(name)'"
            : "SELECT pg_encoding_to_char(encoding), datcollate, datctype FROM pg_database WHERE datname = '\(name)'"
    }

    // PostgreSQL cannot drop a database in a transaction, so each statement runs on its own. An open
    // transaction of another client makes a drop of MySQL wait, by default for a year.
    static func statements(_ name: String, kind: DatabaseKind, settings: [String]) -> [String] {
        let identifier = DatabaseConfig.identifier(name, kind: kind)
        let values = settings.map { $0.wholeMatch(of: /[A-Za-z0-9_.@-]+/) == nil ? nil : $0 }
        let value = { (index: Int) in values.indices.contains(index) ? values[index] : nil }

        guard kind.usesMySQLProtocol else {
            let options = [value(0).map { "ENCODING '\($0)'" }, value(1).map { "LC_COLLATE '\($0)'" }, value(2).map { "LC_CTYPE '\($0)'" }].compactMap { $0 }
            return [
                "DROP DATABASE IF EXISTS \(identifier) WITH (FORCE)",
                (["CREATE DATABASE \(identifier) TEMPLATE template0"] + options).joined(separator: " "),
            ]
        }

        let options = [value(0).map { "CHARACTER SET \($0)" }, value(1).map { "COLLATE \($0)" }].compactMap { $0 }
        return ["SET SESSION lock_wait_timeout = 60; DROP DATABASE IF EXISTS \(identifier); " + (["CREATE DATABASE \(identifier)"] + options).joined(separator: " ")]
    }
}
