import Darwin
import Foundation
import NexusCore

// One connection to a MongoDB server on 127.0.0.1 or on a socket. A command and its answer use
// blocking calls on an own thread. So a server that gives no answer does not block a thread of the
// cooperative pool of Swift. The timeout ends each wait.
public actor MongoDBConnection {
    private let descriptor: Int32
    private var nextID: Int32 = 1
    private var isClosed = false
    // The actor can start a second command while the first one waits for its answer. Both would
    // then read from the same socket. So a command waits until the command before it ends.
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if !isClosed {
            close(descriptor)
        }
    }

    // A server without a password has no users, and it needs no login. The timeout is for each read
    // and for each write. The users of Nexus are in the database admin. A user of another server can
    // be in another database.
    public static func connect(port: Int, account: DatabaseAccount? = nil, authenticationDatabase: String = "admin", timeout: TimeInterval = 10) async throws -> MongoDBConnection {
        let descriptor = try await onOwnThread {
            try open(timeout: timeout, problem: "No server listens on port \(port).") { try IPv4Socket.connectToLoopback(port: port) }
        }

        return try await connected(descriptor, account: account, authenticationDatabase: authenticationDatabase)
    }

    // The socket of a server of a workspace (mongod --unixSocketPrefix).
    public static func connect(socket path: String, timeout: TimeInterval = 10) async throws -> MongoDBConnection {
        let descriptor = try await onOwnThread {
            try open(timeout: timeout, problem: "No server listens on \(path).") { try UnixSocket.connect(to: path) }
        }

        return try await connected(descriptor, account: nil, authenticationDatabase: "admin")
    }

    private static func connected(_ descriptor: Int32, account: DatabaseAccount?, authenticationDatabase: String) async throws -> MongoDBConnection {
        let connection = MongoDBConnection(descriptor: descriptor)

        if let account, !account.password.isEmpty {
            try await connection.logIn(account, on: authenticationDatabase)
        }

        return connection
    }

    @discardableResult
    public func run(_ command: BSONDocument, on database: String = "admin") async throws -> BSONDocument {
        await takeTurn()
        defer { endTurn() }

        guard !isClosed else {
            throw MongoDBError.connection("The connection is closed.")
        }

        let id = nextID
        nextID &+= 1

        var message = command
        message["$db"] = .string(database)

        let bytes = try MongoDBMessage.command(message, id: id)
        let descriptor = descriptor
        let answer: BSONDocument

        // After a failed or a late read the next answer could belong to this command. So the
        // connection closes.
        do {
            answer = try await Self.onOwnThread { try Self.exchange(bytes, id: id, descriptor: descriptor) }
        } catch {
            disconnect()
            throw error
        }

        guard answer["ok"]?.int64 == 1 else {
            throw MongoDBError.command(
                name: command.elements.first?.key ?? "",
                message: answer["errmsg"]?.string ?? "unknown",
                code: answer["code"]?.int64.map(Int.init) ?? 0
            )
        }

        return answer
    }

    public func disconnect() {
        guard !isClosed else {
            return
        }

        isClosed = true
        close(descriptor)
    }

    private func takeTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }

        await withCheckedContinuation { waiting.append($0) }
    }

    // The next command gets the turn at once, so isBusy stays true for it.
    private func endTurn() {
        guard !waiting.isEmpty else {
            isBusy = false
            return
        }

        waiting.removeFirst().resume()
    }

    private func logIn(_ account: DatabaseAccount, on database: String) async throws {
        let scram = ScramSHA256(user: account.user, password: account.password)

        do {
            let start = try await run([
                "saslStart": .int32(1),
                "mechanism": .string("SCRAM-SHA-256"),
                "payload": .binary(Data(scram.firstMessage.utf8)),
                "options": .document(["skipEmptyExchange": .bool(true)]),
            ], on: database)
            let answer = try scram.answer(to: try Self.payload(of: start))
            let end = try await run([
                "saslContinue": .int32(1),
                "conversationId": start["conversationId"] ?? .int32(1),
                "payload": .binary(Data(answer.message.utf8)),
            ], on: database)

            guard end["done"]?.bool == true, ScramSHA256.serverSignature(in: try Self.payload(of: end)) == answer.serverSignature else {
                throw MongoDBError.loginFailed
            }
        } catch MongoDBError.command {
            disconnect()
            throw MongoDBError.loginFailed
        } catch {
            disconnect()
            throw error
        }
    }

    private static func payload(of answer: BSONDocument) throws -> String {
        guard let data = answer["payload"]?.binary, let text = String(data: data, encoding: .utf8) else {
            throw MongoDBError.invalidAnswer
        }

        return text
    }

    private static func onOwnThread<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func open(timeout: TimeInterval, problem: String, _ connecting: () throws -> Int32) throws -> Int32 {
        let descriptor: Int32

        do {
            descriptor = try connecting()
        } catch {
            throw MongoDBError.connection(problem)
        }

        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        return descriptor
    }

    private static func exchange(_ bytes: Data, id: Int32, descriptor: Int32) throws -> BSONDocument {
        try send(bytes, to: descriptor)

        let header = try MongoDBMessage.header(try receive(MongoDBMessage.headerSize, from: descriptor))
        let body = try receive(header.size - MongoDBMessage.headerSize, from: descriptor)

        guard header.answerTo == id else {
            throw MongoDBError.invalidAnswer
        }

        do {
            return try MongoDBMessage.answer(body)
        } catch is BSONError {
            throw MongoDBError.invalidAnswer
        }
    }

    private static func send(_ bytes: Data, to descriptor: Int32) throws {
        var rest = Array(bytes)[...]

        while !rest.isEmpty {
            let count = rest.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }

            if count < 0, errno == EINTR {
                continue
            }

            guard count > 0 else {
                throw MongoDBError.connection(reason(errno))
            }

            rest = rest.dropFirst(count)
        }
    }

    private static func receive(_ count: Int, from descriptor: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var position = 0

        while position < count {
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress?.advanced(by: position), count - position, 0) }

            if received < 0, errno == EINTR {
                continue
            }

            guard received > 0 else {
                throw MongoDBError.connection(received == 0 ? "The server closed the connection." : reason(errno))
            }

            position += received
        }

        return Data(buffer)
    }

    private static func reason(_ code: Int32) -> String {
        code == EAGAIN || code == EWOULDBLOCK ? "The answer did not come in time." : "\(String(cString: strerror(code)))."
    }
}
