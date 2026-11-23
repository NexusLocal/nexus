import Darwin
import Foundation
import NexusCore
import Testing
@testable import NexusMongoDB

struct MongoDBServerTests {
    private let configuration: BSONDocument = [
        "_id": .string("nexus"),
        "version": .int32(1),
        "members": .array([.document(["_id": .int32(0), "host": .string("127.0.0.1:27017"), "votes": .int32(1)])]),
        "settings": .document(["heartbeatIntervalMillis": .int32(2000), "replicaSetId": .objectID(Data(1...12))]),
    ]

    @Test func aMovedSetHasTheNewPortAndANewIDAndKeepsTheRest() throws {
        let moved = try #require(MongoDBServer.moved(configuration, toPort: 42001, id: Data(repeating: 9, count: 12)))
        let member = try #require(moved["members"]?.array?.first?.document)

        #expect(member["host"] == .string("127.0.0.1:42001"))
        #expect(member["votes"] == .int32(1))
        #expect(moved["_id"] == .string("nexus"))
        #expect(moved["settings"]?.document?["replicaSetId"] == .objectID(Data(repeating: 9, count: 12)))
        #expect(moved["settings"]?.document?["heartbeatIntervalMillis"] == .int32(2000))
    }

    @Test func aSetWithMoreThanOneServerDoesNotMove() {
        var two = configuration
        two["members"] = .array([.document(["_id": .int32(0)]), .document(["_id": .int32(1)])])

        #expect(MongoDBServer.moved(two, toPort: 42001, id: Data()) == nil)
        #expect(MongoDBServer.moved(["_id": .string("nexus")], toPort: 42001, id: Data()) == nil)
    }

    @Test(arguments: [("127.0.0.1:27017", 27017), ("localhost", nil), ("", nil)] as [(String, Int?)])
    func thePortComesFromTheAddress(address: String, port: Int?) {
        #expect(MongoDBServer.port(ofAddress: address) == port)
    }

    @Test func theDatabasesComeWithoutTheSystemDatabases() async throws {
        let answer: BSONDocument = [
            "ok": .double(1),
            "databases": .array([
                .document(["name": .string("admin"), "sizeOnDisk": .int64(1)]),
                .document(["name": .string("shop"), "sizeOnDisk": .double(40960)]),
                .document(["name": .string("local"), "sizeOnDisk": .int32(1)]),
                .document(["name": .string("logs"), "sizeOnDisk": .int32(8192)]),
            ]),
        ]
        let fake = try FakeServer(answers: [answer])
        defer { fake.stop() }

        let server = MongoDBServer(try await MongoDBConnection.connect(port: fake.port, timeout: 5))

        #expect(try await server.databases() == [MongoDBDatabase(name: "shop", bytes: 40960), MongoDBDatabase(name: "logs", bytes: 8192)])
        #expect(fake.commands.map { $0.elements.first?.key } == ["listDatabases"])
        #expect(fake.commands.first?["$db"] == .string("admin"))
    }

    @Test func anErrorOfTheServerHasItsMessageAndItsCode() async throws {
        let fake = try FakeServer(answers: [["ok": .double(0), "errmsg": .string("not authorized"), "code": .int32(13)]])
        defer { fake.stop() }

        let connection = try await MongoDBConnection.connect(port: fake.port, timeout: 5)

        await #expect(throws: MongoDBError.command(name: "hello", message: "not authorized", code: 13)) {
            try await connection.run(["hello": .int32(1)])
        }
    }

    @Test func aSetThatExistsIsNoErrorOfItsStart() async throws {
        let fake = try FakeServer(answers: [["ok": .double(0), "errmsg": .string("already initialized"), "code": .int32(23)]])
        defer { fake.stop() }

        try await MongoDBServer(MongoDBConnection.connect(port: fake.port, timeout: 5)).initiateReplicaSet(port: 27017)

        #expect(fake.commands.first?["replSetInitiate"]?.document?["_id"] == .string("nexus"))
    }

    @Test func aUserThatDoesNotExistIsCreated() async throws {
        let fake = try FakeServer(answers: [
            ["ok": .double(0), "errmsg": .string("User root@admin not found"), "code": .int32(11)],
            ["ok": .double(1)],
        ])
        defer { fake.stop() }

        try await MongoDBServer(MongoDBConnection.connect(port: fake.port, timeout: 5)).setUser(DatabaseAccount(user: "root", password: "secret"))

        #expect(fake.commands.map { $0.elements.first?.key } == ["updateUser", "createUser"])
        #expect(fake.commands.last?["roles"] == .array([.string("root")]))
    }

    @Test func aServerThatClosesTheConnectionGivesAnError() async throws {
        let fake = try FakeServer(answers: [])
        defer { fake.stop() }

        let connection = try await MongoDBConnection.connect(port: fake.port, timeout: 5)

        await #expect(throws: MongoDBError.self) {
            try await connection.run(["hello": .int32(1)])
        }

        await #expect(throws: MongoDBError.connection("The connection is closed.")) {
            try await connection.run(["hello": .int32(1)])
        }
    }

    @Test func aServerThatGivesNoAnswerEndsWithTheTimeout() async throws {
        let fake = try FakeServer(answers: [], isSilent: true)
        defer { fake.stop() }

        let connection = try await MongoDBConnection.connect(port: fake.port, timeout: 0.3)

        await #expect(throws: MongoDBError.connection("The answer did not come in time.")) {
            try await connection.run(["hello": .int32(1)])
        }
    }

    @Test func aPortWithoutAServerGivesAnError() async throws {
        let fake = try FakeServer(answers: [])
        fake.stop()

        await #expect(throws: MongoDBError.connection("No server listens on port \(fake.port).")) {
            try await MongoDBConnection.connect(port: fake.port, timeout: 1)
        }
    }
}

struct MongoDBMessageTests {
    @Test func aCommandHasItsSizeItsIDAndItsDocument() throws {
        let document: BSONDocument = ["ping": .int32(1), "$db": .string("admin")]
        let bytes = try MongoDBMessage.command(document, id: 7)
        let header = try MongoDBMessage.header(bytes.prefix(16))

        #expect(header == MongoDBMessage.Header(size: bytes.count, id: 7, answerTo: 0, operation: 2013))
        #expect(try MongoDBMessage.answer(bytes.dropFirst(16)) == document)
    }

    @Test func aHeaderOfAnotherOperationOrSizeGivesAnError() {
        let header = { (size: Int32, operation: Int32) in
            BSON.littleEndian(size) + BSON.littleEndian(Int32(1)) + BSON.littleEndian(Int32(1)) + BSON.littleEndian(operation)
        }

        #expect(throws: MongoDBError.invalidAnswer) { try MongoDBMessage.header(header(100, 1)) }
        #expect(throws: MongoDBError.invalidAnswer) { try MongoDBMessage.header(header(16, 2013)) }
        #expect(throws: MongoDBError.invalidAnswer) { try MongoDBMessage.header(header(-5, 2013)) }
        #expect(throws: MongoDBError.invalidAnswer) { try MongoDBMessage.header(header(.max, 2013)) }
        #expect(throws: MongoDBError.invalidAnswer) { try MongoDBMessage.header(Data([1, 2, 3])) }
    }
}

// Accepts one connection and answers each command with the next answer. Without an answer it closes
// the connection, or it stays silent. Only the thread of the server closes the listener. A close in
// stop() can come before that thread calls accept, and another test can then get the same descriptor.
private final class FakeServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var received: [BSONDocument] = []
    private var client: Int32 = -1
    private var isStopped = false
    private var hasAccepted = false

    init(answers: [BSONDocument], isSilent: Bool = false) throws {
        let descriptor = try IPv4Socket.listener(on: 0, host: IPv4Socket.loopback, backlog: 1)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        withUnsafeMutablePointer(to: &address) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }

        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))

        Thread.detachNewThread { [self] in serve(answers, isSilent: isSilent) }
    }

    var commands: [BSONDocument] {
        lock.withLock { received }
    }

    // A server that has not accepted yet gets a connection of its own, so its accept returns.
    func stop() {
        let wakesServer = lock.withLock {
            guard !isStopped else {
                return false
            }

            isStopped = true

            if client >= 0 {
                shutdown(client, SHUT_RDWR)
            }

            return !hasAccepted
        }

        if wakesServer, let socket = try? IPv4Socket.connectToLoopback(port: port) {
            close(socket)
        }
    }

    private func serve(_ answers: [BSONDocument], isSilent: Bool) {
        var connection: Int32

        repeat {
            connection = accept(listener, nil, nil)
        } while connection < 0 && errno == EINTR

        close(listener)

        guard connection >= 0 else {
            return
        }

        let isStopped = lock.withLock {
            hasAccepted = true

            if !self.isStopped {
                client = connection
            }

            return self.isStopped
        }

        guard !isStopped else {
            close(connection)
            return
        }

        var rest = answers[...]

        while let header = read(16, from: connection), let parsed = try? MongoDBMessage.header(header), let body = read(parsed.size - 16, from: connection), let command = try? MongoDBMessage.answer(body) {
            lock.withLock { received.append(command) }

            guard let answer = rest.popFirst(), let document = try? BSON.encode(answer) else {
                if isSilent {
                    continue
                }

                break
            }

            let content = Data([0, 0, 0, 0, 0]) + document
            let message = BSON.littleEndian(Int32(16 + content.count)) + BSON.littleEndian(Int32(99)) + BSON.littleEndian(parsed.id) + BSON.littleEndian(Int32(2013)) + content
            _ = message.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        }

        lock.withLock { client = -1 }
        close(connection)
    }

    private func read(_ count: Int, from connection: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var position = 0

        while position < count {
            let received = buffer.withUnsafeMutableBytes { recv(connection, $0.baseAddress?.advanced(by: position), count - position, 0) }

            if received < 0, errno == EINTR {
                continue
            }

            guard received > 0 else {
                return nil
            }

            position += received
        }

        return Data(buffer)
    }
}
