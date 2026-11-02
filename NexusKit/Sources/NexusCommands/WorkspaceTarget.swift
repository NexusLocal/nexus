import Foundation
import NexusCore
import NexusIPC

// canAppearLater is true when a new worktree can give this workspace after a moment.
struct WorkspaceTargetError: Error, CustomStringConvertible {
    let description: String
    var canAppearLater = false
}

// The workspace that a command means. Without a name, that is the workspace of the current folder.
struct WorkspaceTarget: Equatable {
    let site: SiteInfo
    let workspace: WorkspaceInfo

    static func find(name: String?, site host: String?, folder: String, in sites: [SiteInfo]) throws -> WorkspaceTarget {
        let chosen = host.map { host in sites.filter { $0.hosts.contains(host) } } ?? sites

        if let host, chosen.isEmpty {
            throw WorkspaceTargetError(description: "Nexus has no site \(host).")
        }

        let targets = chosen.flatMap { site in (site.workspaces ?? []).map { WorkspaceTarget(site: site, workspace: $0) } }

        guard let name else {
            guard let target = deepestTarget(holding: folder, in: targets) else {
                throw WorkspaceTargetError(description: "\(folder) is in no workspace. Run nexus workspace create in a git worktree, or give the name of a workspace.", canAppearLater: true)
            }

            return target
        }

        let named = targets.filter { $0.workspace.name == name }

        // Two sites of one project share a record. So they list the same workspace.
        guard Set(named.map(\.workspace.folder)).count < 2 else {
            let hosts = named.compactMap(\.site.hosts.first).joined(separator: ", ")
            throw WorkspaceTargetError(description: "More sites have a workspace \(name): \(hosts). Choose one with --site.")
        }

        guard let target = named.first else {
            throw WorkspaceTargetError(description: "Nexus has no workspace \(name). See: nexus workspace list --all", canAppearLater: true)
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
    static func currentSite(folder: String, in sites: [SiteInfo]) -> SiteInfo? {
        let holders = sites.flatMap { site in
            let project = ProjectFolder.projectFolder(ofSiteFolder: URL(filePath: site.folder, directoryHint: .isDirectory))
            let folders = [project] + (site.workspaces ?? []).flatMap { [$0.worktree, $0.folder] }

            return folders.filter { RealPath.contains($0, folder) }.map { (site: site, depth: $0.count) }
        }

        return holders.max { $0.depth < $1.depth }?.site
    }
}

// What nexus workspace info --json prints (D38). A script reads these keys. So a key without a value
// is null and does not go away.
struct WorkspaceDetails: Encodable {
    let name: String
    let site: String
    let state: String
    let problem: String?
    let url: String?
    let hosts: [String]
    let worktree: String
    let folder: String
    let branch: String?
    let databases: [WorkspaceDatabaseInfo]
    let redisIndexes: [String: Int]
    let ports: [String: Int]
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case name, site, state, problem, url, hosts, worktree, folder, branch, databases, redisIndexes, ports, warnings
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(site, forKey: .site)
        try container.encode(state, forKey: .state)
        try container.encode(problem, forKey: .problem)
        try container.encode(url, forKey: .url)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(worktree, forKey: .worktree)
        try container.encode(folder, forKey: .folder)
        try container.encode(branch, forKey: .branch)
        try container.encode(databases, forKey: .databases)
        try container.encode(redisIndexes, forKey: .redisIndexes)
        try container.encode(ports, forKey: .ports)
        try container.encode(warnings, forKey: .warnings)
    }

    init(_ target: WorkspaceTarget) {
        let workspace = target.workspace

        name = workspace.name
        site = target.site.hosts.first ?? ""
        problem = workspace.isolationProblem ?? workspace.problem
        url = workspace.url
        hosts = workspace.hosts ?? []
        worktree = workspace.worktree
        folder = workspace.folder
        branch = workspace.branch
        databases = workspace.databases ?? []
        redisIndexes = workspace.redisIndexes ?? [:]
        ports = workspace.ports ?? [:]
        warnings = workspace.warnings ?? []

        switch workspace.state {
        case .ready:
            state = "ready"
        case .notIsolated:
            state = "not_isolated"
        case .preparing, nil:
            state = "preparing"
        }
    }

    var json: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}
