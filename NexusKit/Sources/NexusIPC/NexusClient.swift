import Foundation
import NexusCore

public enum NexusClientError: Error, CustomStringConvertible, Equatable {
    case daemonNotRunning(String)
    // nexusd refuses each request of a program whose file changed after its start (bug
    // 2026-11-17). The description is the text of the nexus command. The MCP server has its own.
    case programChanged(ProgramChange)

    public var description: String {
        switch self {
        case .daemonNotRunning(let reason):
            "Nexus cannot reach its background service nexusd. Open the Nexus app once, so it can start nexusd. (\(reason))"
        case .programChanged(.updated):
            "Nexus was updated while this command ran. Run the command again."
        case .programChanged(.removed):
            "Nexus was moved or removed while this command ran. Open Nexus. Then run the command again."
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
            if let change = ExecutableFile.changeSinceStart {
                throw NexusClientError.programChanged(change)
            }

            throw NexusClientError.daemonNotRunning(reason)
        }
    }
}
