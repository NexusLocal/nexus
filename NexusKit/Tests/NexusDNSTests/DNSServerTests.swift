import Darwin
import Foundation
import Testing
@testable import NexusDNS

struct DNSServerTests {
    private func freeUDPPort() -> Int {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

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
