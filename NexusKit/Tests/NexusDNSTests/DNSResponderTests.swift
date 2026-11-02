import Testing
@testable import NexusDNS

struct DNSResponderTests {
    private let responder = DNSResponder(tld: "test", ttl: 60)

    private func query(_ name: String, type: UInt16, id: UInt16 = 0x1234, recursionDesired: Bool = true) -> [UInt8] {
        var packet: [UInt8] = DNSResponder.bytes(id) + [recursionDesired ? 0x01 : 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

        for label in name.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: Array(label.utf8))
        }

        packet.append(0)
        return packet + DNSResponder.bytes(type) + DNSResponder.bytes(UInt16(1))
    }

    private func code(of response: [UInt8]) -> UInt8 {
        response[3] & 0x0F
    }

    private func answerCount(of response: [UInt8]) -> Int {
        Int(response[6]) << 8 | Int(response[7])
    }

    @Test func aQuestionInTheTLDGetsTheIPv4LoopbackAddress() throws {
        let question = query("shop.test", type: 1)

        let response = try #require(responder.response(to: question))

        #expect(Array(response.prefix(2)) == [0x12, 0x34])
        #expect(response[2] & 0x80 != 0)
        #expect(response[2] & 0x04 != 0)
        #expect(response[2] & 0x01 != 0)
        #expect(code(of: response) == 0)
        #expect(answerCount(of: response) == 1)
        #expect(Array(response.suffix(4)) == [127, 0, 0, 1])
    }

    @Test func aaaaQuestionGetsTheIPv6LoopbackAddress() throws {
        let response = try #require(responder.response(to: query("api.shop.test", type: 28)))

        #expect(answerCount(of: response) == 1)
        #expect(Array(response.suffix(16)) == Array(repeating: 0, count: 15) + [1])
    }

    @Test func theAnswerUsesTheTimeToLive() throws {
        let question = query("shop.test", type: 1)

        let response = try #require(DNSResponder(tld: "test", ttl: 300).response(to: question))

        let answer = Array(response.dropFirst(question.count))
        #expect(Array(answer[6..<10]) == [0, 0, 1, 44])
    }

    @Test func otherRecordTypesGetAnEmptyAnswer() throws {
        let response = try #require(responder.response(to: query("shop.test", type: 65)))

        #expect(code(of: response) == 0)
        #expect(answerCount(of: response) == 0)
    }

    @Test func namesMatchWithoutCase() throws {
        let response = try #require(responder.response(to: query("Shop.TEST", type: 1)))

        #expect(answerCount(of: response) == 1)
    }

    @Test func aNameOutsideTheTLDIsRefused() throws {
        let response = try #require(responder.response(to: query("example.com", type: 1)))

        #expect(code(of: response) == 5)
        #expect(answerCount(of: response) == 0)
    }

    @Test func aNameThatOnlyEndsWithTheLettersOfTheTLDIsRefused() throws {
        let response = try #require(responder.response(to: query("latest", type: 1)))

        #expect(code(of: response) == 5)
    }

    @Test func aCompressedNameInTheQuestionIsAFormatError() throws {
        let packet: [UInt8] = [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]

        let response = try #require(responder.response(to: packet))

        #expect(code(of: response) == 1)
    }

    @Test func aTruncatedQuestionIsAFormatError() throws {
        let packet = Array(query("shop.test", type: 1).dropLast(3))

        let response = try #require(responder.response(to: packet))

        #expect(code(of: response) == 1)
    }

    @Test func aResponseOrAShortPacketGetsNoAnswer() {
        var answer = query("shop.test", type: 1)
        answer[2] |= 0x80

        #expect(responder.response(to: answer) == nil)
        #expect(responder.response(to: [0x00, 0x01]) == nil)
    }

    @Test func anotherOpcodeIsNotImplemented() throws {
        var update = query("shop.test", type: 1)
        update[2] = 5 << 3

        let response = try #require(responder.response(to: update))

        #expect(code(of: response) == 4)
    }
}
