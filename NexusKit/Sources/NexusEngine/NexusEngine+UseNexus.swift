import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// "Use Nexus…" of a Laravel site (owner, 2026-11-14). Nexus changes the keys of the .env of the
// main checkout that point to another server, for example MAMP PRO. With a copy, the data comes
// first. The .env changes only after the copy, so a failed copy leaves the site as it was.
extension NexusEngine {
    // The plan for the .env of now. It needs no query to a database server.
    private struct UseNexusSetup {
        let site: Site
        let url: String
        let file: String
        let plan: UseNexusPlan
    }

    private static let changedNothing = "Nexus changed nothing."

    // A server that does not answer in this time counts as a server that does not run.
    private static let oldServerTimeout = 3

    // A failure gives nil, because the Databases section shows the problem of the probe already.
    func useNexusInfo(host: String) async -> UseNexusInfo? {
        guard let setup = try? await useNexusSetup(host: host) else {
            return nil
        }

        return UseNexusInfo(
            host: setup.site.host,
            url: setup.url,
            appURL: setup.plan.appURL,
            appURLValue: setup.plan.appURLValue,
            database: await useNexusDatabase(setup.plan.database),
            redis: setup.plan.redis
        )
    }

    // The action checks the old server and the instance of the request again. It does not query
    // the other instances.
    func useNexus(_ request: UseNexusRequest) async throws -> String {
        let host = request.host

        guard let setup = try await useNexusSetup(host: host) else {
            throw RuntimeError.unsupported("The .env of \(host) uses Nexus already. \(Self.changedNothing)")
        }

        let changedText = "The .env of \(host) or a server of Nexus changed after the sheet opened. Open \"Use Nexus…\" again. \(Self.changedNothing)"

        // The order of the keys does not matter for the .env.
        guard Set(setup.plan.changes(choosing: request.instance)) == Set(request.changes) else {
            throw RuntimeError.unsupported(changedText)
        }

        let part = setup.plan.database
        let choice = part?.choices.first { $0.server.id == request.instance }

        if request.copy {
            guard let part, let choice, let name = part.name else {
                throw RuntimeError.unsupported(changedText)
            }

            if await runningDatabaseExists(name, on: choice.server.id) == true {
                throw RuntimeError.unsupported(Self.existsText(name, on: choice.server))
            }

            guard await oldServer(part.source, database: name, clientOf: choice.server.id).holdsDatabase else {
                throw RuntimeError.unsupported("The old server of \(name) does not answer now. \(Self.changedNothing)")
            }
        }

        var step = UseNexusInfo.DatabaseStep.unchanged

        // The servers that the new keys point to must run, also without a database name.
        if let choice {
            try await startForSetup(choice.server.id)
        }

        if let redis = setup.plan.redisServer, !setup.plan.redis.isEmpty {
            try await startForSetup(redis)
        }

        if let part, let choice, let name = part.name {
            let id = choice.server.id
            let exists = try await databaseExists(name, on: id)

            if request.copy {
                guard !exists else {
                    throw RuntimeError.unsupported(Self.existsText(name, on: choice.server))
                }

                try await copy(name, from: part.source, to: id)
                step = .copied
            } else if !exists {
                _ = try await createDatabase(name, on: .instance(id))
                step = .made
            }
        }

        // The keys go into the state before the .env changes. Else a failed save of the state leaves
        // comment lines that "Use the old mail settings" would put back.
        try await stateStore.update { $0.useNexusKeys[host, default: []].formUnion(request.changes.map(\.key)) }

        // The user can change the .env during a long copy. So the change starts from the file of now.
        do {
            try Self.write(EnvRewrite.applyKeepingOldValues(to: try Self.envText(of: setup.file), changes: request.changes), to: setup.file)
        } catch {
            guard let choice, let name = part?.name, step != .unchanged else {
                throw error
            }

            let done = step == .copied ? "copied \(name) to \(choice.server.name)" : "made the empty database \(name) on \(choice.server.name)"
            throw RuntimeError.unsupported("Nexus \(done), but it could not write the .env. \(ErrorText.plain(error))")
        }

        return UseNexusInfo.doneMessage(database: part?.name, server: choice?.server.name, step: step, keys: request.changes.count)
    }

    private static func existsText(_ database: String, on server: UseNexusPlan.Server) -> String {
        "\(server.name) has a database \(database) already. \(changedNothing)"
    }

    private func copy(_ database: String, from source: UseNexusPlan.Source, to instance: String) async throws {
        let server = DatabaseServer(host: source.host, port: source.port, account: source.account, socket: source.socket)

        do {
            _ = try await copyDatabase(DatabaseCopy(source: server, database: database, instance: instance, name: database))
        } catch let stopped as TaskStopped {
            throw TaskStopped(description: "\(stopped.description) Nexus did not change the .env.")
        } catch {
            throw RuntimeError.unsupported("\(ErrorText.plain(error)) Nexus did not change the .env.")
        }
    }

    // An empty plan gives nil.
    private func useNexusSetup(host: String) async throws -> UseNexusSetup? {
        let state = await stateStore.current()
        let (site, folder) = try laravelSite(host, in: state, else: Self.changedNothing)

        guard PHPProject.type(of: site) == .laravel else {
            throw RuntimeError.unsupported("\(host) is no Laravel application. \(Self.changedNothing)")
        }

        let file = try envFile(in: folder, of: host, else: Self.changedNothing)
        let text = try Self.envText(of: file)
        let configuration = try await shownConfiguration(of: site, folder: folder)
        var servers: [UseNexusPlan.Server] = []

        for address in try await databaseAddresses() {
            let tools = address.tools

            servers.append(UseNexusPlan.Server(
                id: tools.id,
                name: Self.instanceName(tools.kind, line: tools.runtime.line),
                kind: tools.kind,
                version: tools.runtime.version,
                port: address.port,
                socket: address.socket,
                account: try await account(of: tools)
            ))
        }

        var redisServers: [UseNexusPlan.RedisServer] = []

        for instance in try await redisInstances() {
            redisServers.append(UseNexusPlan.RedisServer(id: instance.id, port: instance.port, running: await supervisor.state(of: instance.id)?.isActive == true))
        }

        let url = Self.url(for: site.host, in: state)
        let input = UseNexusPlan.Input(
            envText: text,
            hosts: site.hosts,
            url: url,
            httpsPort: state.ports[ServiceCatalog.httpsPortKey] ?? 443,
            databaseServers: servers,
            redisServers: redisServers
        )
        let plan = UseNexusPlan(configuration: configuration, input: input)

        guard !plan.isEmpty else {
            return nil
        }

        return UseNexusSetup(site: site, url: url, file: file, plan: plan)
    }

    // The version of the old server orders the choices again. The client of the first choice
    // reads the old server, as a copy does.
    private func useNexusDatabase(_ part: UseNexusPlan.Database?) async -> UseNexusDatabase? {
        guard let part, let first = part.choices.first else {
            return nil
        }

        let old = await oldServer(part.source, database: part.name, clientOf: first.server.id)
        var choices: [UseNexusChoice] = []

        for choice in UseNexusPlan.ordered(part.choices, kind: part.source.kind, oldVersion: old.version) {
            let exists = await runningDatabaseExists(part.name, on: choice.server.id)

            choices.append(UseNexusChoice(
                instance: choice.server.id,
                name: choice.server.name,
                changes: choice.changes,
                databaseExists: exists,
                canCopy: old.holdsDatabase && exists != true && part.name != nil
            ))
        }

        return UseNexusDatabase(connection: part.connection, database: part.name, choices: choices)
    }

    // One query with the account of the .env and the client of the instance. No connection, a
    // refused account or an error gives no version, and Nexus then offers no copy. The data stays
    // on the old server.
    private func oldServer(_ source: UseNexusPlan.Source, database name: String?, clientOf id: String) async -> (version: String?, holdsDatabase: Bool) {
        let answers = source.socket.map { PortInspector.acceptsConnections(socket: $0) } ?? PortInspector.acceptsConnections(source.port)

        guard answers, let tools = await databaseRuntime(id) else {
            return (nil, false)
        }

        let endpoint = DatabaseEndpoint(host: source.host, port: source.port, account: source.account, socket: source.socket, connectTimeout: Self.oldServerTimeout)
        let sql = tools.kind.usesMySQLProtocol
            ? "SELECT VERSION(), (\(Self.countOfSchema(name ?? "")))"
            : "SELECT current_setting('server_version'), COUNT(*) FROM pg_database WHERE datname = \(PostgreSQLAccess.string(name ?? ""))"

        guard let (client, work) = try? preparedClient(tools, endpoint: endpoint) else {
            return (nil, false)
        }

        defer { try? FileManager.default.removeItem(at: work) }

        guard let row = try? await client.rows(sql).first, row.count == 2 else {
            return (nil, false)
        }

        return (row[0], row[1] == "1")
    }

    // A stopped instance gives nil. nexusd starts it and checks again before the change.
    private func runningDatabaseExists(_ name: String?, on id: String) async -> Bool? {
        guard let name, await supervisor.state(of: id)?.isActive == true else {
            return nil
        }

        return try? await databaseExists(name, on: id)
    }

    private func databaseExists(_ name: String, on id: String) async throws -> Bool {
        let (_, client, work) = try await runningClient(id)
        defer { try? FileManager.default.removeItem(at: work) }

        return try await client.exists(name)
    }
}
