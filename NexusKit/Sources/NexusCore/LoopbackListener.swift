import Darwin
import Dispatch
import Foundation
import Synchronization

// A TCP server on 127.0.0.1 for the SMTP server and the web page of the dumps. Each connection
// runs on its own thread with blocking reads, because a local server has few connections. serve
// owns the socket and closes it.
package final class LoopbackListener: Sendable {
    private struct Listening: @unchecked Sendable {
        let source: any DispatchSourceRead
        let closed: DispatchSemaphore
    }

    private let requestedPort: Int
    private let label: String
    private let idleTimeout: TimeInterval
    private let serve: @Sendable (LineSocket) -> Void
    private let listening = Mutex<Listening?>(nil)
    private let boundPort = Mutex(0)

    // Port 0 takes a free port, for the tests.
    package init(port: Int, label: String, idleTimeout: TimeInterval, serve: @escaping @Sendable (LineSocket) -> Void) {
        requestedPort = port
        self.label = label
        self.idleTimeout = idleTimeout
        self.serve = serve
    }

    package var port: Int {
        boundPort.withLock { $0 }
    }

    package func start() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = LineSocket.loopback(port: requestedPort)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bound == 0, listen(descriptor, 64) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("bind", code)
        }

        boundPort.withLock { $0 = Self.localPort(of: descriptor) }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: label))
        source.setEventHandler { [weak self] in
            self?.acceptConnection(on: descriptor)
        }
        let closed = DispatchSemaphore(value: 0)
        source.setCancelHandler {
            close(descriptor)
            closed.signal()
        }
        listening.withLock { $0 = Listening(source: source, closed: closed) }
        source.resume()
    }

    // The port is free when stop returns. So a removal or a port change can use it at once. A
    // connection that is open stays until its client or its timeout ends it.
    package func stop() {
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

    private func acceptConnection(on descriptor: Int32) {
        let client = accept(descriptor, nil, nil)

        // Without a free descriptor the source fires again at once. A short pause keeps the queue
        // out of a loop at full speed, until a connection ends.
        guard client >= 0 else {
            if errno == EMFILE || errno == ENFILE {
                Thread.sleep(forTimeInterval: 0.1)
            }

            return
        }

        Thread.detachNewThread { [self] in
            serve(LineSocket(descriptor: client, timeout: idleTimeout))
        }
    }

    private static func localPort(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}
