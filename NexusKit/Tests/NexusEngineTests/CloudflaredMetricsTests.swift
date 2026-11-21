import Darwin
import Foundation
import Synchronization
import Testing
@testable import NexusEngine

// A metrics server of cloudflared on 127.0.0.1 with fixed answers by path.
final class FakeMetricsServer: @unchecked Sendable {
    let port: Int
    private let descriptor: Int32
    private let stopped = Mutex(false)
    private let ended = DispatchSemaphore(value: 0)

    init(answers: [String: (status: Int, body: String)]) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &named) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }

        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }

        descriptor = listener
        port = Int(UInt16(bigEndian: named.sin_port))

        Thread.detachNewThread { [self] in
            serve(answers: answers)
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        ended.wait()
        close(descriptor)
    }

    private func serve(answers: [String: (status: Int, body: String)]) {
        defer { ended.signal() }

        while !stopped.withLock({ $0 }) {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)

            guard poll(&waiting, 1, 20) > 0 else {
                continue
            }

            let client = accept(descriptor, nil, nil)

            guard client >= 0 else {
                continue
            }

            Self.answer(client, answers: answers)
        }
    }

    private static func answer(_ client: Int32, answers: [String: (status: Int, body: String)]) {
        defer { close(client) }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let capacity = buffer.count

        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, capacity)

            guard count > 0 else {
                return
            }

            request.append(contentsOf: buffer.prefix(count))
        }

        let words = String(decoding: request, as: UTF8.self).split(separator: " ")
        let path = words.count > 1 ? String(words[1]) : "/"
        let answer = answers[path] ?? (404, "")
        let text = "HTTP/1.1 \(answer.status) Test\r\nContent-Type: application/json\r\nContent-Length: \(answer.body.utf8.count)\r\nConnection: close\r\n\r\n\(answer.body)"
        let bytes = Array(text.utf8)
        _ = write(client, bytes, bytes.count)
    }
}

struct CloudflaredMetricsTests {
    @Test func theQuickTunnelGivesItsHost() async throws {
        let server = try FakeMetricsServer(answers: ["/quicktunnel": (200, #"{"hostname":"calm-river-tree-lamp.trycloudflare.com"}"#)])
        defer { server.stop() }

        #expect(await CloudflaredMetrics.quickTunnelHost(port: server.port) == "calm-river-tree-lamp.trycloudflare.com")
    }

    @Test func anEmptyHostnameGivesNoHost() async throws {
        let server = try FakeMetricsServer(answers: ["/quicktunnel": (200, #"{"hostname":""}"#)])
        defer { server.stop() }

        #expect(await CloudflaredMetrics.quickTunnelHost(port: server.port) == nil)
    }

    @Test func readyGivesTrueForAConnectionAndFalseWithoutOne() async throws {
        let ready = try FakeMetricsServer(answers: ["/ready": (200, #"{"status":200,"readyConnections":4}"#)])
        let waiting = try FakeMetricsServer(answers: ["/ready": (503, #"{"status":503,"readyConnections":0}"#)])
        defer {
            ready.stop()
            waiting.stop()
        }

        #expect(await CloudflaredMetrics.isReady(port: ready.port) == true)
        #expect(await CloudflaredMetrics.isReady(port: waiting.port) == false)
    }

    @Test func noListenerGivesNoAnswerWithinTheTimeLimit() async throws {
        let server = try FakeMetricsServer(answers: [:])
        let port = server.port
        server.stop()
        let start = ContinuousClock.now

        let ready = await CloudflaredMetrics.isReady(port: port)
        let host = await CloudflaredMetrics.quickTunnelHost(port: port)

        #expect(ready == nil)
        #expect(host == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
