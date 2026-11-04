import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// The database servers of the workspaces (D66). Each workspace gets one server for each instance
// that its application uses, on an APFS clone of the data folder of that instance. So a large
// database costs no time and almost no disk, and the database names stay the same. These servers
// have no place in the service list. They run as programs, because they come and go with a
// workspace. They run in each state of a workspace, because a setup needs them and a removal needs
// them for its dump.
extension NexusEngine {
    // The instance of each port that the plan names.
    func serverInstances(of plan: WorkspaceEnvPlan) async throws -> [(tools: DatabaseTools, mainPort: Int)] {
        var instances: [(tools: DatabaseTools, mainPort: Int)] = []
        let runtimes = await databaseRuntimes()

        for mainPort in plan.serverPorts {
            var found: DatabaseTools?

            for tools in runtimes where try await port(of: tools) == mainPort {
                found = tools
                break
            }

            guard let found else {
                throw RuntimeError.unsupported("Nexus has no database instance on port \(mainPort).")
            }

            instances.append((found, mainPort))
        }

        return instances
    }

    // A second setup keeps a finished clone, because that clone holds the data of the workspace. A
    // clone that did not end is no use, so it gets a new run.
    func prepareServer(of tools: DatabaseTools, port: Int, databases: [WorkspaceDatabase], workspace: String, key: String) async throws {
        let record = await stateStore.current().worktrees[key]?.workspaces.first { $0.name == workspace }
        var server = record?.servers.first { $0.instance == tools.id }

        if let known = server, !known.isComplete || !FileManager.default.fileExists(atPath: known.folder) {
            try await discard(known, workspace: workspace, key: key)
            server = nil
        }

        let isNewClone = server == nil

        if server == nil {
            guard Self.holdsDatabase(catalog.dataFolder(for: tools.runtime), kind: tools.kind) else {
                if databases.contains(where: \.isDefault) {
                    throw RuntimeError.unsupported("\(tools.id) has no data. Import a database, and then retry.")
                }

                return
            }

            server = try await cloneInstance(tools, port: port, workspace: workspace, key: key)
        }

        guard let server else {
            return
        }

        try await updateRecord(of: workspace, key: key) { record in
            let others = record.databases.filter { $0.instance != tools.id }

            record.databases = others + databases.map { WorkspaceDatabaseCopy(instance: tools.id, name: $0.name) }
        }

        await syncBackgroundProcesses().value
        try await waitForServer(tools, port: server.port)

        let (client, work) = try serverClient(tools, server)
        defer { try? FileManager.default.removeItem(at: work) }

        // A missing database of another connection does not matter, because the main site does not
        // have it either.
        for database in databases where database.isDefault {
            guard try await client.exists(try DatabaseName.validated(database.name)) else {
                guard isNewClone else {
                    throw RuntimeError.unsupported("The database server of this workspace has no database \(database.name). Create it on that server, or remove the workspace.")
                }

                try await discard(server, workspace: workspace, key: key)
                throw RuntimeError.unsupported("\(tools.id) has no database \(database.name). Import it, and then retry.")
            }
        }
    }

    // A new clone without the database of the application holds no work of the user, and a retry
    // after an import must get a new clone with that database. An older clone can hold that work in
    // its other databases, so it stays. A removal then writes its dump.
    private func discard(_ server: WorkspaceDatabaseServer, workspace: String, key: String) async throws {
        try await updateRecord(of: workspace, key: key) { record in
            record.servers.removeAll { $0 == server }
            record.databases.removeAll { $0.instance == server.instance }
        }

        await syncBackgroundProcesses().value
        try? await Self.removeClone(of: server)
    }

    // The record names the clone before it starts. So a stop of nexusd loses no folder.
    private func cloneInstance(_ tools: DatabaseTools, port: Int, workspace: String, key: String) async throws -> WorkspaceDatabaseServer? {
        guard !updatingServices.contains(tools.id) else {
            throw RuntimeError.unsupported("Nexus updates \(tools.id) now. Retry after the update.")
        }

        let folder = paths.workspaceData
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: tools.id, directoryHint: .isDirectory)
            .path(percentEncoded: false)
        let started = WorkspaceDatabaseServer(instance: tools.id, folder: RealPath.trimmed(folder), port: port, account: try await account(of: tools))

        // A removal can start as soon as the record names this clone, and it must wait for the clone.
        cloningServers.insert(started.folder)
        defer { cloningServers.remove(started.folder) }

        try await updateRecord(of: workspace, key: key) { record in
            record.servers.append(started)
        }

        // Without a record, nothing would ever remove this clone.
        guard await stateStore.current().worktrees[key]?.workspaces.contains(where: { $0.name == workspace && $0.servers.contains(started) }) == true else {
            return nil
        }

        try await clone(tools, to: started.folder)
        try DatabaseSnapshot.removeFilesOfSource(from: started.folder, kind: tools.kind)

        var finished = started

        finished.isComplete = true

        try await updateRecord(of: workspace, key: key) { [finished] record in
            record.servers = record.servers.map { $0 == started ? finished : $0 }
        }

        return finished
    }

    // A stopped instance writes nothing, and it stays stopped. The queue keeps a start of that
    // instance away from the clone.
    private func clone(_ tools: DatabaseTools, to target: String) async throws {
        let source = RealPath.trimmed(catalog.dataFolder(for: tools.runtime).path(percentEncoded: false))

        let isCloned = try await serialWeb {
            guard await self.supervisor.state(of: tools.id)?.isActive != true else {
                return false
            }

            try await Self.cloneOutsideTheActor(source, to: target)
            return true
        }

        guard !isCloned else {
            return
        }

        let (_, client, work) = try await runningClient(tools.id)
        defer { try? FileManager.default.removeItem(at: work) }

        try await DatabaseSnapshot(tools: tools, client: client, source: source, target: target).take()
    }

    // A sync starts no server during an update or after "Stop all services". So a wait would end
    // with a wrong reason.
    func waitForServer(_ tools: DatabaseTools, port: Int) async throws {
        guard !updatingServices.contains(tools.id) else {
            throw RuntimeError.unsupported("Nexus updates \(tools.id) now. Retry after the update.")
        }

        guard !watchingStopped, !stoppingAllServices, await !waitsForStoppedServices() else {
            throw RuntimeError.unsupported("The services are stopped, so the database server of this workspace does not run. Start the services, and then retry.")
        }

        let deadline = ContinuousClock.now + ServiceCatalog.databaseStartTimeout

        while !PortInspector.acceptsConnections(port), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let takesQueries = tools.kind == .postgresql
            ? try await takesQueries(tools, port: port, until: deadline)
            : PortInspector.acceptsConnections(port)

        guard takesQueries else {
            throw RuntimeError.unsupported("The database server of this workspace does not start on port \(port). See \(paths.log(tools.id).path(percentEncoded: false)).")
        }
    }

    func serverClient(_ tools: DatabaseTools, _ server: WorkspaceDatabaseServer) throws -> (DatabaseClient, URL) {
        try preparedClient(tools, port: server.port, account: server.account)
    }

    // The folder with the id of this clone. It exists before the clone has its final name.
    static func cloneFolder(of server: WorkspaceDatabaseServer) -> String {
        (server.folder as NSString).deletingLastPathComponent
    }

    // A clone can hold many files, and each request of nexusd would wait for this removal.
    static func removeClone(of server: WorkspaceDatabaseServer) async throws {
        let folder = cloneFolder(of: server)

        try await Task.detached { try FileManager.default.removeItem(atPath: folder) }.value
    }

    // An update runs in the queue, and a sync can wait for that queue. So this stop needs no sync. The
    // sync of that request starts these servers again.
    func stopWorkspaceServers(of instance: String) async {
        for (id, process) in runningProcesses where process.log == instance {
            try? await processSupervisor.stop(id)
            runningProcesses[id] = nil
        }
    }

    // The servers that must run now. A removed workspace keeps its server until its dump is complete.
    // A program of an instance that Nexus updates must stop, because the update replaces its files.
    func workspaceServerProcesses(_ state: EngineState) async -> [BackgroundProcess] {
        let ofWorkspaces = state.worktrees.flatMap { key, record in
            record.workspaces.flatMap { workspace in
                workspace.servers.map { (owner: Self.processOwner(key: key, workspace: workspace.name), server: $0) }
            }
        }
        let ofRemovals = state.databaseRemovals.map { (owner: Self.processOwner(key: $0.site, workspace: $0.workspace), server: $0.server) }
        let servers = ofWorkspaces + ofRemovals

        guard !servers.isEmpty else {
            return []
        }

        let instances = await databaseRuntimes()
        var processes: [BackgroundProcess] = []

        for (owner, server) in servers where server.isComplete && !removingServers.contains(server.folder) && !updatingServices.contains(server.instance) {
            guard FileManager.default.fileExists(atPath: server.folder), let tools = instances.first(where: { $0.id == server.instance }) else {
                continue
            }

            guard let definition = catalog.workspaceServerDefinition(id: server.folder, instance: server.instance, runtime: tools.runtime, port: server.port, folder: URL(filePath: server.folder, directoryHint: .isDirectory), environment: [Self.processMarker: processMarkerValue]) else {
                continue
            }

            processes.append(BackgroundProcess(owner: owner, command: definition.displayName, log: server.instance, worktree: nil, definition: definition))
        }

        return processes
    }

    // The configuration can look right while the application still reaches another server, because
    // the names of a workspace and of the main site are the same (D66). A host in config/database.php
    // or code in a service provider can do that. So the application itself answers. The default
    // connection must work. Another connection can name a database that does not exist.
    func checkServers(_ plan: WorkspaceEnvPlan, of written: (site: Site, folder: String, defaultConnection: String?), ownPorts: Set<Int>) async throws -> [String] {
        let wrong = plan.connections.filter { !ownPorts.contains($0.value) }.keys.sorted()

        guard wrong.isEmpty else {
            return wrong.map { "The connection \($0) does not use the database server of this workspace." }
        }

        guard !plan.connections.isEmpty else {
            return []
        }

        let installed = await installer.installedRuntimes()
        let php = try await phpCommand(installedPHP(written.site.php, in: installed))
        let probe = ConfigurationProbe(php: URL(filePath: php.executable), environment: php.environment)
        let reached = try await probe.serverPorts(of: plan.connections.keys.sorted(), root: URL(filePath: written.folder, directoryHint: .isDirectory))

        return plan.connections.keys.sorted().compactMap { name in
            guard let ports = reached[name] else {
                return name == written.defaultConnection ? "The connection \(name) does not reach the database server of this workspace." : nil
            }

            return ports.first { !ownPorts.contains($0) }.map { "The connection \(name) reaches the server on port \($0), and that is not the database server of this workspace." }
        }
    }
}
