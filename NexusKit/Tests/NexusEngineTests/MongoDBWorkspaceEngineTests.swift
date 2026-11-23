import Foundation
import NexusConfig
import NexusCore
import NexusLaravel
import NexusRuntime
import Testing
@testable import NexusEngine

// The parts of the MongoDB server of a workspace that need no real mongod (group 6, step 4).
extension NexusEngineTests {
    @Test func theMongoDBServerOfAWorkspaceHasItsSocketInTheRunFolder() throws {
        let paths = NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none"))
        let runtime = InstalledRuntime(name: "mongodb", line: "8.0", version: "8.0.38", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/tmp/mongodb"))
        let catalog = ServiceCatalog(paths: paths)

        let definition = try #require(catalog.workspaceServerDefinition(id: "/data/workspaces/A/mongodb-8.0", instance: "mongodb-8.0", workspace: "fix", runtime: runtime, port: 20011, folder: URL(filePath: "/data/workspaces/A/mongodb-8.0"), environment: [:]))
        let arguments = definition.arguments
        let socket = paths.workspaceDatabaseSocket(.mongodb, line: "8.0", port: 20011)
        let prefix = try #require(arguments.firstIndex(of: "--unixSocketPrefix"))

        #expect(socket.lastPathComponent == "mongodb-20011.sock")
        #expect(URL(filePath: arguments[prefix + 1]).standardizedFileURL == socket.deletingLastPathComponent().standardizedFileURL)
        #expect(!arguments.contains("--nounixsocket"))
        #expect(arguments.contains("--replSet"))
        #expect(arguments.suffix(2) == ["--wiredTigerCacheSizeGB", MongoDBConfig.workspaceCacheSizeGB])
    }

    @Test func theCloneOfAMongoDBLosesTheLockFileOfItsSourceAndKeepsItsKey() throws {
        let folder = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for name in ["mongod.lock", "nexus.key", "WiredTiger", "collection-0-1.wt"] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path(percentEncoded: false), contents: Data())
        }

        try DatabaseSnapshot.removeFilesOfSource(from: folder.path(percentEncoded: false), kind: .mongodb)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted() == ["WiredTiger", "collection-0-1.wt", "nexus.key"])
    }

    @Test func aMongoDBURLOfALaravelApplicationGetsThePortOfTheWorkspace() throws {
        var plan = WorkspaceEnvPlan(nodeFiles: [], usesDatabaseClient: false, request: WorkspaceEnvRequest(workspace: "fix", mainFolder: "/a", workspaceFolder: "/b", mysqlPorts: [], postgresqlPorts: [], redisPorts: []))
        plan.serverURLKeys = ["MONGODB_URI", "DB_URI"]
        plan.serverURLs = ["MONGODB_URI": "mongodb://localhost:27017/shop", "DB_URI": "mongodb://localhost:27017/default"]
        let runtime = InstalledRuntime(name: "mongodb", line: "8.0", version: "8.0.38", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/tmp/mongodb"))
        let tools = DatabaseTools(id: "mongodb-8.0", kind: .mongodb, runtime: runtime)
        let servers = [(tools: tools, mainPort: 27017, port: 20011)]

        let fromEnv = NexusEngine.serverURLValues(of: plan, in: "MONGODB_URI=\"mongodb://nexus:pw@localhost:27017/shop?replicaSet=nexus\"\n", servers: servers)
        let again = NexusEngine.serverURLValues(of: plan, in: "MONGODB_URI=mongodb://127.0.0.1:20011/shop\nDB_URI=mongodb://127.0.0.1:20011/default\n", servers: servers)
        let withKeys = NexusEngine.serverURLValues(of: plan, in: "MONGODB_URI=\"mongodb://${DB_HOST}:27017/shop\"\nDB_URI=mongodb://127.0.0.1:27018/default\n", servers: servers)

        #expect(fromEnv.values == [
            "MONGODB_URI": "mongodb://nexus:pw@127.0.0.1:20011/shop?replicaSet=nexus",
            "DB_URI": "mongodb://127.0.0.1:20011/default",
        ])
        #expect(fromEnv.problems.isEmpty)
        #expect(again.values.isEmpty)
        #expect(again.problems.isEmpty)
        #expect(withKeys.values.isEmpty)
        #expect(withKeys.problems == [
            "Nexus cannot change the URL in DB_URI, so this workspace would use the server of the main site.",
            "MONGODB_URI builds its URL from other keys, so Nexus cannot change it.",
        ])
    }

    @Test func aTaskThatEndsLateStillRunsAfterTheLimit() async throws {
        let late = Task { try await Task.sleep(for: .milliseconds(300)) }
        let quick = Task { () async throws in }
        let failing = Task { throw CancellationError() }

        #expect(try await !NexusEngine.ends(late, within: .milliseconds(20)))
        #expect(!late.isCancelled)
        #expect(try await NexusEngine.ends(quick, within: .seconds(5)))
        await #expect(throws: CancellationError.self) { try await NexusEngine.ends(failing, within: .seconds(5)) }
        try await late.value
    }
}
