import Foundation
import NexusCore
import NexusIPC
import NexusMCP

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
    // The idle stop (owner, 2026-11-15). runState is running, starting or stopped. stopWhenIdle is
    // false when "Stop when idle" is off.
    let runState: String
    let stopWhenIdle: Bool
    let lastActivity: Date?

    private enum CodingKeys: String, CodingKey {
        case name, site, state, problem, url, hosts, worktree, folder, branch, databases, redisIndexes, ports, warnings, runState, stopWhenIdle, lastActivity
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
        try container.encode(runState, forKey: .runState)
        try container.encode(stopWhenIdle, forKey: .stopWhenIdle)
        try container.encode(lastActivity?.formatted(.iso8601), forKey: .lastActivity)
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
        state = (workspace.state ?? .preparing).name
        runState = workspace.resolvedRunState.rawValue
        stopWhenIdle = workspace.stopsWhenIdle
        lastActivity = workspace.lastActivity
    }

    // The Site screen shows the pin in place of this note. A stopped workspace can also have "Stop
    // when idle" off, so the note names the setting and not a state.
    static func stateText(of workspace: WorkspaceInfo) -> String {
        workspace.stopsWhenIdle ? workspace.stateText : "\(workspace.stateText) (Stop when idle: off)"
    }

    // The same words as the sheet of the old workspaces, for example "2 hours ago".
    static func activityText(_ date: Date?, now: Date = .now) -> String {
        date.map { WorkspaceActivity.age(of: $0, now: now) } ?? "no activity"
    }

    var json: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}
