import NexusCore

// The site and its workspaces as places of the Logs screen (group 7), for read_log, nexus logs and
// the web page of the logs.
extension SiteInfo {
    public var logPlaces: [LogPlace] {
        LogPlace.places(of: LogPlace.Source(
            hosts: hosts,
            folder: folder,
            kind: kind,
            projectType: projectType,
            php: php,
            appLog: app?.log,
            workspaces: (workspaces ?? []).map { workspace in
                LogPlace.Source.Workspace(name: workspace.name, hosts: workspace.hosts ?? [], folder: workspace.folder, worktree: workspace.worktree, appLog: workspace.app?.log)
            }
        ))
    }
}
