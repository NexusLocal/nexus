import Foundation
import NexusCore
import NexusIPC

// Why Nexus finds no workspace. description is the text for the terminal. The MCP tools write
// their own text from the reason, because an agent cannot use the options of a command.
public struct WorkspaceTargetError: Error, CustomStringConvertible, Equatable {
    public enum Reason: Sendable, Equatable {
        case noSite(String)
        case notInWorkspace(folder: String)
        case sameName(String, hosts: [String])
        case noWorkspace(String)
    }

    public let reason: Reason

    public init(_ reason: Reason) {
        self.reason = reason
    }

    // A new worktree can give this workspace after a moment.
    public var canAppearLater: Bool {
        switch reason {
        case .notInWorkspace, .noWorkspace: true
        case .noSite, .sameName: false
        }
    }

    public var description: String {
        switch reason {
        case .noSite(let host): "Nexus has no site \(host)."
        case .notInWorkspace(let folder): "\(folder) is in no workspace. Run nexus workspace create in a git worktree, or give the name of a workspace."
        case .sameName(let name, let hosts): "More sites have a workspace \(name): \(hosts.joined(separator: ", ")). Choose one with --site."
        case .noWorkspace(let name): "Nexus has no workspace \(name). See: nexus workspace list --all"
        }
    }
}

// The workspace that a command means. Without a name, that is the workspace of the current folder.
public struct WorkspaceTarget: Equatable, Sendable {
    public let site: SiteInfo
    public let workspace: WorkspaceInfo

    public init(site: SiteInfo, workspace: WorkspaceInfo) {
        self.site = site
        self.workspace = workspace
    }

    public static func find(name: String?, site host: String?, folder: String, in sites: [SiteInfo]) throws -> WorkspaceTarget {
        let chosen = host.map { host in sites.filter { $0.hosts.contains(host) } } ?? sites

        if let host, chosen.isEmpty {
            throw WorkspaceTargetError(.noSite(host))
        }

        let targets = chosen.flatMap { site in (site.workspaces ?? []).map { WorkspaceTarget(site: site, workspace: $0) } }

        guard let name else {
            guard let target = deepestTarget(holding: folder, in: targets) else {
                throw WorkspaceTargetError(.notInWorkspace(folder: folder))
            }

            return target
        }

        let named = targets.filter { $0.workspace.name == name }

        // Two sites of one project share a record. So they list the same workspace.
        guard Set(named.map(\.workspace.folder)).count < 2 else {
            throw WorkspaceTargetError(.sameName(name, hosts: named.compactMap(\.site.hosts.first)))
        }

        guard let target = named.first else {
            throw WorkspaceTargetError(.noWorkspace(name))
        }

        return target
    }

    // A worktree can be in another worktree. Two sites of one repository have one worktree. The
    // deepest worktree wins. In that worktree the workspace whose own folder holds the path wins. An
    // inner worktree without a workspace does not give the workspace around it, because a removal
    // would then remove the outer worktree.
    private static func deepestTarget(holding folder: String, in targets: [WorkspaceTarget]) -> WorkspaceTarget? {
        let currentWorktree = ProjectFolder.worktree(holding: folder)?.root

        func ownDepth(_ target: WorkspaceTarget) -> Int {
            RealPath.contains(target.workspace.folder, folder) ? target.workspace.folder.count : 0
        }

        let holders = targets.filter { target in
            currentWorktree.map { $0 == target.workspace.worktree } ?? RealPath.contains(target.workspace.worktree, folder)
        }

        return holders.max { first, second in
            (first.workspace.worktree.count, ownDepth(first)) < (second.workspace.worktree.count, ownDepth(second))
        }
    }

    // The site of the project or of one of its worktrees that holds the folder. The deepest folder
    // wins, as in ProjectFolder.locate. Two sites of one repository share a worktree. So the folder
    // of a workspace in that worktree tells them apart.
    public static func currentSite(folder: String, in sites: [SiteInfo]) -> SiteInfo? {
        let holders = sites.flatMap { site in
            let project = ProjectFolder.projectFolder(ofSiteFolder: URL(filePath: site.folder, directoryHint: .isDirectory))
            let folders = [project] + (site.workspaces ?? []).flatMap { [$0.worktree, $0.folder] }

            return folders.filter { RealPath.contains($0, folder) }.map { (site: site, depth: $0.count) }
        }

        return holders.max { $0.depth < $1.depth }?.site
    }
}

public struct SiteTargetError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

// The site or the workspace that nexus open, nexus edit, the database commands and the MCP tools
// mean. A host names a site or a workspace. Without a host, the workspace of the current folder
// comes first, then its site.
public struct SiteTarget: Equatable, Sendable {
    public let site: SiteInfo
    public let workspace: WorkspaceInfo?

    public init(site: SiteInfo, workspace: WorkspaceInfo?) {
        self.site = site
        self.workspace = workspace
    }

    public static func find(host: String?, folder: String, in sites: [SiteInfo], example: String) throws -> SiteTarget {
        if let host {
            return try named(host, in: sites)
        }

        if let target = try? WorkspaceTarget.find(name: nil, site: nil, folder: folder, in: sites) {
            return SiteTarget(site: target.site, workspace: target.workspace)
        }

        guard let site = WorkspaceTarget.currentSite(folder: folder, in: sites) else {
            throw SiteTargetError(description: "\(folder) is in no site of Nexus. Give a host, for example: \(example)")
        }

        return SiteTarget(site: site, workspace: nil)
    }

    private static func named(_ host: String, in sites: [SiteInfo]) throws -> SiteTarget {
        if let site = sites.first(where: { $0.hosts.contains(host) }) {
            return SiteTarget(site: site, workspace: nil)
        }

        for site in sites {
            if let workspace = site.workspaces?.first(where: { $0.hosts?.contains(host) == true }) {
                return SiteTarget(site: site, workspace: workspace)
            }
        }

        throw SiteTargetError(description: "Nexus has no site or workspace \(host). See: nexus site list")
    }

    public var siteHost: String {
        site.hosts.first ?? ""
    }

    public var host: String {
        workspace.map { $0.hosts?.first ?? $0.name } ?? siteHost
    }

    public var url: String? {
        guard let workspace else {
            return site.url
        }

        return workspace.url
    }

    public var folder: String {
        workspace?.folder ?? site.folder
    }

    // A site on the public folder of a project opens the project in the editor.
    public var projectFolder: String {
        ProjectFolder.projectFolder(ofSiteFolder: URL(filePath: folder, directoryHint: .isDirectory))
    }
}

extension DatabaseTarget {
    // The server of the first connection on a server of Nexus. A workspace uses its own server.
    public static func server(of target: SiteTarget, connections: [DatabaseConnectionInfo]) -> DatabaseTarget? {
        guard let instance = connections.lazy.compactMap(\.instance).first else {
            return nil
        }

        guard let workspace = target.workspace else {
            return .instance(instance)
        }

        return .workspace(site: target.siteHost, name: workspace.name, instance: instance)
    }
}
