import Foundation
import NexusCore
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// The Redis instances of the workspaces (D47). Nexus reads the keyspace of an instance and empties
// the indexes of a workspace that went away. Only an instance that nexusd supervises gets this
// command, because another Redis can hold data of the user on the same port.
extension NexusEngine {
    struct RedisInstance: Sendable {
        let id: String
        let port: Int
        let client: URL

        func command(_ arguments: String...) -> Command {
            Command(executable: client, arguments: ["-p", String(port)] + arguments)
        }
    }

    // A port in the state does not prove an instance. The state keeps the port of a Redis that the
    // user removed, and another Redis can use that port now. A running instance keeps its port
    // until a restart, while nexus port changes the state at once. So its port comes from the
    // supervisor, and a command does not reach the other Redis on the new port.
    func redisInstances() async throws -> [RedisInstance] {
        var instances: [RedisInstance] = []
        let running = await supervisor.status().filter(\.state.isActive)

        for runtime in await serviceRuntimes() where runtime.name == "redis" {
            guard let id = catalog.serviceID(for: runtime) else {
                continue
            }

            let nextPort = try await ports(for: runtime)[id] ?? ServiceCatalog.redisStandardPort

            instances.append(RedisInstance(
                id: id,
                port: running.first { $0.id == id }?.ports.first ?? nextPort,
                client: runtime.folder.appending(path: "bin/redis-cli")
            ))
        }

        return instances
    }

    // The start does not change which services nexusd starts at its own start. So a service that
    // "Stop all services" stopped stays in that list. The check runs in the queue, because a
    // removal can run a stopped instance for a moment and stop it again.
    func startForSetup(_ id: String) async throws {
        guard !updatingServices.contains(id) else {
            throw RuntimeError.unsupported("Nexus updates \(id) now. Retry after the update.")
        }

        try await serialWeb {
            guard await self.supervisor.state(of: id)?.isActive != true else {
                return
            }

            let stoppedByStopAll = await self.stateStore.current().stoppedByStopAll.contains(id)
            _ = try await self.start(id, enable: false)

            if stoppedByStopAll {
                try await self.stateStore.update { $0.stoppedByStopAll.insert(id) }
            }
        }
    }

    func indexesWithKeys(on instance: RedisInstance) async throws -> Set<Int> {
        try await Self.waitForData(of: instance)
        return Self.indexes(inKeyspace: try await CommandRunner.run(instance.command("INFO", "keyspace")).standardOutput)
    }

    // Redis accepts a connection while it loads its data file. Until the end of the load, it
    // refuses each query and its keyspace is not complete. An instance that restarts after a
    // crash counts as active, and it refuses the connection for a moment.
    private static func waitForData(of instance: RedisInstance) async throws {
        let deadline = ContinuousClock.now + ServiceCatalog.databaseStartTimeout

        while (try? await CommandRunner.run(instance.command("PING")))?.trimmed != "PONG" {
            guard ContinuousClock.now < deadline else {
                throw RuntimeError.unsupported("\(instance.id) does not take queries on port \(instance.port).")
            }

            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // INFO ends each line with a carriage return and a line feed. Swift counts these as one
    // character, so a split on "\n" finds no line.
    static func indexes(inKeyspace text: String) -> Set<Int> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            line.prefixMatch(of: /db(\d+):/).flatMap { Int($0.1) }
        })
    }

    // The indexes in the .env of each main site. A setup probes only its own project, because a
    // probe of each site takes too long. A main site can have an index from 16 up without keys at
    // this moment, so the keyspace does not show that index.
    func redisIndexesOfMainSites() async -> Set<Int> {
        let sites = resolvedSites(await stateStore.current()).map(\.site)
        let roots = Set(sites.compactMap { LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: $0), directoryHint: .isDirectory)) })

        return roots.reduce(into: []) { indexes, root in
            if let text = try? String(contentsOf: root.appending(path: ".env"), encoding: .utf8) {
                indexes.formUnion(EnvRewrite.redisIndexes(in: text))
            }
        }
    }

    // A removal has no plan of the main site, and only a probe shows a fixed index in its
    // config/database.php. Without a probe, the indexes stay as they are. Without a site, no main
    // site of this project can use them.
    func emptyRedisIndexes(of removed: [Workspace], key: String) async {
        let indexes = Set(removed.flatMap(\.redisIndexesOnInstances))

        guard !indexes.isEmpty else {
            return
        }

        do {
            let mainIndexes = try await mainRedisIndexes(ofRecord: key, workspace: removed[0].name)
            await emptyRedisIndexes(indexes.filter { !mainIndexes.contains($0.index) })
        } catch {
            for id in Set(indexes.map(\.instance)) {
                writeToLog(of: id, "Nexus did not empty the Redis indexes of \(removed.map(\.name)), because it cannot read the configuration of the main site. \(error)\n")
            }
        }
    }

    private func mainRedisIndexes(ofRecord key: String, workspace: String) async throws -> Set<Int> {
        let sites = resolvedSites(await stateStore.current()).map(\.site)

        guard let site = sites.first(where: { ProjectFolder.workspaceKey(of: $0) == key }),
              let main = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return []
        }

        let mainFolder = RealPath.of(main)

        return try await envPlan(workspace: workspace, site: site, mainFolder: mainFolder, workspaceFolder: mainFolder).mainRedisIndexes
    }

    // An index with keys stays out of the choice of a later workspace. So an index that this step
    // cannot empty only keeps its data, and no workspace reads it. A setup does not choose these
    // indexes during this step, because the step would remove the keys of the new workspace. An
    // index that a main site uses now stays as it is.
    func emptyRedisIndexes(_ indexes: Set<WorkspaceRedisIndex>) async {
        guard !indexes.isEmpty else {
            return
        }

        emptyingRedisIndexes.formUnion(indexes)
        defer { emptyingRedisIndexes.subtract(indexes) }

        let mainIndexes = await redisIndexesOfMainSites()
        let unused = indexes.filter { !mainIndexes.contains($0.index) }

        for (id, indexesOfInstance) in Dictionary(grouping: unused, by: \.instance) {
            do {
                try await serialWeb { try await self.empty(indexesOfInstance.map(\.index), on: id) }
            } catch {
                writeToLog(of: id, "Nexus could not empty the Redis indexes \(indexesOfInstance.map(\.index).sorted()). \(error)\n")
            }
        }
    }

    // A stopped instance runs only for this step. startService changes no choice of the user, so
    // a service that the user stopped stays stopped. A port conflict of this step is not a start
    // of the user, so the service list does not show it. The instance comes from here and not
    // from the caller, because a request before this one in the queue can change its port.
    private func empty(_ indexes: [Int], on id: String) async throws {
        guard !watchingStopped else {
            return
        }

        guard !updatingServices.contains(id) else {
            throw RuntimeError.unsupported("Nexus updates \(id) now.")
        }

        guard let instance = try await redisInstances().first(where: { $0.id == id }) else {
            throw RuntimeError.unsupported("\(id) is not installed.")
        }

        let ranBefore = await supervisor.state(of: id)?.isActive == true
        let earlierConflict = portConflicts[id]
        var failure: (any Error)?

        do {
            if !ranBefore {
                _ = try await startService(id)
            }

            try await Self.waitForData(of: instance)

            for index in indexes {
                try await Self.empty(index, on: instance)
            }
        } catch {
            failure = error
        }

        if !ranBefore {
            try? await supervisor.stop(id)
            portConflicts[id] = earlierConflict
        }

        if let failure {
            throw failure
        }
    }

    // SELECT and FLUSHDB stay in one script. redis-cli -n runs its command on index 0 when the
    // index does not exist, and index 0 belongs to a main site. A script stops at the failed
    // SELECT. redis-cli exits with 0 after an error of Redis, so only the answer proves the result.
    private static func empty(_ index: Int, on instance: RedisInstance) async throws {
        let script = "redis.call('SELECT', ARGV[1]) return redis.call('FLUSHDB')"
        let answer = try await CommandRunner.run(instance.command("EVAL", script, "0", String(index))).trimmed

        guard answer == "OK" else {
            throw RuntimeError.unsupported("Redis index \(index) on \(instance.id) stays as it is: \(answer)")
        }
    }

    func writeToLog(of id: String, _ line: String) {
        if let log = try? LogFile.openForAppending(paths.log(id)) {
            try? log.write(contentsOf: Data(line.utf8))
            try? log.close()
        }
    }
}
