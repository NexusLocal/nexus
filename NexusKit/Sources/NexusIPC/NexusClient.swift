import Foundation
import NexusCore

public enum NexusClientError: Error, CustomStringConvertible {
    case daemonNotRunning(String)

    public var description: String {
        switch self {
        case .daemonNotRunning(let reason):
            "Nexus cannot reach its background service nexusd. Open the Nexus app once, so it can start nexusd. (\(reason))"
        }
    }
}

// Sends one request to nexusd over its XPC Mach service and waits for the answer. Every call uses
// a new connection, because the CLI sends one request and ends.
public struct NexusClient: Sendable {
    private let serviceName: String

    public init(serviceName: String = NexusIdentifiers.daemon) {
        self.serviceName = serviceName
    }

    public func send(_ request: NexusRequest) async throws -> NexusResponse {
        let payload = try NexusMessageCoding.encode(request)
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: NexusDaemonProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: NexusClientError.daemonNotRunning(error.localizedDescription))
            }

            guard let daemon = proxy as? NexusDaemonProtocol else {
                once.resume(throwing: NexusClientError.daemonNotRunning("no daemon proxy"))
                return
            }

            daemon.handle(payload) { reply in
                once.resume(returning: reply)
            }
        }

        return try NexusMessageCoding.decode(NexusResponse.self, from: data)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        take()?.resume(returning: data)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
