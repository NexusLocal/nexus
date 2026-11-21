// The screen that a click on a notification of the app opens (owner, 2026-11-14). macOS keeps
// only property list values in the userInfo of a notification. So each value is a string. The
// target of a workspace or a database is also the scroll id of its row. The old workspaces of a
// site open the Site screen and the sheet of its old workspaces. A public link opens the Site
// screen of its site. The link of a workspace also marks the row of the workspace (group 4).
public enum NotificationTarget: Hashable, Sendable {
    case workspace(site: String, name: String)
    case service(id: String)
    case database(instance: String, name: String)
    case mail(id: String, tag: String?)
    case site(host: String)
    case oldWorkspaces(site: String)
    case publicLink(host: String)

    private static let targetKey = "target"
    private static let siteKey = "site"
    private static let workspaceKey = "workspace"
    private static let serviceKey = "service"
    private static let databaseKey = "database"
    private static let mailKey = "mail"
    private static let tagKey = "tag"
    private static let oldWorkspacesKey = "oldWorkspaces"
    private static let publicLinkKey = "publicLink"

    public init?(userInfo: [AnyHashable: Any]) {
        func value(_ key: String) -> String? {
            userInfo[key] as? String
        }

        switch value(Self.targetKey) {
        case Self.workspaceKey:
            guard let site = value(Self.siteKey), let name = value(Self.workspaceKey) else {
                return nil
            }

            self = .workspace(site: site, name: name)
        case Self.serviceKey:
            guard let id = value(Self.serviceKey) else {
                return nil
            }

            self = .service(id: id)
        case Self.databaseKey:
            guard let instance = value(Self.serviceKey), let name = value(Self.databaseKey) else {
                return nil
            }

            self = .database(instance: instance, name: name)
        case Self.mailKey:
            guard let id = value(Self.mailKey) else {
                return nil
            }

            guard userInfo[Self.tagKey] == nil || value(Self.tagKey) != nil else {
                return nil
            }

            self = .mail(id: id, tag: value(Self.tagKey))
        case Self.siteKey:
            guard let host = value(Self.siteKey) else {
                return nil
            }

            self = .site(host: host)
        case Self.oldWorkspacesKey:
            guard let host = value(Self.siteKey) else {
                return nil
            }

            self = .oldWorkspaces(site: host)
        case Self.publicLinkKey:
            guard let host = value(Self.siteKey) else {
                return nil
            }

            self = .publicLink(host: host)
        default:
            return nil
        }
    }

    public var userInfo: [String: String] {
        switch self {
        case .workspace(let site, let name):
            return [Self.targetKey: Self.workspaceKey, Self.siteKey: site, Self.workspaceKey: name]
        case .service(let id):
            return [Self.targetKey: Self.serviceKey, Self.serviceKey: id]
        case .database(let instance, let name):
            return [Self.targetKey: Self.databaseKey, Self.serviceKey: instance, Self.databaseKey: name]
        case .mail(let id, let tag):
            var userInfo = [Self.targetKey: Self.mailKey, Self.mailKey: id]
            userInfo[Self.tagKey] = tag
            return userInfo
        case .site(let host):
            return [Self.targetKey: Self.siteKey, Self.siteKey: host]
        case .oldWorkspaces(let host):
            return [Self.targetKey: Self.oldWorkspacesKey, Self.siteKey: host]
        case .publicLink(let host):
            return [Self.targetKey: Self.publicLinkKey, Self.siteKey: host]
        }
    }
}
