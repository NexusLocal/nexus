import Foundation
import NexusCore

// The requests that nexusd sends to the privileged helper. The helper checks every value again,
// because it runs as root.
public enum HelperRequest: Codable, Sendable, Equatable {
    case setResolver(tld: String, port: Int)
    case removeResolver(tld: String)
    case setHosts([String])
}

public enum HelperResponse: Codable, Sendable, Equatable {
    case done
    case failure(message: String)
}

public enum HelperError: Error, Equatable, CustomStringConvertible {
    case notReachable(String)
    case refused(String)

    public var description: String {
        switch self {
        case .notReachable(let reason):
            "The Nexus helper does not answer. Open Nexus and approve the helper in System Settings > General > Login Items & Extensions. (\(reason))"
        case .refused(let message):
            "The Nexus helper refused the change: \(message)"
        }
    }
}

public protocol PrivilegedHelper: Sendable {
    func send(_ request: HelperRequest) async throws
}

// The helper is a launchd daemon in the system domain, so the connection is privileged.
public struct HelperClient: PrivilegedHelper {
    private let channel = XPCChannel(serviceName: NexusIdentifiers.helper, privileged: true)

    public init() {}

    public func send(_ request: HelperRequest) async throws {
        let reply: Data
        do {
            reply = try await channel.send(try NexusMessageCoding.encode(request))
        } catch XPCChannelError.unreachable(let reason) {
            throw HelperError.notReachable(reason)
        }

        if case .failure(let message) = try NexusMessageCoding.decode(HelperResponse.self, from: reply) {
            throw HelperError.refused(message)
        }
    }
}
