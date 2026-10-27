import Foundation
import NexusEngine
import NexusIPC

final class DaemonService: NSObject, NSXPCListenerDelegate, NexusDaemonXPCService, @unchecked Sendable {
    private let engine: NexusEngine
    private let requirement: String?
    private let watchers: NexusEventWatchers

    init(engine: NexusEngine) {
        self.engine = engine
        self.requirement = CodeSigning.ownTeamIdentifier().map { "anchor apple generic and certificate leaf[subject.OU] = \"\($0)\"" }
        self.watchers = NexusEventWatchers { await engine.events() }
    }

    // Only programs that are signed by the same team as nexusd may connect, so another app on
    // the Mac cannot start or stop services.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement {
            connection.setCodeSigningRequirement(requirement)
        }

        connection.exportedInterface = NSXPCInterface(with: NexusDaemonXPCService.self)
        connection.exportedObject = self
        watchers.prepare(connection)
        connection.resume()
        return true
    }

    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine

        Task {
            let response: NexusResponse
            if let decoded = try? NexusMessageCoding.decode(NexusRequest.self, from: request) {
                response = await engine.handle(decoded)
            } else {
                response = .failure(message: "nexusd could not read the request.")
            }

            reply((try? NexusMessageCoding.encode(response)) ?? Data())
        }
    }

    func watch() {
        watchers.watchCurrentConnection()
    }
}
