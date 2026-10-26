import Darwin
import Dispatch
import Foundation
import Synchronization

public enum DNSServerError: Error, Equatable, CustomStringConvertible {
    case portInUse(Int)
    case socketFailed(String)

    public var description: String {
        switch self {
        case .portInUse(let port):
            "UDP port \(port) on 127.0.0.1 is in use, so the DNS server of Nexus cannot start. Give it another port: nexus port dns <port>"
        case .socketFailed(let reason):
            "The DNS server of Nexus cannot open its socket: \(reason)"
        }
    }
}

// A UDP DNS server on 127.0.0.1. macOS sends it the questions for the dev TLD, because
// /etc/resolver/<tld> names this address and port. It binds a high port, so it needs no root.
public final class DNSServer: Sendable {
    public static let defaultPort = 10053

    private struct Listening: @unchecked Sendable {
        let port: Int
        let source: any DispatchSourceRead
        let closed: DispatchSemaphore
    }

    private let responder: DNSResponder
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.dns")
    private let listening = Mutex<Listening?>(nil)

    public init(responder: DNSResponder) {
        self.responder = responder
    }

    public var port: Int? {
        listening.withLock { $0?.port }
    }

    public func start(port: Int) throws {
        stop()

        let descriptor = try Self.bind(port: port)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let closed = DispatchSemaphore(value: 0)
        let responder = responder

        source.setEventHandler {
            Self.answer(on: descriptor, using: responder)
        }
        source.setCancelHandler {
            close(descriptor)
            closed.signal()
        }

        listening.withLock { $0 = Listening(port: port, source: source, closed: closed) }
        source.resume()
    }

    // Waits until the socket is closed, so a new start on the same port can bind it.
    public func stop() {
        let current = listening.withLock { listening in
            defer { listening = nil }
            return listening
        }

        guard let current else {
            return
        }

        current.source.cancel()
        current.closed.wait()
    }

    private static func bind(port: Int) throws -> Int32 {
        guard (1...65535).contains(port) else {
            throw DNSServerError.socketFailed("\(port) is not a valid port.")
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw DNSServerError.socketFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw code == EADDRINUSE ? DNSServerError.portInUse(port) : DNSServerError.socketFailed(String(cString: strerror(code)))
        }

        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    private static func answer(on descriptor: Int32, using responder: DNSResponder) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sender = sockaddr_storage()
        var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

        while true {
            let received = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }

            guard received > 0 else {
                return
            }

            if let response = responder.response(to: Array(buffer.prefix(received))) {
                _ = withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, response, response.count, 0, $0, senderLength)
                    }
                }
            }

            senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        }
    }
}
