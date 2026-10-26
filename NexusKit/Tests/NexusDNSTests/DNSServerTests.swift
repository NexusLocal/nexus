import Foundation
import NexusTestSupport
import Testing
@testable import NexusDNS

struct DNSServerTests {
    private func dig(_ name: String, port: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/dig")
        process.arguments = ["@127.0.0.1", "-p", String(port), "+short", "+time=2", "+tries=1", name]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func digGetsTheLoopbackAddressForANameInTheTLD() throws {
        let port = freeUDPPort()
        let server = DNSServer(responder: DNSResponder(tld: "test"))
        try server.start(port: port)
        defer { server.stop() }

        #expect(try dig("anything.test", port: port) == "127.0.0.1")
        #expect(try dig("deep.name.anything.test", port: port) == "127.0.0.1")
    }

    @Test func aSecondServerOnTheSamePortReportsThePort() throws {
        let port = freeUDPPort()
        let first = DNSServer(responder: DNSResponder(tld: "test"))
        try first.start(port: port)
        defer { first.stop() }

        #expect(throws: DNSServerError.portInUse(port)) {
            try DNSServer(responder: DNSResponder(tld: "test")).start(port: port)
        }
    }

    @Test func stopFreesThePort() throws {
        let port = freeUDPPort()
        let server = DNSServer(responder: DNSResponder(tld: "test"))
        try server.start(port: port)

        server.stop()

        let again = DNSServer(responder: DNSResponder(tld: "test"))
        try again.start(port: port)
        again.stop()
        #expect(server.port == nil)
    }
}
