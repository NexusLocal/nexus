import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor

extension ServiceKind {
    init?(package: String) {
        switch package {
        case "nginx", "httpd": self = .webservers
        case "php": self = .php
        case "mysql": self = .mysql
        case "mariadb": self = .mariadb
        case "postgresql": self = .postgresql
        case "redis": self = .redis
        case "dns": self = .dns
        default: return nil
        }
    }

    var databaseKind: DatabaseKind? {
        switch self {
        case .mysql: .mysql
        case .mariadb: .mariadb
        case .postgresql: .postgresql
        case .webservers, .php, .redis, .dns: nil
        }
    }
}

extension PortHolder {
    // nexusd cannot see a program of another user. So it has no owner then.
    init(_ conflict: PortConflict) {
        self.init(
            port: conflict.port,
            app: conflict.owner?.application ?? "another user",
            process: conflict.owner?.command ?? "a process",
            processNumber: Int(conflict.owner?.pid ?? 0),
            path: conflict.owner?.executable ?? "",
            suggestedPort: conflict.suggestedPort
        )
    }
}

extension ServiceVersion {
    // A package that the app does not know yet gives no row.
    init?(_ info: ServiceInfo) {
        guard let kind = ServiceKind(package: info.name) else {
            return nil
        }

        let name = switch info.name {
        case "nginx": "nginx \(info.line)"
        case "httpd": "Apache \(info.line)"
        case "dns": "DNS"
        default: "\(kind.title) \(info.line)"
        }

        self.init(id: info.id, kind: kind, name: name, version: info.version, health: .stopped)
        line = info.line
        ports = Self.ports(of: info)
        internalPort = info.name == "httpd"
        dataFolder = info.dataFolder.map { ($0 as NSString).abbreviatingWithTildeInPath }
        account = info.account
        logFile = info.logFile
        toggles = (info.toggles ?? []).map { ToggleItem(name: $0.name, enabled: $0.enabled, required: $0.required, help: $0.help ?? "") }
        customSettings = info.customSettings ?? []
        usedBy = info.usedBy ?? []
        note = info.note

        switch info.state {
        case .stopped:
            if let conflict = info.portConflict {
                health = .attention
                problem = ServiceProblem(summary: "Port in use", detail: conflict.description, portHolder: PortHolder(conflict))
            }
        case .running(_, let since):
            health = .running
            self.since = since.formatted(date: Calendar.current.isDateInToday(since) ? .omitted : .abbreviated, time: .shortened)

            if let detail = info.problem {
                health = .attention
                activeWithProblem = true
                problem = ServiceProblem(summary: "Not set up", detail: detail)
            }
        case .restarting(let attempt):
            health = .attention
            activeWithProblem = true
            stoppedUnexpectedly = true
            problem = ServiceProblem(summary: "Restarting", detail: "\(name) stopped without a request. Nexus starts it again, attempt \(attempt).")
        case .failed(let reason):
            health = .failed
            stoppedUnexpectedly = true
            problem = ServiceProblem(summary: "Failed", detail: reason)
        }
    }

    // nginx first, then Apache. The other kinds show their oldest version first.
    static func showsBefore(_ first: ServiceVersion, _ second: ServiceVersion) -> Bool {
        let kinds = ServiceKind.allCases

        if first.kind != second.kind {
            return kinds.firstIndex(of: first.kind)! < kinds.firstIndex(of: second.kind)!
        }

        if first.kind == .webservers {
            return first.id == "nginx"
        }

        return first.name.compare(second.name, options: .numeric) == .orderedAscending
    }

    var webServer: WebServer? {
        guard kind == .webservers else {
            return nil
        }

        return id == "apache" ? .apache : .nginx
    }

    // The link of a database app (D36), with the account of the instance.
    func databaseURL(_ database: String? = nil) -> URL? {
        guard let kind = kind.databaseKind, let port = ports.first?.number else {
            return nil
        }

        return kind.url(port: port, account: account ?? .newInstance, database: database)
    }

    private static func ports(of info: ServiceInfo) -> [ServicePort] {
        let names: [(name: String, key: String)] = switch info.name {
        case "nginx": [("HTTP", "http"), ("HTTPS", "https")]
        case "httpd": [("Internal", "apache")]
        default: [("Port", info.id)]
        }

        return zip(names, info.ports).map { ServicePort(name: $0.name, number: $1, key: $0.key) }
    }
}
