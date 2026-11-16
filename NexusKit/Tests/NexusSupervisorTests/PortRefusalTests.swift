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
}
