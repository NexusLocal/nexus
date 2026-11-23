import Darwin

// The IPv4 parts that the sockets of nexusd share: the address of a host and a port, a connection
// to 127.0.0.1 and a TCP listener.
package enum IPv4Socket {
    package static let loopback = inet_addr("127.0.0.1")

    package static func address(_ host: in_addr_t, port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: host)
        return address
    }

    // SO_NOSIGPIPE comes before the connect. So a write to a connection that the other side closed
    // gives an error and does not end nexusd.
    package static func connectToLoopback(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var target = address(loopback, port: port)

        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("connect", code)
        }

        return descriptor
    }

    // A port on 127.0.0.1 that macOS gives out as free now. Another program can take it before the
    // caller binds it, but that is rare.
    package static func freeLoopbackPort() throws -> Int {
        let descriptor = try listener(on: 0, host: loopback, backlog: 1)
        defer { close(descriptor) }

        var local = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)

        let found = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }

        guard found == 0 else {
            throw SocketError.system("getsockname", errno)
        }

        return Int(UInt16(bigEndian: local.sin_port))
    }

    // SO_REUSEADDR, as the database servers set it. So a listener on all addresses and one on
    // 127.0.0.1 can hold one port, and closed connections that wait on the port after a restart do
    // not block the bind.
    package static func listener(on port: Int, host: in_addr_t, backlog: Int32) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var local = address(host, port: port)

        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        guard bound == 0, listen(descriptor, backlog) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("bind", code)
        }

        return descriptor
    }
}
