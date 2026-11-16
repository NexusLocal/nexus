import Foundation
import NexusCore

// A database server of a workspace, as the gate of its port knows it (plan items 3c and 3e). folder
// is the clone folder. It is also the id of the server program. socket is the Unix socket of the
// server, and log is the log of its instance. The engine sets both from the line of the installed
// runtime.
public struct GatedServer: Sendable, Hashable {
    public let folder: String
    public let instance: String
    public let kind: DatabaseKind
    public let port: Int
    public let socket: URL
    public let log: URL

    public init(folder: String, instance: String, kind: DatabaseKind, port: Int, socket: URL, log: URL) {
        self.folder = folder
        self.instance = instance
        self.kind = kind
        self.port = port
        self.socket = socket
        self.log = log
    }

    // The reason for the clients of a start when the server ends during that start.
    var stoppedDuringStart: String {
        "The server stopped during its start. See \(log.path(percentEncoded: false))."
    }

    // The folder and the port name the server. The socket and the log come from the line of the
    // installed runtime. So they can change between two lists, and the server stays the same.
    func isSame(as other: GatedServer?) -> Bool {
        folder == other?.folder && port == other?.port
    }
}

// The calls between the idle stop (3c) and the hand-over of the database ports (3e). 3c decides
// when a workspace runs. While a server of a stopped workspace does not run, the gate holds its port
// on 127.0.0.1. A client that connects there starts the workspace.
public protocol WorkspaceServerGate: Sendable {
    // One call at the start of nexusd, before the first sync. The gate calls wake when a client connects
    // to a port that it holds. The gate calls wake from a Task, and never from a thread that relays
    // bytes. wake answers nil when 3c began the start of the workspace, or when the sync started the
    // server of a workspace that runs. serverWillStart then came already for each server that
    // starts. Else wake answers the reason.
    func begin(wake: @escaping @Sendable (GatedServer) async -> String?) async

    // The servers whose port the gate holds while they do not run. Each call gives the whole list.
    func hold(_ servers: Set<GatedServer>) async

    // Around each start and each stop of a workspace server. The gate does nothing for a server whose
    // port it does not hold. A server that starts leaves the list of hold until the next list.
    // serverWillStart answers the number of the hand-over when the gate hands the port over to the
    // server. The supervisor then does not check that port, because the gate still listens on it.
    //
    // serverDidNotStart with that number ends that hand-over. A number of an earlier hand-over
    // changes nothing. An exit after which the supervisor starts the server again is no failed start.
    func serverWillStart(_ server: GatedServer) async -> Int?
    func serverDidNotStart(_ server: GatedServer, handOver: Int?, reason: String) async
    func serverWillStop(_ server: GatedServer) async
    func serverDidStop(_ server: GatedServer) async

    // Waits while the gate hands the port over to its server. A TCP probe of that port reaches the
    // gate in that time. Answers the reason when the server did not start.
    func waitForHandOver(of port: Int) async -> String?

    // One call at the stop of nexusd. Each client that waits gets the reason.
    func end(reason: String) async
}

// Without the gate a client of a stopped server gets "Connection refused".
public struct NoServerGate: WorkspaceServerGate {
    public init() {}

    public func begin(wake: @escaping @Sendable (GatedServer) async -> String?) async {}
    public func hold(_ servers: Set<GatedServer>) async {}
    public func serverWillStart(_ server: GatedServer) async -> Int? { nil }
    public func serverDidNotStart(_ server: GatedServer, handOver: Int?, reason: String) async {}
    public func serverWillStop(_ server: GatedServer) async {}
    public func serverDidStop(_ server: GatedServer) async {}
    public func waitForHandOver(of port: Int) async -> String? { nil }
    public func end(reason: String) async {}
}
