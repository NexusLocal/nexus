extension NexusRequest {
    // For the activity log. A request can hold a password, the settings of PHP or a key of a .env
    // file. So only these requests name their values. All others show only their name.
    public var activitySummary: String {
        switch self {
        case .start(let service): "start \(service)"
        case .stop(let service): "stop \(service)"
        case .restart(let service): "restart \(service)"
        case .setPort(let service, let port): "setPort \(service) \(port)"
        case .install(let name, let line): "install \(name) \(line)"
        case .remove(let name, let line): "remove \(name) \(line)"
        case .removeSite(let host): "removeSite \(host)"
        case .editSite(let host, _): "editSite \(host)"
        case .restartApp(let host, let workspace): "restartApp \(host)\(workspace.map { " \($0)" } ?? "")"
        case .setAccount(let instance, _): "setAccount \(instance)"
        case .retryWorkspace(let host, let name): "retryWorkspace \(host) \(name)"
        case .removeWorkspace(let host, let name, _): "removeWorkspace \(host) \(name)"
        case .stopTask(let id): "stopTask \(id)"
        default: Mirror(reflecting: self).children.first?.label ?? "\(self)"
        }
    }

    // nexusd answers these questions many times a minute. They only matter when they fail.
    public var onlyReads: Bool {
        switch self {
        case .status, .available, .installed, .rootCertificate, .hosts, .sites, .siteDefaults, .extensions, .modules,
             .customSettings, .databases, .databaseSizes, .sourceDatabases, .workspaceEnv, .backgroundPreset,
             .workspaceSettings, .dumps, .probe, .tool:
            true
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
        default: "done"
        }
    }

    public var failed: Bool {
        switch self {
        case .failure, .portInUse, .invalidSettings: true
        default: false
        }
    }
}
