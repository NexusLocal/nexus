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

// Sends one request to nexusd over its XPC Mach service and waits for the answer.
public struct NexusClient: Sendable {
    private let channel: XPCChannel

    public init(serviceName: String = NexusIdentifiers.daemon) {
        self.channel = XPCChannel(serviceName: serviceName, privileged: false)
    }

    public func send(_ request: NexusRequest) async throws -> NexusResponse {
        let payload = try NexusMessageCoding.encode(request)

        do {
            return try NexusMessageCoding.decode(NexusResponse.self, from: try await channel.send(payload))
        } catch XPCChannelError.unreachable(let reason) {
            throw NexusClientError.daemonNotRunning(reason)
        }
    }
}
