import Foundation

// One git worktree of a site (D40). worktree is the root of the worktree. folder is the project
// folder of the site in that worktree. For a site in a subfolder of the repository, these differ.
public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public var worktree: String
    public var folder: String
    public var branch: String?

    public var id: String { name }

    // The name goes into a host (D42), and a DNS label has a limit of 63 characters.
    static let longestName = 40

    public init(name: String, worktree: String, folder: String, branch: String? = nil) {
        self.name = name
        self.worktree = worktree
        self.folder = folder
        self.branch = branch
    }

    // D41: TICKET-123 becomes ticket-123. A second worktree with the same name gets a number,
    // because a name must be unique in a site.
    public static func name(forFolder folder: String, taken: Set<String>) -> String {
        let allowed = String(folder.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
        let trimmed = allowed.prefix(longestName).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = trimmed.isEmpty ? "workspace" : trimmed
        var candidate = name
        var number = 2

        while taken.contains(candidate) {
            candidate = "\(name)-\(number)"
            number += 1
        }

        return candidate
    }
}

extension Workspace {
    // sites holds the sites that share the project of this workspace.
    public func hosts(of sites: [Site], tld: String) -> [String] {
        var seen: Set<String> = []

        return sites.flatMap(\.hosts)
            .map { HostName.workspaceHost($0, workspace: name, tld: tld) }
            .filter { seen.insert($0).inserted }
    }

    // A workspace runs as a site of its own, with the PHP and the webserver of its project.
    public func site(of sites: [Site], tld: String) -> Site? {
        guard let main = sites.first else {
            return nil
        }

        let hosts = hosts(of: sites, tld: tld)
        return Site(host: hosts[0], folder: URL(filePath: folder, directoryHint: .isDirectory), aliases: Array(hosts.dropFirst()), php: main.php, server: main.server, node: main.node)
    }
}

// What Nexus knows about the worktrees of a site. listed holds the worktrees that were there at
// the last check, also those without a workspace. So only a new worktree gets a workspace.
public struct SiteWorktrees: Codable, Sendable, Equatable {
    public var listed: Set<String>
    public var workspaces: [Workspace]

    public init(listed: Set<String> = [], workspaces: [Workspace] = []) {
        self.listed = listed
        self.workspaces = workspaces
    }
}
