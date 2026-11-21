import Foundation

// A Debug build is Nexus Dev. It has its own bundle id, data folder, launchd jobs, helper, ports,
// dev domain, root CA and line in ~/.zshrc. So it runs next to the installed Nexus, and a change
// in one does not reach the other. A Release build keeps the names of the installed Nexus, so its
// updates reach every user as before.
//
// The bundle id decides, not the DEBUG flag. nexusd, the helper and the nexus command each have
// an id in their own executable, also when a link in the bin folder starts the command. The tests
// run as the installed Nexus.
public enum NexusVariant: Sendable {
    case release
    case dev

    public static let current = variant(for: Bundle.main.bundleIdentifier)

    public static func variant(for bundleIdentifier: String?) -> NexusVariant {
        let dev = NexusVariant.dev.bundleIdentifier

        guard let bundleIdentifier else {
            return .release
        }

        if bundleIdentifier == dev || bundleIdentifier.hasPrefix("\(dev).") {
            return .dev
        }

        return .release
    }

    // The installed Nexus uses the ports below 30000, also for its apps and workspaces. The services
    // of Nexus Dev sit 30000 above those of Nexus. Its apps and workspaces come after them, below
    // 49152, where macOS starts to give out ports to outgoing connections.
    static let devPortShift = 30_000

    public var name: String {
        switch self {
        case .release: "Nexus"
        case .dev: "Nexus Dev"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .release: "nl.roodfruit.nexus"
        case .dev: "nl.roodfruit.nexus.dev"
        }
    }

    public var tld: String {
        switch self {
        case .release: "test"
        case .dev: "internal"
        }
    }

    // The name of the MCP server and of its entry in the settings of an agent. So both apps can be
    // on in one agent.
    public var mcpServerName: String {
        switch self {
        case .release: "nexus"
        case .dev: "nexus-dev"
        }
    }

    public func port(_ port: Int) -> Int {
        switch self {
        case .release: port
        case .dev: port + Self.devPortShift
        }
    }

    public var firstAppPort: Int {
        switch self {
        case .release: 19_000
        case .dev: 41_000
        }
    }

    public var firstWorkspacePort: Int {
        switch self {
        case .release: 20_000
        case .dev: 42_000
        }
    }

    // The ports of the links: the share block and the metrics server of cloudflared (group 4). They
    // are below the app ports and far from 20241 to 20245, the default metrics ports of cloudflared.
    public var firstSharePort: Int {
        switch self {
        case .release: 18_000
        case .dev: 40_000
        }
    }

    // The tunnel of the own domain (group 4, 4h). Each Mac and each variant has its own tunnel. The
    // computer name becomes a-z, 0-9 and -. For example "Jo’s MacBook Pro" gives nexus-jos-macbook-pro.
    public func tunnelName(computer: String) -> String {
        let prefix = self == .dev ? "nexus-dev" : "nexus"
        return "\(prefix)-\(Self.slug(computer))"
    }

    // At most 40 characters. An empty slug is mac.
    static func slug(_ name: String) -> String {
        let label = HostName.label(from: name.filter { $0 != "'" && $0 != "’" })
        let trimmed = String(label.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "mac" : trimmed
    }
}
