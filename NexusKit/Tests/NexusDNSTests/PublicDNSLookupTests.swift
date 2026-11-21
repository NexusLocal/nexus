import Foundation
import NexusTestSupport
import Testing
@testable import NexusDNS

struct PublicDNSLookupTests {
    private static let id: UInt16 = 0x5F2B
    private static let question: [UInt8] = [4] + Array("calm".utf8) + [13] + Array("trycloudflare".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]

    private func answer(id: UInt16 = id, code: UInt8 = 0, records: [[UInt8]] = []) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF), 0x81, 0x80 | code, 0, 1, 0, UInt8(records.count), 0, 0, 0, 0] + Self.question + records.flatMap { $0 }
    }

    private func record(type: UInt16, data: [UInt8]) -> [UInt8] {
        [0xC0, 0x0C, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 1, 44, 0, UInt8(data.count)] + data
    }

    @Test func theQueryAsksOneQuestionOfTypeAWithRecursion() {
        let query = PublicDNSLookup.query(for: "calm.trycloudflare.com", id: Self.id)

        #expect(Array(query.prefix(12)) == [0x5F, 0x2B, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(Array(query.dropFirst(12)) == Self.question)
    }

    @Test func anARecordResolves() {
        #expect(PublicDNSLookup.resolves(answer: answer(records: [record(type: 1, data: [104, 16, 230, 132])]), id: Self.id) == true)
    }

    @Test func anAddressAfterACNAMEResolves() {
        let cname = record(type: 5, data: [3] + Array("cdn".utf8) + [0xC0, 0x0C])

        #expect(PublicDNSLookup.resolves(answer: answer(records: [cname, record(type: 1, data: [104, 16, 230, 132])]), id: Self.id) == true)
    }

    @Test func noSuchNameAndAnAnswerWithoutAnAddressDoNotResolve() {
        #expect(PublicDNSLookup.resolves(answer: answer(code: 3), id: Self.id) == false)
        #expect(PublicDNSLookup.resolves(answer: answer(), id: Self.id) == false)
        #expect(PublicDNSLookup.resolves(answer: answer(records: [record(type: 28, data: Array(repeating: 0, count: 16))]), id: Self.id) == false)
    }

    @Test func aRefusalAFailureAndAnotherIDGiveNoAnswer() {
        #expect(PublicDNSLookup.resolves(answer: answer(code: 5), id: Self.id) == nil)
        #expect(PublicDNSLookup.resolves(answer: answer(code: 2), id: Self.id) == nil)
        #expect(PublicDNSLookup.resolves(answer: answer(id: 0x1234, records: [record(type: 1, data: [1, 2, 3, 4])]), id: Self.id) == nil)
        #expect(PublicDNSLookup.resolves(answer: [0x5F, 0x2B], id: Self.id) == nil)
    }

    @Test func theQueryOfTheNameServersAsksForTypeNSWithRecursion() {
        let query = PublicDNSLookup.query(for: "example.com", type: 2, id: Self.id)

        #expect(Array(query.prefix(12)) == [0x5F, 0x2B, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(Array(query.dropFirst(12)) == [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 2, 0, 1])
    }

    @Test func twoNameServersWithACompressionPointerGiveBothNames() {
        let first = record(type: 2, data: [4] + Array("anna".utf8) + [2] + Array("ns".utf8) + [10] + Array("cloudflare".utf8) + [3] + Array("com".utf8) + [0])
        let pointerToNS = UInt8(12 + Self.question.count + 12 + 5)
        let second = record(type: 2, data: [3] + Array("bob".utf8) + [0xC0, pointerToNS])

        let names = PublicDNSLookup.nameservers(answer: answer(records: [first, second]), id: Self.id)

        #expect(names == ["anna.ns.cloudflare.com", "bob.ns.cloudflare.com"])
    }

    @Test func noSuchNameGivesNoNameServersAndAFailureGivesNoAnswer() {
        #expect(PublicDNSLookup.nameservers(answer: answer(code: 3), id: Self.id) == [])
        #expect(PublicDNSLookup.nameservers(answer: answer(), id: Self.id) == [])
        #expect(PublicDNSLookup.nameservers(answer: answer(code: 5), id: Self.id) == nil)
        #expect(PublicDNSLookup.nameservers(answer: answer(id: 0x1234, records: [record(type: 2, data: [0])]), id: Self.id) == nil)
    }

    @Test func aPointerOutOfThePacketAndAPointerLoopGiveNoAnswer() {
        let outside = record(type: 2, data: [3] + Array("bob".utf8) + [0xC0, 0xFF])
        let loopStart = UInt8(12 + Self.question.count + 12)
        let loop = record(type: 2, data: [0xC0, loopStart])

        #expect(PublicDNSLookup.nameservers(answer: answer(records: [outside]), id: Self.id) == nil)
        #expect(PublicDNSLookup.nameservers(answer: answer(records: [loop]), id: Self.id) == nil)
    }

    @Test func aLocalServerAnswersForItsTLDAndRefusesTheOtherNames() async throws {
        let server = DNSServer(responder: DNSResponder(tld: "internal"))
        let port = try startOnFreePort(server)
        defer { server.stop() }

        let inside = await PublicDNSLookup.resolves("shop.internal", server: "127.0.0.1", port: port)
        let outside = await PublicDNSLookup.resolves("calm.trycloudflare.com", server: "127.0.0.1", port: port)

        #expect(inside == true)
        #expect(outside == nil)
    }

    @Test func aPortWithoutAServerGivesNoAnswerWithinTheTimeLimit() async {
        let start = ContinuousClock.now

        let answer = await PublicDNSLookup.resolves("shop.internal", server: "127.0.0.1", port: freeUDPPort(), timeout: .milliseconds(500))

        #expect(answer == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
