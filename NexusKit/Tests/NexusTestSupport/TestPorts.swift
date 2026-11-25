import Darwin
import Synchronization

// A port that no other test of this run got, and that nothing listens on. A port that macOS gives
// out by itself (49152 and higher) can go to an outgoing connection right after its close. Then a
// check that the port is closed can connect to that connection. These ports are below that range,
// and above the ports of Nexus and Nexus Dev. PortGateTests.freePort uses 47001 to 48000, and
// freePortAboveNexus of the engine tests uses 48001 to 49000.
public enum TestPorts {
    private static let given = Mutex<Set<Int>>([])

    public static func free() -> Int {
        while true {
            let port = Int.random(in: 46_001...47_000)

            guard given.withLock({ $0.insert(port).inserted }), canBind(port) else {
                continue
            }

            return port
        }
    }

    private static func canBind(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
