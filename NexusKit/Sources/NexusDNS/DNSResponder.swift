import Foundation

// Answers DNS questions for the dev TLD. Every name in the TLD gets 127.0.0.1 for an A question
// and ::1 for an AAAA question. Other record types get an empty answer. A name outside the TLD
// gets REFUSED, because Nexus is not a general DNS server.
public struct DNSResponder: Sendable {
    enum ResponseCode: UInt8 {
        case noError = 0
        case formatError = 1
        case notImplemented = 4
        case refused = 5
    }

    enum RecordType: UInt16 {
        case a = 1
        case aaaa = 28
        case any = 255
    }

    static let headerLength = 12
    static let classInternet: UInt16 = 1
    static let classAny: UInt16 = 255
    static let maximumNameLength = 255

    public let tld: String
    public let ttl: UInt32

    public init(tld: String, ttl: UInt32 = 60) {
        self.tld = tld.lowercased()
        self.ttl = ttl
    }

    public func contains(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == tld || name.hasSuffix(".\(tld)")
    }

    // Returns nil for a packet that is not a query, so Nexus never answers an answer.
    public func response(to query: [UInt8]) -> [UInt8]? {
        guard query.count >= Self.headerLength else {
            return nil
        }

        let isResponse = query[2] & 0x80 != 0
        guard !isResponse else {
            return nil
        }

        let opcode = (query[2] >> 3) & 0x0F
        guard opcode == 0 else {
            return header(for: query, code: .notImplemented, authoritative: false, questions: 0, answers: 0)
        }

        guard UInt16(query[4]) << 8 | UInt16(query[5]) == 1, let question = Question(parsing: query) else {
            return header(for: query, code: .formatError, authoritative: false, questions: 0, answers: 0)
        }

        let isInternetClass = question.recordClass == Self.classInternet || question.recordClass == Self.classAny
        guard isInternetClass, contains(question.name) else {
            return header(for: query, code: .refused, authoritative: false, questions: 1, answers: 0) + question.bytes
        }

        let answers = records(for: question.recordType)
        return header(for: query, code: .noError, authoritative: true, questions: 1, answers: answers.count)
            + question.bytes
            + answers.flatMap { $0 }
    }

    private func records(for recordType: UInt16) -> [[UInt8]] {
        switch RecordType(rawValue: recordType) {
        case .a: [record(type: .a, address: [127, 0, 0, 1])]
        case .aaaa: [record(type: .aaaa, address: Array(repeating: 0, count: 15) + [1])]
        case .any: [record(type: .a, address: [127, 0, 0, 1]), record(type: .aaaa, address: Array(repeating: 0, count: 15) + [1])]
        case nil: []
        }
    }

    // The name of each answer is a pointer to the name in the question, which starts at byte 12.
    private func record(type: RecordType, address: [UInt8]) -> [UInt8] {
        [0xC0, 0x0C]
            + Self.bytes(type.rawValue)
            + Self.bytes(Self.classInternet)
            + Self.bytes(ttl)
            + Self.bytes(UInt16(address.count))
            + address
    }

    private func header(for query: [UInt8], code: ResponseCode, authoritative: Bool, questions: Int, answers: Int) -> [UInt8] {
        let opcodeAndRecursionDesired = query[2] & 0x79
        let flags = 0x80 | opcodeAndRecursionDesired | (authoritative ? 0x04 : 0)

        return [query[0], query[1], flags, code.rawValue]
            + Self.bytes(UInt16(questions))
            + Self.bytes(UInt16(answers))
            + [0, 0, 0, 0]
    }

    static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

extension DNSResponder {
    struct Question {
        let name: String
        let recordType: UInt16
        let recordClass: UInt16
        let bytes: [UInt8]

        // A query has no compressed names, so a pointer or an extended label type is a format
        // error here.
        init?(parsing packet: [UInt8]) {
            var offset = DNSResponder.headerLength
            var labels: [String] = []
            var nameLength = 0

            while true {
                guard offset < packet.count else {
                    return nil
                }

                let length = Int(packet[offset])
                offset += 1

                if length == 0 {
                    break
                }

                guard length & 0xC0 == 0, offset + length <= packet.count else {
                    return nil
                }

                nameLength += length + 1
                guard nameLength < DNSResponder.maximumNameLength else {
                    return nil
                }

                labels.append(String(decoding: packet[offset..<offset + length], as: UTF8.self))
                offset += length
            }

            guard offset + 4 <= packet.count else {
                return nil
            }

            name = labels.joined(separator: ".").lowercased()
            recordType = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
            recordClass = UInt16(packet[offset + 2]) << 8 | UInt16(packet[offset + 3])
            bytes = Array(packet[DNSResponder.headerLength..<offset + 4])
        }
    }
}
