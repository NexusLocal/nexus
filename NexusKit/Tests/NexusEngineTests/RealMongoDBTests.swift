import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusMongoDB
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

// The engine with a real MongoDB, only when NEXUS_REAL_MONGOD names a mongod and
// NEXUS_REAL_MONGODB_TOOLS names a folder of the MongoDB Database Tools, for example:
// NEXUS_REAL_MONGOD=/path/8.0.38/bin/mongod NEXUS_REAL_MONGODB_TOOLS=/path/tools swift test --filter RealMongoDB
// The instance is new and lives in a temporary folder.
extension NexusEngineTests {
    static let realMongod = ProcessInfo.processInfo.environment["NEXUS_REAL_MONGOD"]
    static let realMongoDBTools = ProcessInfo.processInfo.environment["NEXUS_REAL_MONGODB_TOOLS"]

    @Test(.enabled(if: realMongod != nil && realMongoDBTools != nil), .timeLimit(.minutes(5)))
    func aRealMongoDBStartsAsAReplicaSetImportsCopiesChangesItsAccountAndMovesToANewPort() async throws {
        let id = "mongodb-8.0"
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        try installLinked("mongodb", line: "8.0", bin: URL(filePath: try #require(Self.realMongod)).deletingLastPathComponent(), paths: paths)
        try installLinked(MongoDBToolsPackage.name, line: MongoDBToolsPackage.line, bin: URL(filePath: try #require(Self.realMongoDBTools)).appending(path: "bin"), paths: paths)

        var state = EngineState()
        state.ports[id] = freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )

        try await whileRunning(engine) {
            let tools = try #require(await engine.databaseRuntime(id))
            let port = try await engine.port(of: tools)

            let started = await engine.handle(.start(service: id))
            let before = await engine.handle(.databaseSizes(instance: id))

            let writer = try await MongoDBConnection.connect(port: port)
            let rows: [BSONValue] = (1...50).map { .document(["n": .int32(Int32($0))]) }
            try await writer.run(["insert": .string("orders"), "documents": .array(rows)], on: "shop")
            let primary = try await MongoDBServer(writer).isPrimary()
            await writer.disconnect()

            let archive = root.appending(path: "shop.archive.gz")
            _ = try await CommandRunner.run(Command(executable: tools.dump, arguments: ["--uri=mongodb://127.0.0.1:\(port)/", "--db=shop", "--archive=\(archive.path(percentEncoded: false))", "--gzip", "--quiet"]))

            let inspected = await engine.handle(.inspectDump(DumpInspection(file: archive.path(percentEncoded: false), target: .instance(id), name: "shop")))
            let imported = await engine.handle(.importDump(DumpImport(file: archive.path(percentEncoded: false), target: .instance(id), name: "imported")))
            let refused = await engine.handle(.importDump(DumpImport(file: archive.path(percentEncoded: false), target: .instance(id), name: "imported")))
            let replaced = await engine.handle(.importDump(DumpImport(file: archive.path(percentEncoded: false), target: .instance(id), name: "imported", existing: .replaceDatabase)))
            let trash = (try? FileManager.default.contentsOfDirectory(atPath: paths.trash.path(percentEncoded: false))) ?? []
            let copied = await engine.handle(.copyDatabase(DatabaseCopy(source: DatabaseServer(port: port, account: DatabaseAccount(user: "", password: ""), url: "mongodb://127.0.0.1:\(port)/shop"), database: "shop", instance: id, name: "copied")))
            let missingSource = DatabaseServer(port: port, account: DatabaseAccount(user: "", password: ""), url: "mongodb://127.0.0.1:\(port)")
            let refusedCopy = await engine.handle(.copyDatabase(DatabaseCopy(source: missingSource, database: "missing", instance: id, name: "copied", replace: true)))
            let after = await engine.handle(.databaseSizes(instance: id))

            let account = DatabaseAccount(user: "nexus", password: "s3cret\"pw")
            let changed = await engine.handle(.setAccount(instance: id, account: account))
            let keyFile = MongoDBConfig.keyFile(in: paths.dataFolder(service: "mongodb", line: "8.0")).path(percentEncoded: false)
            let hasKeyFile = FileManager.default.fileExists(atPath: keyFile)
            let withPassword = await engine.handle(.databaseSizes(instance: id))
            let anonymous = try await MongoDBConnection.connect(port: port)
            let refusedWithoutLogin = (try? await MongoDBServer(anonymous).databases()) == nil
            await anonymous.disconnect()

            let newPort = freePort()
            _ = await engine.handle(.stop(service: id))
            let moved = await engine.handle(.setPort(service: id, port: newPort))
            let startedAgain = await engine.handle(.start(service: id))
            let mover = try await MongoDBConnection.connect(port: newPort, account: account)
            let primaryOnNewPort = try await MongoDBServer(mover).isPrimary()
            let setPort = try await MongoDBServer(mover).replicaSetPort()
            await mover.disconnect()

            let changedBack = await engine.handle(.setAccount(instance: id, account: .newInstance))
            let open = try await MongoDBConnection.connect(port: newPort)
            let worksWithoutLogin = try await MongoDBServer(open).databases().map(\.name)
            await open.disconnect()

            if case .done = started {} else { Issue.record("the start failed: \(started)") }
            #expect(before == .databaseSizes([]))
            #expect(primary)

            guard case .dumpInfo(let info) = inspected else {
                Issue.record("no dump info: \(inspected)")
                return
            }
            #expect(info.format == .mongodb)
            #expect(info.dumps == ["shop"])
            #expect(info.dump == "shop")
            #expect(info.tables == ["orders"])
            #expect(info.existingTables == ["orders"])

            if case .done = imported {} else { Issue.record("the import failed: \(imported)") }
            if case .failure = refused {} else { Issue.record("the second import did not stop: \(refused)") }
            if case .done = replaced {} else { Issue.record("the replace failed: \(replaced)") }
            #expect(trash.contains { $0.hasSuffix("-\(id)-imported.archive.gz") })
            if case .done = copied {} else { Issue.record("the copy failed: \(copied)") }
            if case .failure = refusedCopy {} else { Issue.record("a copy of a missing database did not stop: \(refusedCopy)") }

            guard case .databaseSizes(let sizes) = after else {
                Issue.record("no sizes: \(after)")
                return
            }
            #expect(sizes.map(\.name).sorted() == ["copied", "imported", "shop"])

            if case .done = changed {} else { Issue.record("the account did not change: \(changed)") }
            guard case .databaseSizes(let sizesWithPassword) = withPassword else {
                Issue.record("no sizes with the password: \(withPassword)")
                return
            }
            #expect(sizesWithPassword.count == 3)
            #expect(refusedWithoutLogin)
            #expect(hasKeyFile)

            if case .done = moved {} else { Issue.record("the port did not change: \(moved)") }
            if case .done = startedAgain {} else { Issue.record("the start on the new port failed: \(startedAgain)") }
            #expect(primaryOnNewPort)
            #expect(setPort == newPort)

            if case .done = changedBack {} else { Issue.record("the account did not change back: \(changedBack)") }
            #expect(worksWithoutLogin.sorted() == ["copied", "imported", "shop"])
            #expect(!FileManager.default.fileExists(atPath: keyFile))
            #expect(await engine.stateStore.current().databaseAccounts[id] == .newInstance)
        }
    }

    @Test(.enabled(if: realMongod != nil && realMongoDBTools != nil), .timeLimit(.minutes(2)))
    func aNewRealMongoDBWithAPasswordMakesItsUserAtItsFirstStart() async throws {
        let id = "mongodb-8.0"
        let account = DatabaseAccount(user: "admin", password: "first pw")
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        try installLinked("mongodb", line: "8.0", bin: URL(filePath: try #require(Self.realMongod)).deletingLastPathComponent(), paths: paths)

        var state = EngineState()
        state.ports[id] = freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        state.newInstanceAccount = account
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )

        try await whileRunning(engine) {
            let port = try await engine.port(of: try #require(await engine.databaseRuntime(id)))
            let started = await engine.handle(.start(service: id))

            let anonymous = try await MongoDBConnection.connect(port: port)
            let refusedWithoutLogin = (try? await MongoDBServer(anonymous).databases()) == nil
            await anonymous.disconnect()

            let user = try await MongoDBConnection.connect(port: port, account: account)
            let primary = try await MongoDBServer(user).isPrimary()
            await user.disconnect()

            let restarted = await engine.handle(.restart(service: id))

            if case .done = started {} else { Issue.record("the start failed: \(started)") }
            #expect(refusedWithoutLogin)
            #expect(primary)
            if case .done = restarted {} else { Issue.record("the restart failed: \(restarted)") }
            #expect(await engine.stateStore.current().databaseAccounts[id] == account)
        }
    }

    // A runtime folder with the metadata of an install and a link to a real bin folder.
    func installLinked(_ name: String, line: String, bin: URL, paths: NexusPaths) throws {
        let folder = paths.runtime(name, line: line)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "bin"), withDestinationURL: bin)

        let runtime = InstalledRuntime(name: name, line: line, version: line, revision: 1, sha256: "test", installedAt: .now, folder: folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(runtime).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
    }
}
