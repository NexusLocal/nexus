import Foundation
import NexusCore

// A small client of the Redis protocol (RESP) for the move from Herd. It copies the keys of a Redis
// or Valkey on this Mac into the Redis of Nexus with DUMP and RESTORE. Each call blocks, so callers
// run it on a thread of their own.
final class RedisWire {
    enum Reply: Equatable {
        case status(String)
        case error(String)
        case integer(Int)
        case bulk(Data?)
        case array([Reply]?)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let socket: LineSocket

    init(port: Int, password: String? = nil, timeout: TimeInterval = 10) throws {
        socket = try LineSocket.connect(port: port, timeout: timeout)

        if let password, !password.isEmpty {
            try check(command(["AUTH", password]))
        }
    }

    deinit {
        socket.close()
    }

    func command(_ arguments: [String]) throws -> Reply {
        try command(arguments.map { Data($0.utf8) })
    }

    func command(_ arguments: [Data]) throws -> Reply {
        var request = Data("*\(arguments.count)\r\n".utf8)

        for argument in arguments {
            request.append(Data("$\(argument.count)\r\n".utf8))
            request.append(argument)
            request.append(Data("\r\n".utf8))
        }

        try socket.write(request)
        return try readReply()
    }

    @discardableResult
    func check(_ reply: Reply) throws -> Reply {
        if case .error(let message) = reply {
            throw Failure(description: message)
        }

        return reply
    }

    private func readReply() throws -> Reply {
        guard let line = try socket.readLine(), let kind = line.first else {
            throw Failure(description: "The server closed the connection.")
        }

        let text = String(decoding: line.dropFirst(), as: UTF8.self)

        switch kind {
        case UInt8(ascii: "+"):
            return .status(text)
        case UInt8(ascii: "-"):
            return .error(text)
        case UInt8(ascii: ":"):
            return .integer(Int(text) ?? 0)
        case UInt8(ascii: "$"):
            guard let count = Int(text), count >= 0 else {
                return .bulk(nil)
            }

            let data = try socket.read(count: count) ?? Data()
            _ = try socket.read(count: 2)
            return .bulk(data)
        case UInt8(ascii: "*"):
            guard let count = Int(text), count >= 0 else {
                return .array(nil)
            }

            return .array(try (0..<count).map { _ in try readReply() })
        default:
            throw Failure(description: "The server sent an answer that Nexus cannot read.")
        }
    }

    // The databases with keys, from "INFO keyspace", for example [0: 3, 1: 12].
    func keyspace() throws -> [Int: Int] {
        guard case .bulk(let data?) = try check(command(["INFO", "keyspace"])) else {
            return [:]
        }

        var result: [Int: Int] = [:]

        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let match = line.firstMatch(of: #/^db(\d+):keys=(\d+)/#), let database = Int(match.1), let keys = Int(match.2) else {
                continue
            }

            result[database] = keys
        }

        return result
    }

    func keys(in database: Int) throws -> [Data] {
        try check(command(["SELECT", String(database)]))
        var cursor = "0"
        var keys: [Data] = []

        repeat {
            guard case .array(let parts?) = try check(command(["SCAN", cursor, "COUNT", "500"])), parts.count == 2,
                  case .bulk(let next?) = parts[0], case .array(let list?) = parts[1] else {
                throw Failure(description: "The server sent an answer to SCAN that Nexus cannot read.")
            }

            cursor = String(decoding: next, as: UTF8.self)
            keys += list.compactMap { if case .bulk(let key?) = $0 { key } else { nil } }
        } while cursor != "0"

        return keys
    }

    // The value and the time to live of a key, or nil when the key is gone.
    func dump(_ key: Data) throws -> (payload: Data, ttl: Int)? {
        guard case .bulk(let payload?) = try check(command([Data("DUMP".utf8), key])) else {
            return nil
        }

        guard case .integer(let ttl) = try check(command([Data("PTTL".utf8), key])), ttl != -2 else {
            return nil
        }

        return (payload, max(ttl, 0))
    }

    func restore(_ key: Data, payload: Data, ttl: Int, in database: Int) throws {
        try check(command(["SELECT", String(database)]))
        try check(command([Data("RESTORE".utf8), key, Data(String(ttl).utf8), payload, Data("REPLACE".utf8)]))
    }

    // Copies each key of each database. Returns the number of keys and the problems.
    static func copyKeys(from source: RedisWire, to target: RedisWire) throws -> (copied: Int, problems: [String]) {
        var copied = 0
        var problems: [String] = []

        for database in try source.keyspace().keys.sorted() {
            for key in try source.keys(in: database) {
                guard let value = try source.dump(key) else {
                    continue
                }

                do {
                    try target.restore(key, payload: value.payload, ttl: value.ttl, in: database)
                    copied += 1
                } catch {
                    if problems.count < 5 {
                        problems.append("\(String(decoding: key, as: UTF8.self)): \(error)")
                    }
                }
            }
        }

        return (copied, problems)
    }
}
