import Foundation
import Testing
@testable import NexusSupervisor

struct PortRefusalTests {
    @Test func theMySQLErrorPacketHasTheCodeOfTheServerAndNoStateMarker() {
        let packet = PortRefusal.mysqlErrorPacket("Stopped.")

        #expect([UInt8](packet) == [0x0B, 0x00, 0x00, 0x00, 0xFF, 0x1D, 0x04] + Array("Stopped.".utf8))
    }

    @Test func thePostgreSQLErrorResponseIsFatalWithTheStateCannotConnectNow() {
        let response = PortRefusal.postgreSQLErrorResponse("Stopped.")
        let fields = Array("SFATAL\0VFATAL\0C57P03\0MStopped.\0\0".utf8)

        #expect([UInt8](response) == Array("E".utf8) + [0x00, 0x00, 0x00, 36] + fields)
    }

    @Test func aLongTextEndsAtTheLimitInBothForms() {
        let text = String(repeating: "a", count: 500)

        #expect(PortRefusal.mysqlErrorPacket(text).count == 4 + 3 + 400)
        #expect(PortRefusal.postgreSQLErrorResponse(text).count == 1 + 4 + 21 + 1 + 400 + 1 + 1)
    }

    @Test func aTextEndsAtAWholeCharacter() {
        let text = String(repeating: "a", count: 399) + "é" + "b"

        let packet = PortRefusal.mysqlErrorPacket(text)

        #expect(packet.count == 4 + 3 + 399)
        #expect(String(data: packet.dropFirst(7), encoding: .utf8) == String(repeating: "a", count: 399))
    }

    static let starts: [([UInt8], PortRefusal.PostgreSQLStart)] = [
        ([0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F], .sslRequest),
        ([0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x30], .encryptionRequest),
        ([0, 0, 0, 16, 0x04, 0xD2, 0x16, 0x2E], .cancelRequest(length: 16)),
        ([0, 0, 0, 84, 0x00, 0x03, 0x00, 0x00], .startup(length: 84)),
        ([0, 0, 0x27, 0x11, 0x00, 0x03, 0x00, 0x00], .tooLong),
        ([0, 0, 0, 4, 0x00, 0x03, 0x00, 0x00], .tooLong),
        ([0, 0, 0, 8], .tooLong),
    ]

    @Test(arguments: starts)
    func theFirstBytesOfAPostgreSQLClientGiveItsMessage(_ head: [UInt8], _ start: PortRefusal.PostgreSQLStart) {
        #expect(PortRefusal.postgreSQLStart(Data(head)) == start)
    }

    static func mongoDBHeader(length: Int32, id: Int32, operation: Int32) -> [UInt8] {
        [length, id, 0, operation].flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
    }

    static let mongoDBStarts: [([UInt8], PortRefusal.MongoDBStart)] = [
        (mongoDBHeader(length: 120, id: 7, operation: 2013), .message(id: 7, length: 120)),
        (mongoDBHeader(length: 250, id: 1, operation: 2004), .query(id: 1, length: 250)),
        (mongoDBHeader(length: 120, id: 7, operation: 2012), .other),
        (mongoDBHeader(length: 16, id: 7, operation: 2013), .other),
        (mongoDBHeader(length: 20_000, id: 7, operation: 2013), .other),
        (Array(mongoDBHeader(length: 120, id: 7, operation: 2013).prefix(12)), .other),
    ]

    @Test(arguments: mongoDBStarts)
    func theHeaderOfAMongoDBClientGivesItsMessage(_ head: [UInt8], _ start: PortRefusal.MongoDBStart) {
        #expect(PortRefusal.mongoDBStart(Data(head)) == start)
    }

    @Test func theMongoDBErrorDocumentHasOkZeroAndTheText() {
        let document = [UInt8](PortRefusal.mongoDBErrorDocument("Stopped."))
        let ok: [UInt8] = [0x01] + Array("ok\0".utf8) + Array(repeating: 0, count: 8)
        let errmsg: [UInt8] = [0x02] + Array("errmsg\0".utf8) + [9, 0, 0, 0] + Array("Stopped.\0".utf8)

        #expect(document == [38, 0, 0, 0] + ok + errmsg + [0])
    }

    @Test func anOPMSGGetsAnOPMSGThatAnswersItsID() {
        let reply = [UInt8](PortRefusal.mongoDBErrorReply("Stopped.", to: .message(id: 7, length: 120)) ?? Data())
        let document = [UInt8](PortRefusal.mongoDBErrorDocument("Stopped."))

        #expect(reply == Self.mongoDBHeader(length: 16 + 5 + 38, id: 0, operation: 2013).enumerated().map { $0.offset == 8 ? 7 : $0.element } + [0, 0, 0, 0, 0] + document)
    }

    @Test func anOPQUERYGetsAnOPREPLYWithOneDocument() {
        let reply = [UInt8](PortRefusal.mongoDBErrorReply("Stopped.", to: .query(id: 3, length: 250)) ?? Data())
        let document = [UInt8](PortRefusal.mongoDBErrorDocument("Stopped."))
        let fields: [UInt8] = Array(repeating: 0, count: 16) + [1, 0, 0, 0]

        #expect(reply == Self.mongoDBHeader(length: 16 + 20 + 38, id: 0, operation: 1).enumerated().map { $0.offset == 8 ? 3 : $0.element } + fields + document)
        #expect(PortRefusal.mongoDBErrorReply("Stopped.", to: .other) == nil)
    }
}
