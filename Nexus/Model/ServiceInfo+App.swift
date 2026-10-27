import Foundation
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
        ports = Self.ports(of: info)
        internalPort = info.name == "httpd"

        switch info.state {
        case .stopped:
            break
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
            problem = ServiceProblem(summary: "Restarting", detail: "\(name) stopped without a request. Nexus starts it again, attempt \(attempt).")
        case .failed(let reason):
            health = .failed
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

    private static func ports(of info: ServiceInfo) -> [ServicePort] {
        let names = switch info.name {
        case "nginx": ["HTTP", "HTTPS"]
        case "httpd": ["Internal"]
        default: ["Port"]
        }

        return zip(names, info.ports).map { ServicePort(name: $0, number: $1) }
    }
}
