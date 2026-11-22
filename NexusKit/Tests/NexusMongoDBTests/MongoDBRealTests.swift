import Foundation
import NexusCore
import Testing
@testable import NexusMongoDB

// The client with a real MongoDB server, only when NEXUS_REAL_MONGOD names a mongod. The servers listen
// on 127.0.0.1, and their data is in a temporary folder.
@Suite(.serialized)
struct MongoDBRealTests {
    private static let mongod = ProcessInfo.processInfo.environment["NEXUS_REAL_MONGOD"]
    private static let mainPort = 47_031
    private static let clonePort = 47_032
    private static let temporaryPort = 47_033

    private func start(_ folder: URL, port: Int, arguments: [String] = []) async throws -> Process {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(filePath: try #require(Self.mongod))
        process.arguments = [
            "--dbpath", folder.path(percentEncoded: false),
            "--port", String(port),
            "--bind_ip", "127.0.0.1",
            "--nounixsocket",
            "--wiredTigerCacheSizeGB", "0.25",
            "--logpath", folder.deletingLastPathComponent().appending(path: "\(port).log").path(percentEncoded: false),
            "--logappend",
        ] + arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        return process
    }

    private func stop(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()
        process.waitUntilExit()
    }

    private func connection(_ port: Int, account: DatabaseAccount? = nil) async throws -> MongoDBServer {
        let deadline = ContinuousClock.now + .seconds(30)

        while true {
            do {
                return MongoDBServer(try await MongoDBConnection.connect(port: port, account: account))
            } catch MongoDBError.connection where ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func waitForPrimary(_ server: MongoDBServer) async throws {
        let deadline = ContinuousClock.now + .seconds(30)

        while try await !server.isPrimary() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(.enabled(if: mongod != nil), .timeLimit(.minutes(2)))
    func aCloneOfAReplicaSetRunsOnItsOwnPortWithTheDataOfTheMainServer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus MongoDB \(UUID().uuidString)", directoryHint: .isDirectory)
        let mainFolder = root.appending(path: "main data", directoryHint: .isDirectory)
        let cloneFolder = root.appending(path: "clone data", directoryHint: .isDirectory)
        let set = ["--replSet", MongoDBServer.replicaSet]
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try await start(mainFolder, port: Self.mainPort, arguments: set)
        defer { stop(main) }
        let server = try await connection(Self.mainPort)
        try await server.initiateReplicaSet(port: Self.mainPort)
        try await server.initiateReplicaSet(port: Self.mainPort)
        try await waitForPrimary(server)
        try await server.connection.run(["insert": .string("items"), "documents": .array((0..<100).map { .document(["n": .int32($0)]) })], on: "shop")

        #expect(try await server.databases().map(\.name) == ["shop"])
        #expect(try await server.lockCount() == 0)

        try await server.lock()
        #expect(try await server.lockCount() == 1)
        try FileManager.default.copyItem(at: mainFolder, to: cloneFolder)
        try await server.unlock()

        #expect(try await server.lockCount() == 0)

        try FileManager.default.removeItem(at: cloneFolder.appending(path: "mongod.lock"))

        let standalone = try await start(cloneFolder, port: Self.temporaryPort)
        defer { stop(standalone) }
        let repair = try await connection(Self.temporaryPort)

        #expect(try await repair.replicaSetPort() == Self.mainPort)
        try await repair.moveReplicaSet(toPort: Self.clonePort)
        #expect(try await repair.replicaSetPort() == Self.clonePort)
        stop(standalone)

        let clone = try await start(cloneFolder, port: Self.clonePort, arguments: set)
        defer { stop(clone) }
        let copy = try await connection(Self.clonePort)
        try await waitForPrimary(copy)
        try await copy.connection.run(["insert": .string("items"), "documents": .array([.document(["n": .int32(-1)])])], on: "shop")

        #expect(try await copy.connection.run(["count": .string("items")], on: "shop")["n"]?.int64 == 101)
        #expect(try await server.connection.run(["count": .string("items")], on: "shop")["n"]?.int64 == 100)

        try await copy.dropDatabase("shop")

        #expect(try await copy.databases().isEmpty)
        #expect(try await server.databases().map(\.name) == ["shop"])
    }

    @Test(.enabled(if: mongod != nil), .timeLimit(.minutes(2)))
    func aServerWithAPasswordTakesOnlyTheRightPassword() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus MongoDB \(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "main data", directoryHint: .isDirectory)
        let keyFile = root.appending(path: "keyfile")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedData().write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path(percentEncoded: false))

        let set = ["--replSet", MongoDBServer.replicaSet]
        let open = try await start(folder, port: Self.mainPort, arguments: set)
        defer { stop(open) }
        let server = try await connection(Self.mainPort)
        try await server.initiateReplicaSet(port: Self.mainPort)
        try await waitForPrimary(server)
        try await server.setUser(DatabaseAccount(user: "root", password: "first"))
        try await server.setUser(DatabaseAccount(user: "root", password: "sécond, = password"))
        stop(open)

        let closed = try await start(folder, port: Self.mainPort, arguments: set + ["--keyFile", keyFile.path(percentEncoded: false)])
        defer { stop(closed) }
        let loggedIn = try await connection(Self.mainPort, account: DatabaseAccount(user: "root", password: "sécond, = password"))
        try await waitForPrimary(loggedIn)

        #expect(try await loggedIn.databases().isEmpty)

        await #expect(throws: MongoDBError.loginFailed) {
            try await MongoDBConnection.connect(port: Self.mainPort, account: DatabaseAccount(user: "root", password: "first"))
        }

        let withoutLogin = try await connection(Self.mainPort)

        await #expect(throws: MongoDBError.self) {
            try await withoutLogin.databases()
        }
    }
}
