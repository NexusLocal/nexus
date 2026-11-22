import Foundation
import NexusCore

public struct MongoDBDatabase: Sendable, Equatable {
    public let name: String
    public let bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

// The commands that Nexus sends to a MongoDB server.
public struct MongoDBServer: Sendable {
    // Each server of Nexus is a replica set of one server, because transactions need one. A project
    // can name the set in its URL, so the name is the same in each workspace.
    public static let replicaSet = "nexus"
    public static let systemDatabases: Set<String> = ["admin", "config", "local"]

    private static let alreadyInitialized = 23
    private static let notYetInitialized = 94
    private static let namespaceExists = 48
    private static let userNotFound = 11

    public let connection: MongoDBConnection

    public init(_ connection: MongoDBConnection) {
        self.connection = connection
    }

    public func isPrimary() async throws -> Bool {
        try await connection.run(["hello": .int32(1)])["isWritablePrimary"]?.bool ?? false
    }

    public func databases() async throws -> [MongoDBDatabase] {
        let answer = try await connection.run(["listDatabases": .int32(1)])

        return (answer["databases"]?.array ?? []).compactMap { value in
            guard let database = value.document, let name = database["name"]?.string, !Self.systemDatabases.contains(name) else {
                return nil
            }

            return MongoDBDatabase(name: name, bytes: database["sizeOnDisk"]?.int64 ?? 0)
        }
    }

    public func dropDatabase(_ name: String) async throws {
        try await connection.run(["dropDatabase": .int32(1)], on: name)
    }

    // MARK: The replica set

    // A new data folder has no set. A folder that has one keeps it.
    public func initiateReplicaSet(port: Int) async throws {
        let configuration: BSONDocument = [
            "_id": .string(Self.replicaSet),
            "members": .array([.document(["_id": .int32(0), "host": .string(Self.address(port))])]),
        ]

        do {
            try await connection.run(["replSetInitiate": .document(configuration)])
        } catch MongoDBError.command(_, _, Self.alreadyInitialized) {
            return
        }
    }

    // The port in the configuration of the set. It is nil when the folder has no set.
    public func replicaSetPort() async throws -> Int? {
        try await storedConfiguration().flatMap { $0["members"]?.array?.first?.document?["host"]?.string }.flatMap(Self.port)
    }

    // The server must run without --replSet, on a port that no program of the user knows. A clone
    // has the address of the main server, and that set cannot start on another port. A new id keeps
    // the two sets apart.
    public func moveReplicaSet(toPort port: Int, id: Data = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })) async throws {
        guard var configuration = try await storedConfiguration() else {
            return
        }

        guard let moved = Self.moved(configuration, toPort: port, id: id) else {
            throw MongoDBError.invalidAnswer
        }

        configuration = moved

        let answer = try await connection.run([
            "update": .string("system.replset"),
            "updates": .array([.document(["q": .document(["_id": configuration["_id"] ?? .string(Self.replicaSet)]), "u": .document(configuration)])]),
        ], on: "local")

        guard answer["n"]?.int64 == 1, answer["writeErrors"] == nil else {
            throw MongoDBError.invalidAnswer
        }
    }

    static func moved(_ configuration: BSONDocument, toPort port: Int, id: Data) -> BSONDocument? {
        guard let members = configuration["members"]?.array, members.count == 1, var member = members[0].document else {
            return nil
        }

        var moved = configuration
        var settings = configuration["settings"]?.document ?? [:]

        member["host"] = .string(address(port))
        settings["replicaSetId"] = .objectID(id)
        moved["members"] = .array([.document(member)])
        moved["settings"] = .document(settings)

        return moved
    }

    private func storedConfiguration() async throws -> BSONDocument? {
        let answer = try await connection.run(["find": .string("system.replset"), "limit": .int32(1)], on: "local")
        return answer["cursor"]?.document?["firstBatch"]?.array?.first?.document
    }

    static func address(_ port: Int) -> String {
        "127.0.0.1:\(port)"
    }

    static func port(ofAddress address: String) -> Int? {
        address.split(separator: ":").last.flatMap { Int($0) }
    }

    // MARK: The lock for a clone

    // The lock stays after the end of the connection. So the caller must unlock, also after a
    // failed clone. Each call adds one lock, and unlock removes one.
    public func lock() async throws {
        try await connection.run(["fsync": .int32(1), "lock": .bool(true)])
    }

    public func unlock() async throws {
        try await connection.run(["fsyncUnlock": .int32(1)])
    }

    // The number of locks of the server.
    public func lockCount() async throws -> Int {
        let answer = try await connection.run(["currentOp": .int32(1)])
        return answer["fsyncLock"]?.bool == true ? 1 : 0
    }

    // MARK: The account

    // A user of the database admin with the role root. An existing user gets the new password.
    public func setUser(_ account: DatabaseAccount) async throws {
        let password: BSONValue = .string(account.password)

        do {
            try await connection.run(["updateUser": .string(account.user), "pwd": password])
        } catch MongoDBError.command(_, _, Self.userNotFound) {
            try await connection.run(["createUser": .string(account.user), "pwd": password, "roles": .array([.string("root")])])
        }
    }

    public func dropUser(_ name: String) async throws {
        do {
            try await connection.run(["dropUser": .string(name)])
        } catch MongoDBError.command(_, _, Self.userNotFound) {
            return
        }
    }
}
