extension NexusRequest {
    // For the activity log. A request can hold a password, the settings of PHP or a key of a .env
    // file. So only these requests name their values. All others show only their name.
    public var activitySummary: String {
        switch self {
        case .start(let service): "start \(service)"
        case .stop(let service): "stop \(service)"
        case .restart(let service): "restart \(service)"
        case .setPort(let service, let port): "setPort \(service) \(port)"
        case .setWebPorts(let http, let https): "setWebPorts \(http) \(https)"
        case .install(let name, let line): "install \(name) \(line)"
        case .remove(let name, let line): "remove \(name) \(line)"
        case .removeSite(let host): "removeSite \(host)"
        case .editSite(let host, _): "editSite \(host)"
        case .setSiteLines(let host, _): "setSiteLines \(host)"
        case .restartApp(let host, let workspace): "restartApp \(host)\(workspace.map { " \($0)" } ?? "")"
        case .setAccount(let instance, _): "setAccount \(instance)"
        case .retryWorkspace(let host, let name): "retryWorkspace \(host) \(name)"
        case .removeWorkspace(let host, let name, _): "removeWorkspace \(host) \(name)"
        case .removeWorkspaces(let host, let names): "removeWorkspaces \(host) \(names.joined(separator: " "))"
        case .stopWorkspace(let host, let name): "stopWorkspace \(host) \(name)"
        case .startWorkspace(let host, let name, let keepAwake): "startWorkspace \(host) \(name)\(keepAwake == true ? " --keep" : "")"
        case .setKeepAwake(let host, let name, let keepAwake): "setKeepAwake \(host) \(name) \(keepAwake)"
        case .stopTask(let id): "stopTask \(id)"
        case .createSite(let site): "createSite \(site.template.rawValue) \(site.name)"
        case .removeSiteLeftovers(let id): "removeSiteLeftovers \(id)"
        case .importSite(let site): "importSite \(site.name)"
        case .createDatabase(_, let name): "createDatabase \(name)"
        case .importDump(let request): "importDump \(request.name)\(request.existing.map { " \($0.rawValue)" } ?? "")"
        case .useNexus(let request): "useNexus \(request.host)\(request.copy ? " with a copy" : "")"
        case .startShare(let start): "startShare \(start.host)"
        case .stopShare(let host): "stopShare \(host)"
        case .stopAllShares(let appQuit): "stopAllShares\(appQuit ? " (quit)" : "")"
        case .rebuildShare(let host): "rebuildShare \(host)"
        case .connectOwnDomain(let domain): "connectOwnDomain \(domain)"
        case .clearLinkRequests(let host): "clearLinkRequests \(host ?? "all")"
        case .fromAgent(let agent, let request): "\(request.activitySummary) (\(agent))"
        default: Mirror(reflecting: self).children.first?.label ?? "\(self)"
        }
    }

    // The host and the workspace of a request of nexus, MCP or the app that names a workspace. Such
    // a request counts as activity (owner, 2026-11-15). A stop and a removal are no activity, so
    // they give nil.
    public var namedWorkspace: (host: String, name: String)? {
        switch self {
        case .databaseConnections(let host, let name?), .restartApp(let host, let name?), .retryWorkspace(let host, let name), .startWorkspace(let host, let name, _), .setKeepAwake(let host, let name, _):
            (host, name)
        case .serverDatabases(let target), .createDatabase(let target, _):
            Self.workspace(of: target)
        case .importDump(let request):
            Self.workspace(of: request.target)
        case .inspectDump(let inspection):
            Self.workspace(of: inspection.target)
        case .fromAgent(_, let request):
            request.namedWorkspace
        default:
            nil
        }
    }

    private static func workspace(of target: DatabaseTarget?) -> (host: String, name: String)? {
        guard case .workspace(let host, let name, _) = target else {
            return nil
        }

        return (host, name)
    }

    // nexusd answers these questions many times a minute. They only matter when they fail. They
    // also reach an older nexusd while the app waits for the new one (isSafeForAnOlderNexusd).
    public var onlyReads: Bool {
        switch self {
        case .status, .available, .installed, .rootCertificate, .hosts, .sites, .siteDefaults, .extensions, .modules,
             .customSettings, .siteLines, .databases, .databaseSizes, .sourceDatabases, .workspaceEnv, .siteDatabases, .databaseConnections, .serverDatabases, .wordPressSite, .backgroundPreset,
             .workspaceSettings, .oldWorkspaces, .dumps, .probe, .tool, .inspectBackup, .inspectDump, .serviceList, .tasks, .mailStatus, .siteMail, .useNexusInfo, .dumpList,
             .newDumps, .lastDumps, .dumpPlace, .dumpState, .requestDumps, .requestEntries, .shares, .sharePreview, .shareRequest, .checkOwnDomain:
            true
        case .fromAgent(_, let request):
            request.onlyReads
        case .lan(let enabled):
            enabled == nil
        case .tld(let value):
            value == nil
        default:
            false
        }
    }
}

extension NexusResponse {
    public var activitySummary: String {
        switch self {
        case .failure(let message): "failed: \(message)"
        case .stopped(let message): "stopped: \(message)"
        case .portInUse(let conflict): "port in use: \(conflict.description)"
        case .invalidSettings: "failed: the settings are not valid"
        case .invalidSiteLines: "failed: the lines are not valid"
        case .siteNotCreated(let failure): "failed: \(failure.message)"
        default: "done"
        }
    }

    public var failed: Bool {
        switch self {
        case .failure, .portInUse, .invalidSettings, .invalidSiteLines, .siteNotCreated: true
        default: false
        }
    }
}
