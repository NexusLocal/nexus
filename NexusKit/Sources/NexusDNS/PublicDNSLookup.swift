import Darwin
import Foundation

// Asks 1.1.1.1 for the address of a host (group 4, 4b). nexusd never asks the resolver of macOS
// before a link opens, because that resolver keeps a miss for a minute. resolves gives true for an
// answer with an A record. It gives false for NXDOMAIN or for an answer without an address. It gives
// nil without an answer, for example in a network that blocks DNS to 1.1.1.1.
public enum PublicDNSLookup {
    public static let server = "1.1.1.1"

    private static let typeA: UInt16 = 1
    private static let typeNS: UInt16 = 2
    private static let classInternet: UInt16 = 1
    private static let headerLength = 12
    private static let pointerLimit = 10

    public static func resolves(_ host: String, server: String = server, port: Int = 53, timeout: Duration = .seconds(2)) async -> Bool? {
        await ask(host, type: typeA, server: server, port: port, timeout: timeout) { answer, id in
            resolves(answer: answer, id: id)
        }
    }

    // The name servers of a domain at 1.1.1.1 without the dot at the end (group 4, 4h). [] for
    // NXDOMAIN or for an answer without an NS record. nil without an answer.
    public static func nameservers(of domain: String, server: String = server, port: Int = 53, timeout: Duration = .seconds(2)) async -> [String]? {
        await ask(domain, type: typeNS, server: server, port: port, timeout: timeout) { answer, id in
            nameservers(answer: answer, id: id)
        }
    }

    // One question of type A and class IN with the flag RD.
    static func query(for host: String, id: UInt16) -> [UInt8] {
        query(for: host, type: typeA, id: id)
    }

    // One question of a type and class IN with the flag RD.
    static func query(for name: String, type: UInt16, id: UInt16) -> [UInt8] {
        let header: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let labels = name.split(separator: ".").flatMap { label -> [UInt8] in
            let bytes = Array(label.utf8.prefix(63))
            return [UInt8(bytes.count)] + bytes
        }

        return header + labels + [0x00, UInt8(type >> 8), UInt8(type & 0xFF), UInt8(classInternet >> 8), UInt8(classInternet & 0xFF)]
    }

    // REFUSED, SERVFAIL, a packet that is not an answer and an answer with another id give nil.
    static func resolves(answer: [UInt8], id: UInt16) -> Bool? {
        switch code(of: answer, id: id) {
        case 0?:
            hasAddress(in: answer)
        case 3?:
            false
        default:
            nil
        }
    }

    // The names of the NS records of an answer. A name that leaves the packet gives nil.
    static func nameservers(answer: [UInt8], id: UInt16) -> [String]? {
        switch code(of: answer, id: id) {
        case 0?:
            break
        case 3?:
            return []
        default:
            return nil
        }

        var names: [String] = []

        for record in records(in: answer) ?? [] where record.type == typeNS {
            guard let name = name(in: answer, from: record.data) else {
                return nil
            }

            names.append(name)
        }

        return names
    }

    private static func code(of answer: [UInt8], id: UInt16) -> UInt8? {
        guard answer.count >= headerLength, UInt16(answer[0]) << 8 | UInt16(answer[1]) == id, answer[2] & 0x80 != 0 else {
            return nil
        }

        return answer[3] & 0x0F
    }

    private enum Outcome<Value> {
        case answer(Value?)
        case timedOut
        case failed
    }

    // The socket blocks for up to the time limit. So the lookup runs on a thread of its own. No
    // thread of Swift concurrency waits for it. One more try follows a time out.
    private static func ask<Value: Sendable>(_ name: String, type: UInt16, server: String, port: Int, timeout: Duration, parse: @escaping @Sendable ([UInt8], UInt16) -> Value?) async -> Value? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                for _ in 0..<2 {
                    switch askOnce(name, type: type, server: server, port: port, timeout: timeout, parse: parse) {
                    case .answer(let value):
                        continuation.resume(returning: value)
                        return
                    case .timedOut:
                        continue
                    case .failed:
                        continuation.resume(returning: nil)
                        return
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private static func askOnce<Value>(_ name: String, type: UInt16, server: String, port: Int, timeout: Duration, parse: ([UInt8], UInt16) -> Value?) -> Outcome<Value> {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)

        guard inet_pton(AF_INET, server, &address.sin_addr) == 1 else {
            return .failed
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)

        guard descriptor >= 0 else {
            return .failed
        }

        defer { close(descriptor) }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        guard connected == 0 else {
            return .failed
        }

        let id = UInt16.random(in: 0...UInt16.max)
        let packet = query(for: name, type: type, id: id)

        guard send(descriptor, packet, packet.count, 0) == packet.count else {
            return .failed
        }

        let deadline = ContinuousClock.now + timeout
        let capacity = 1_500
        var buffer = [UInt8](repeating: 0, count: capacity)

        // A late answer to an earlier question has another id. The wait then goes on. A time limit
        // of 0 would wait without an end. So the limit is at least 1 millisecond.
        while ContinuousClock.now < deadline {
            let left = max(deadline - ContinuousClock.now, .milliseconds(1))
            var limit = timeval(tv_sec: Int(left.components.seconds), tv_usec: Int32(left.components.attoseconds / 1_000_000_000_000))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

            let count = recv(descriptor, &buffer, capacity, 0)

            if count < 0 {
                return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .failed
            }

            let answer = Array(buffer.prefix(count))

            guard answer.count >= 2, UInt16(answer[0]) << 8 | UInt16(answer[1]) == id else {
                continue
            }

            return .answer(parse(answer, id))
        }

        return .timedOut
    }

    private static func hasAddress(in answer: [UInt8]) -> Bool {
        records(in: answer)?.contains { $0.type == typeA && $0.length == 4 } ?? false
    }

    // The question comes first. Then each answer has a name, a type, a class, a time to live and its
    // data. A name in an answer is a pointer or a list of labels. nil for a packet that ends too
    // early. data is the offset of the data of a record.
    private static func records(in answer: [UInt8]) -> [(type: UInt16, data: Int, length: Int)]? {
        let questions = Int(answer[4]) << 8 | Int(answer[5])
        let answers = Int(answer[6]) << 8 | Int(answer[7])
        var offset = headerLength
        var records: [(type: UInt16, data: Int, length: Int)] = []

        for _ in 0..<questions {
            guard let end = endOfName(in: answer, from: offset), end + 4 <= answer.count else {
                return nil
            }

            offset = end + 4
        }

        for _ in 0..<answers {
            guard let end = endOfName(in: answer, from: offset), end + 10 <= answer.count else {
                return records
            }

            let type = UInt16(answer[end]) << 8 | UInt16(answer[end + 1])
            let length = Int(answer[end + 8]) << 8 | Int(answer[end + 9])
            records.append((type, end + 10, length))
            offset = end + 10 + length
        }

        return records
    }

    private static func endOfName(in packet: [UInt8], from start: Int) -> Int? {
        var offset = start

        while offset < packet.count {
            let length = Int(packet[offset])

            if length == 0 {
                return offset + 1
            }

            if length & 0xC0 == 0xC0 {
                return offset + 2 <= packet.count ? offset + 2 : nil
            }

            offset += 1 + length
        }

        return nil
    }

    // The labels of a name with the dots between them. The reader follows a compression pointer at
    // most pointerLimit times. A name that leaves the packet gives nil.
    private static func name(in packet: [UInt8], from start: Int) -> String? {
        var labels: [String] = []
        var offset = start
        var jumps = 0

        while offset < packet.count {
            let length = Int(packet[offset])

            if length == 0 {
                return labels.joined(separator: ".")
            }

            if length & 0xC0 == 0xC0 {
                guard offset + 1 < packet.count, jumps < pointerLimit else {
                    return nil
                }

                jumps += 1
                offset = (length & 0x3F) << 8 | Int(packet[offset + 1])
                continue
            }

            guard offset + 1 + length <= packet.count else {
                return nil
            }

            labels.append(String(decoding: packet[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }

        return nil
    }
}
