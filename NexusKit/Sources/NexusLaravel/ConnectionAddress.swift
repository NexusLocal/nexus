import Foundation
import NexusCore

// How PHP reaches the database server of a connection. A socket wins over the host and the port.
// MySQL and MariaDB read the host localhost as the standard socket of PHP. PostgreSQL reads a
// host that starts with / as the folder of its socket.
public enum ConnectionAddress: Equatable, Sendable {
    case socket(String)
    case localhostSocket(port: Int)
    case tcp(host: String, port: Int)

    init(path: String, driver: String, settings: [String: ConfigSetting]) {
        self.init(
            driver: driver,
            host: WorkspaceEnvPlan.value("host", at: path, settings: settings)?.description,
            port: WorkspaceEnvPlan.port(path, settings: settings),
            socket: WorkspaceEnvPlan.value("unix_socket", at: path, settings: settings)?.description
        )
    }

    // A value that is nil gets the default of config/database.php.
    public init(driver: String, host: String?, port: Int?, socket: String?) {
        let usesMySQLProtocol = driver != "pgsql"
        let host = host ?? WorkspaceEnvPlan.serverHost
        let port = port ?? (usesMySQLProtocol ? DatabaseKind.mysql : .postgresql).standardPort
        let socket = socket ?? ""

        if usesMySQLProtocol, !socket.isEmpty {
            self = .socket(socket)
            return
        }

        if !usesMySQLProtocol, host.hasPrefix("/") {
            self = .socket("\(RealPath.trimmed(host))/.s.PGSQL.\(port)")
            return
        }

        if usesMySQLProtocol, host.lowercased() == "localhost" {
            self = .localhostSocket(port: port)
            return
        }

        self = .tcp(host: host, port: port)
    }

    var isOnThisMac: Bool {
        guard case .tcp(let host, _) = self else {
            return true
        }

        return WorkspaceEnvPlan.localHosts.contains(host.lowercased())
    }

    // PHP does not know the standard socket of the MySQL client of Nexus. So localhost without a
    // socket reaches no instance of Nexus.
    public func reaches(port: Int, socket: String?) -> Bool {
        switch self {
        case .socket(let path):
            socket.map { RealPath.trimmed(path) == RealPath.trimmed($0) } ?? false
        case .localhostSocket:
            false
        case .tcp(let host, let ownPort):
            WorkspaceEnvPlan.localHosts.contains(host.lowercased()) && ownPort == port
        }
    }
}
