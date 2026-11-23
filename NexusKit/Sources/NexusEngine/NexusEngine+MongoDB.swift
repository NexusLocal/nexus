import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusMongoDB
import NexusRuntime
import NexusSupervisor

// The MongoDB server of a command: an instance, or the server of a workspace. name is the server in
// a message.
struct MongoDBAddress: Sendable {
    let tools: DatabaseTools
    let name: String
    let port: Int
    let account: DatabaseAccount
}

// MongoDB (group 6). Each instance is a replica set of one server with the name nexus, because
// transactions need a replica set. Nexus talks to the server with its own client (NexusMongoDB).
// Without a password the server runs without a login and has no user (D35).
extension NexusEngine {
    // mongod makes its files at its first start, but its data folder must exist. A new instance
    // stores its account here, as the other kinds do after their initialization.
    func prepareMongoDB(_ tools: DatabaseTools) async throws {
        try UserConfigFile.writeIfMissing(MongoDBConfig.initialConf, to: paths.databaseConfig(.mongodb, line: tools.runtime.line))

        let data = catalog.dataFolder(for: tools.runtime)

        guard !Self.holdsDatabase(data, kind: .mongodb) else {
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false))) ?? []
        guard contents.allSatisfy({ $0 == ".DS_Store" || $0 == MongoDBConfig.keyFileName }) else {
            throw RuntimeError.unsupported("\(data.path(percentEncoded: false)) has files, but no MongoDB data. Move the folder away. Nexus then makes a new data folder at the next start.")
        }

        let account = try await account(of: tools)

        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Self.setMongoDBKey(for: account, in: data)
        try await stateStore.update { $0.databaseAccounts[tools.id] = account }
    }

    // The server needs a login when its data folder has the key file.
    static func setMongoDBKey(for account: DatabaseAccount, in data: URL) throws {
        let file = MongoDBConfig.keyFile(in: data)
        let exists = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))

        guard !account.password.isEmpty else {
            if exists {
                try FileManager.default.removeItem(at: file)
            }
            return
        }

        if !exists {
            try writePrivate(MongoDBConfig.newKey(), to: file)
        }
    }

    // The set needs the address of the server in its configuration. A new data folder gets it at
    // its first start. After nexus port the set has the old port, and the server then takes no
    // writes. So the server starts once without the set, and Nexus moves the set to the new port.
    func openMongoDB(_ id: String, _ definition: ServiceDefinition) async throws {
        guard let tools = await databaseRuntime(id), tools.kind == .mongodb, let port = definition.ports.first else {
            return
        }

        guard try await !openReplicaSet(tools, port: port, until: .now + definition.startTimeout) else {
            return
        }

        try await supervisor.stop(id, cause: "a move of its replica set to port \(port)")
        try await moveReplicaSet(of: tools, data: catalog.dataFolder(for: tools.runtime), to: port, logFile: definition.logFile)
        try await supervisor.start(definition)
        try await waitForConnections(definition)

        guard try await openReplicaSet(tools, port: port, until: .now + definition.startTimeout) else {
            throw SupervisorError.launchFailed("\(definition.displayName) has the replica set of another port. See \(definition.logFile.path(percentEncoded: false)).")
        }
    }

    // Returns false when the set has another port. The first start of an instance with a password
    // has no user yet. The localhost exception of MongoDB then lets a connection without a login
    // start the set and make the first user.
    func openReplicaSet(_ tools: DatabaseTools, port: Int, until deadline: ContinuousClock.Instant) async throws -> Bool {
        let account = try await account(of: tools)
        var needsUser = false
        let connection: MongoDBConnection

        do {
            connection = try await MongoDBConnection.connect(port: port, account: account)
        } catch MongoDBError.loginFailed where !account.password.isEmpty {
            connection = try await MongoDBConnection.connect(port: port)
            needsUser = true
        }

        let server = MongoDBServer(connection)

        if !needsUser, let setPort = try await server.replicaSetPort() {
            guard setPort == port else {
                await connection.disconnect()
                return false
            }
        } else {
            try await server.initiateReplicaSet(port: port)
        }

        while try await !server.isPrimary() {
            guard ContinuousClock.now < deadline else {
                await connection.disconnect()
                throw SupervisorError.launchFailed("\(tools.kind.displayName) \(tools.runtime.version) takes no writes on port \(port). See \(paths.log(tools.id).path(percentEncoded: false)).")
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        if needsUser {
            try await server.createUser(account)
        }

        await connection.disconnect()
        return true
    }

    // The server runs without the set and without a login, on a free port that no program of the
    // user knows. It reads no mongod.conf, so a line of the user cannot add the set or a login.
    func moveReplicaSet(of tools: DatabaseTools, data: URL, to port: Int, logFile: URL) async throws {
        let temporaryPort = try IPv4Socket.freeLoopbackPort()
        let definition = ServiceDefinition(
            id: "\(tools.id)-move",
            displayName: "\(tools.kind.displayName) \(tools.runtime.version) without its replica set",
            executable: tools.bin("mongod"),
            arguments: MongoDBConfig.serverArguments(config: nil, data: data, port: temporaryPort, replicaSet: nil, keyFile: nil),
            workingDirectory: data,
            ports: [temporaryPort],
            logFile: logFile,
            startTimeout: ServiceCatalog.databaseStartTimeout,
            stopTimeout: ServiceCatalog.databaseStopTimeout,
            restartsAfterExit: false
        )
        let mover = ProcessSupervisor()

        try await mover.start(definition)

        do {
            let deadline = ContinuousClock.now + definition.startTimeout
            while !PortInspector.acceptsConnections(temporaryPort), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }

            let connection = try await MongoDBConnection.connect(port: temporaryPort)
            try await MongoDBServer(connection).moveReplicaSet(toPort: port)
            await connection.disconnect()
        } catch {
            try? await mover.stop(definition.id, cause: "a failed move of the replica set")
            throw error
        }

        try await mover.stop(definition.id, cause: "the end of the move of the replica set")
    }

    // A connection with the account of a running instance. The caller ends it. The timeout is for
    // each answer.
    func mongoDBServer(_ tools: DatabaseTools, timeout: TimeInterval = 10) async throws -> MongoDBServer {
        guard await supervisor.state(of: tools.id)?.isActive == true else {
            throw RuntimeError.unsupported("Start \(tools.id) first.")
        }

        let port = try await connectionPort(of: tools)

        do {
            return MongoDBServer(try await MongoDBConnection.connect(port: port, account: try await account(of: tools), timeout: timeout))
        } catch let error as MongoDBError {
            throw RuntimeError.unsupported("Nexus cannot connect to \(tools.id) on port \(port). \(error.description)")
        }
    }

    // The connection ends after the work, also after an error.
    func withMongoDB<Value: Sendable>(_ tools: DatabaseTools, _ work: (MongoDBServer) async throws -> Value) async throws -> Value {
        try await withMongoDB(at: try await mongoDBAddress(of: tools), work)
    }

    func withMongoDB<Value: Sendable>(at address: MongoDBAddress, _ work: (MongoDBServer) async throws -> Value) async throws -> Value {
        let server: MongoDBServer

        do {
            server = MongoDBServer(try await MongoDBConnection.connect(port: address.port, account: address.account))
        } catch let error as MongoDBError {
            throw RuntimeError.unsupported("Nexus cannot connect to \(address.name) on port \(address.port). \(error.description)")
        }

        do {
            let value = try await work(server)
            await server.connection.disconnect()
            return value
        } catch {
            await server.connection.disconnect()
            throw error
        }
    }

    // A running instance.
    func mongoDBAddress(of tools: DatabaseTools) async throws -> MongoDBAddress {
        guard await supervisor.state(of: tools.id)?.isActive == true else {
            throw RuntimeError.unsupported("Start \(tools.id) first.")
        }

        return MongoDBAddress(tools: tools, name: tools.id, port: try await connectionPort(of: tools), account: try await account(of: tools))
    }

    // A command for a workspace reaches the server of the workspace and never the instance (D48).
    func mongoDBAddress(_ target: DatabaseTarget) async throws -> MongoDBAddress {
        switch target {
        case .instance(let id):
            guard let tools = await databaseRuntime(id) else {
                throw RuntimeError.unsupported("Nexus has no database instance \(id). See: nexus db list")
            }

            return try await mongoDBAddress(of: tools)
        case .workspace(let host, let name, let instance):
            let (tools, server) = try await runningWorkspaceServer(host: host, name: name, instance: instance)
            return MongoDBAddress(tools: tools, name: target.serverName, port: server.port, account: server.account)
        }
    }

    // A server of a workspace is used by no site of the main checkout.
    func mongoDBSizes(at address: MongoDBAddress) async throws -> [DatabaseSize] {
        let databases = try await withMongoDB(at: address) { try await $0.databases() }
        let users = await databaseUsers(kind: .mongodb, port: address.port, socket: socketPath(of: address.tools, port: address.port))

        return databases.map { DatabaseSize(name: $0.name, bytes: $0.bytes, usedBy: users[$0.name]) }
    }

    // A password needs the key file and a restart with a login. Without a password the server runs
    // without a login and has no user. The new account is stored before the restart. So the next
    // start of the server uses the right login, also after a failed restart.
    func setMongoDBAccount(_ tools: DatabaseTools, from old: DatabaseAccount, to new: DatabaseAccount) async throws {
        let data = catalog.dataFolder(for: tools.runtime)
        let cause = "a change of its account"

        switch (old.password.isEmpty, new.password.isEmpty) {
        case (true, true):
            try await stateStore.update { $0.databaseAccounts[tools.id] = new }
        case (true, false):
            try await withMongoDB(tools) { try await $0.setUser(new) }
            try Self.setMongoDBKey(for: new, in: data)
            try await stateStore.update { $0.databaseAccounts[tools.id] = new }
            _ = try await restart(tools.id, cause: cause)
        case (false, false):
            try await withMongoDB(tools) { try await $0.setUser(new) }
            try await stateStore.update { $0.databaseAccounts[tools.id] = new }

            if old.user != new.user {
                try await withMongoDB(tools) { try await $0.dropUser(old.user) }
            }
        case (false, true):
            try Self.setMongoDBKey(for: new, in: data)
            try await stateStore.update { $0.databaseAccounts[tools.id] = new }
            _ = try await restart(tools.id, cause: cause)
            try await withMongoDB(tools) { try await $0.dropUser(old.user) }
        }
    }
}
