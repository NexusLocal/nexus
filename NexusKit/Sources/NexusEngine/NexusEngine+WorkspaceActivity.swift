import Foundation
import NexusCore
import NexusWorkspaces

// A workspace with what lastActivity(of:) needs: the key of its record, its hosts and the root of
// its repository. Item 3c of group 3 finds its own times in memory with key and workspace.name.
struct TrackedWorkspace: Sendable {
    let key: String
    let workspace: Workspace
    let hosts: [String]
    let repository: String?

    var owner: String {
        NexusEngine.processOwner(key: key, workspace: workspace.name)
    }
}

// The last activity of each workspace (owner, 2026-11-15). It is the newest of the last page in
// the access logs of its hosts, the git times of its worktree and the last command or request that
// nexusd keeps in memory. Each source costs one stat. So the site list can hold the time.
extension NexusEngine {
    // A request through a link writes no line in the access log of the site. So nexusd keeps the time
    // of such a page in memory (group 4, 4b).
    func lastActivity(of tracked: TrackedWorkspace) -> WorkspaceActivity? {
        let commands = activityTimes[tracked.owner].map { [WorkspaceActivity(date: $0, source: .command)] } ?? []
        let linkPages = linkPageTimes[tracked.owner].map { [WorkspaceActivity(date: $0, source: .page)] } ?? []

        return WorkspaceActivity.newest(pageActivity(of: tracked.hosts) + Self.gitActivity(of: tracked) + commands + linkPages)
    }

    func trackedWorkspaces(key: String, sites: [Site], state: EngineState) -> [TrackedWorkspace] {
        let repository = sites.first.flatMap { ProjectFolder.repository(of: $0)?.root }

        return (state.worktrees[key]?.workspaces ?? []).map { workspace in
            TrackedWorkspace(key: key, workspace: workspace, hosts: workspace.hosts(of: sites, tld: state.tld), repository: repository)
        }
    }

    // nginx writes each request at its end. An empty log holds no request.
    private func pageActivity(of hosts: [String]) -> [WorkspaceActivity] {
        hosts.compactMap { host in
            let attributes = try? FileManager.default.attributesOfItem(atPath: paths.siteLog(host).path(percentEncoded: false))
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

            guard size > 0, let date = attributes?[.modificationDate] as? Date else {
                return nil
            }

            return WorkspaceActivity(date: date, source: .page)
        }
    }

    // git writes logs/HEAD at each commit, checkout and reset. It writes the index at each add and
    // commit. commondir comes from git worktree add.
    private static func gitActivity(of tracked: TrackedWorkspace) -> [WorkspaceActivity] {
        guard let admin = ProjectFolder.adminFolder(ofWorktree: tracked.workspace.worktree, repository: tracked.repository) else {
            return []
        }

        let fileManager = FileManager.default
        let change = ["logs/HEAD", "index"].compactMap { file in
            (try? fileManager.attributesOfItem(atPath: (admin as NSString).appendingPathComponent(file)))?[.modificationDate] as? Date
        }.max()
        let created = (try? fileManager.attributesOfItem(atPath: (admin as NSString).appendingPathComponent("commondir")))?[.creationDate] as? Date

        return WorkspaceActivity.git(change: change, created: created)
    }

    // One rule for the sheet, nexus workspace list --old and the notifications. So they name the
    // same old workspaces.
    func oldTrackedWorkspaces(key: String, sites: [Site], state: EngineState, days: Int, now: Date) -> [(tracked: TrackedWorkspace, activity: WorkspaceActivity)] {
        trackedWorkspaces(key: key, sites: sites, state: state).compactMap { tracked in
            guard let activity = lastActivity(of: tracked), OldWorkspaces.isOld(activity.date, days: days, now: now) else {
                return nil
            }

            return (tracked, activity)
        }
    }
}
