import Foundation
import NexusCore
import NexusIPC

// A database connection for an agent, with the password. A local database of Nexus has no
// secret worth more than the time an agent loses when it guesses.
public struct AgentDatabase: Codable, Sendable, Equatable {
    public let connection: String?
    public let kind: String?
    public let database: String
    public let host: String
    public let port: Int?
    public let user: String?
    public let password: String?
    public let url: String?
    public let server: String

    public init(_ info: DatabaseConnectionInfo, inWorkspace: Bool) {
        connection = info.connection
        kind = info.kind?.displayName
        database = info.database
        host = info.host
        port = info.port
        user = info.account?.user
        password = info.account?.password
        url = info.url?.absoluteString
        server = info.instance.map { inWorkspace ? "the database server of the workspace (a clone of \($0))" : $0 } ?? "not a server of Nexus"
    }
}

public struct AgentWorkspace: Codable, Sendable, Equatable {
    public let name: String
    public let host: String?
    public let url: String?
    public let branch: String?
    public let folder: String
    public let state: String
    public let problem: String?

    public init(_ workspace: WorkspaceInfo) {
        name = workspace.name
        host = workspace.hosts?.first
        url = workspace.url
        branch = workspace.branch
        folder = workspace.folder
        problem = workspace.isolationMessage ?? workspace.problem

        switch workspace.state {
        case .ready: state = "ready"
        case .notIsolated: state = "not_isolated"
        case .preparing, nil: state = "preparing"
        }
    }
}

public struct AgentMailSetting: Codable, Sendable, Equatable {
    public let sendsToNexus: Bool
    public let tag: String
    public let note: String
}

public struct AgentTestDatabase: Codable, Sendable, Equatable {
    public let connection: String?
    public let database: String?
    public let source: String
    public let usesDevelopmentDatabase: Bool
    public let note: String

    public init(_ check: TestDatabaseCheck) {
        connection = check.connection
        database = check.database
        source = check.source
        usesDevelopmentDatabase = check.usesDevelopmentDatabase

        switch check.kind {
        case .development:
            note = "Warning: the tests use \(check.developmentDatabase ?? "the database") of .env, the development database. A test that resets the database removes all development data. Do not run such tests. Ask the user to choose a test database in Nexus (the Site screen, section Databases)."
        case .sqliteMemory:
            note = "The tests use SQLite in memory. They do not touch the development database."
        case .separate:
            note = "The tests use \(check.database ?? "another database"), not the development database."
        }
    }
}

// SiteInfo holds much that an agent does not need. Each extra key costs room in its context.
public struct AgentSite: Codable, Sendable, Equatable {
    public let site: String
    public let workspace: AgentWorkspace?
    public let url: String?
    public let aliases: [String]
    public let folder: String
    public let projectFolder: String
    public let type: String
    public let php: String?
    public let node: String?
    public let webServer: String?
    public let documentRoot: String?
    public let databases: [AgentDatabase]
    public let mail: AgentMailSetting?
    public let testDatabase: AgentTestDatabase?
    public let workspaces: [AgentWorkspace]
    public let problem: String?

    public init(target: SiteTarget, connections: [DatabaseConnectionInfo], mail: SiteMail?, testDatabase: TestDatabaseCheck?) {
        let site = target.site

        self.site = target.siteHost
        workspace = target.workspace.map(AgentWorkspace.init)
        url = target.url
        aliases = target.workspace == nil ? Array(site.hosts.dropFirst()) : Array((target.workspace?.hosts ?? []).dropFirst())
        folder = target.folder
        projectFolder = target.projectFolder
        type = Self.type(of: site)
        php = site.kind == .php ? site.php : nil
        node = site.kind == .node ? site.node : nil
        webServer = site.kind == .php ? site.server.rawValue : nil
        documentRoot = site.kind == .php ? target.workspace.map(\.documentRoot) ?? site.documentRoot : nil
        databases = connections.map { AgentDatabase($0, inWorkspace: target.workspace != nil) }
        self.mail = mail.map { Self.mailSetting($0, tag: target.host) }
        self.testDatabase = testDatabase.map(AgentTestDatabase.init)
        workspaces = target.workspace == nil ? (site.workspaces ?? []).map(AgentWorkspace.init) : []
        problem = target.workspace.flatMap { $0.isolationMessage ?? $0.problem } ?? site.problem
    }

    public static func type(of site: SiteInfo) -> String {
        switch site.kind {
        case .node: site.framework.map { "Node.js app (\($0.displayName))" } ?? "Node.js app"
        case .proxy: "Proxy to \(site.address ?? "a server that you start")"
        case .php: site.projectType?.displayName ?? "PHP"
        }
    }

    static func mailSetting(_ mail: SiteMail, tag: String) -> AgentMailSetting {
        if mail.sendsToNexus {
            return AgentMailSetting(sendsToNexus: true, tag: tag, note: "The mail goes to the Nexus inbox and never leaves this Mac. list_mail, read_mail and wait_for_mail find it.")
        }

        let destination = mail.destination.map { " The mail setting of the site is \($0)." } ?? ""
        let fix = mail.canSendToNexus ? " The user can send it to Nexus with \"Send mail to Nexus\" on the Site screen of Nexus." : ""
        return AgentMailSetting(sendsToNexus: false, tag: tag, note: (mail.warning ?? "The mail does not go to the Nexus inbox.\(destination)") + fix)
    }
}

public struct AgentSiteRow: Codable, Sendable, Equatable {
    public let site: String
    public let url: String
    public let folder: String
    public let type: String
    public let php: String?
    public let node: String?
    public let problem: String?
    public let workspaces: [AgentWorkspace]

    public init(_ site: SiteInfo) {
        self.site = site.hosts.first ?? ""
        url = site.url
        folder = site.folder
        type = AgentSite.type(of: site)
        php = site.kind == .php ? site.php : nil
        node = site.kind == .node ? site.node : nil
        problem = site.problem
        workspaces = (site.workspaces ?? []).map(AgentWorkspace.init)
    }
}
