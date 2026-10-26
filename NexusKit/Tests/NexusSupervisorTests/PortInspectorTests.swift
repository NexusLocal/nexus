import Darwin
import Foundation
import Testing
@testable import NexusSupervisor

struct PortInspectorTests {
    private func listen(on address: String) throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr = in_addr(s_addr: inet_addr(address))
        _ = withUnsafePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(Darwin.listen(descriptor, 5) == 0)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return (descriptor, Int(UInt16(bigEndian: bound.sin_port)))
    }

    @Test func aListenerOnLoopbackOrOnAllAddressesHoldsThePort() throws {
        for address in ["127.0.0.1", "0.0.0.0"] {
            let listener = try listen(on: address)

            #expect(!PortInspector.isFree(listener.port))
            #expect(PortInspector.acceptsConnections(listener.port))

            close(listener.descriptor)
            #expect(PortInspector.isFree(listener.port))
        }
    }

    @Test func aClosedConnectionDoesNotHoldThePort() throws {
        let listener = try listen(on: "127.0.0.1")
        #expect(PortInspector.acceptsConnections(listener.port))
        close(listener.descriptor)

        #expect(PortInspector.isFree(listener.port))
    }

    @Test func aLowPortWithoutAListenerIsFree() {
        #expect(PortInspector.isFree(81))
    }
}
