import Foundation

public enum WebServer: String, Codable, Sendable, CaseIterable {
    case nginx
    case apache

    public var displayName: String {
        self == .nginx ? "nginx" : "Apache"
    }
}

// A site that the user added. The host is the first name of the site and its identity.
public struct Site: Codable, Sendable, Equatable {
    public var host: String
    public var folder: URL
    public var aliases: [String]
    public var php: String
    public var server: WebServer

    public init(host: String, folder: URL, aliases: [String] = [], php: String, server: WebServer = .nginx) {
        self.host = host
        self.folder = folder
        self.aliases = aliases
        self.php = php
        self.server = server
    }

    public var hosts: [String] {
        [host] + aliases
    }

    // The document root is public/ when the folder has one, else the folder itself (D33).
    public var documentRoot: URL {
        let publicFolder = folder.appending(path: "public", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: publicFolder.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
            return publicFolder
        }

        return folder
    }
}

// The webserver and the PHP version of a new site (D59). A PHP version of nil is the newest
// installed one.
public struct SiteDefaults: Codable, Sendable, Equatable {
    public var server: WebServer
    public var php: String?

    public init(server: WebServer = .nginx, php: String? = nil) {
        self.server = server
        self.php = php
    }

    public var summary: String {
        "A new site gets \(server.displayName) and \(php.map { "PHP \($0)" } ?? "the newest installed PHP version")."
    }
}

// One row of the sidebar in the order of the user (D58): a group or a site outside a group. A
// group keeps its sites in order. A site of a parked folder shows in that folder, unless it is in
// a group.
public enum SiteLayoutEntry: Codable, Sendable, Equatable {
    case site(String)
    case group(name: String, hosts: [String])
}

extension [SiteLayoutEntry] {
    // The groups and the sites outside a group, in the order of this layout (D58). nexusd and the
    // app both use it. A host that is not in hosts is left out, and each host has one place. A
    // host of outside that the layout does not name comes at the end, in the order of outside. A
    // host that is not in outside, for example a site of a parked folder, can only be in a group.
    public func normalized(hosts: Set<String>, outside: [String]) -> [SiteLayoutEntry] {
        let outside = outside.filter(hosts.contains)
        let outsideHosts = Set(outside)
        var placed: Set<String> = []
        var layout: [SiteLayoutEntry] = []

        for entry in self {
            switch entry {
            case .site(let host):
                if outsideHosts.contains(host), placed.insert(host).inserted {
                    layout.append(entry)
                }
            case .group(let name, let members):
                var kept: [String] = []
                for host in members where hosts.contains(host) && placed.insert(host).inserted {
                    kept.append(host)
                }
                layout.append(.group(name: name, hosts: kept))
            }
        }

        return layout + outside.filter { !placed.contains($0) }.map(SiteLayoutEntry.site)
    }

    // Takes a host out of the layout, or moves it to the end of a group. A group that does not
    // exist yet comes at the end. Two group names that differ only in capitals name one group, so
    // the host goes to the group that exists and keeps its name.
    public func moving(_ host: String, toGroup group: String?) -> [SiteLayoutEntry] {
        var moved: [SiteLayoutEntry] = compactMap { entry in
            switch entry {
            case .site(let other):
                return other == host ? nil : entry
            case .group(let name, let hosts):
                return .group(name: name, hosts: hosts.filter { $0 != host })
            }
        }

        guard let group else {
            return moved
        }

        if let index = moved.firstIndex(where: { $0.groupName?.lowercased() == group.lowercased() }), case .group(let name, let hosts) = moved[index] {
            moved[index] = .group(name: name, hosts: hosts + [host])
        } else {
            moved.append(.group(name: group, hosts: [host]))
        }

        return moved
    }
}

extension SiteLayoutEntry {
    public var groupName: String? {
        if case .group(let name, _) = self {
            return name
        }

        return nil
    }
}

// A parked folder. Each subfolder is a site with the host <subfolder>.<tld>.
public struct ParkedFolder: Codable, Sendable, Equatable {
    public var folder: URL
    public var php: String
    public var server: WebServer

    public init(folder: URL, php: String, server: WebServer = .nginx) {
        self.folder = folder
        self.php = php
        self.server = server
    }

    public func sites(tld: String, using fileManager: FileManager = .default) -> [Site] {
        let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        return children
            .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { child in
                guard let host = try? HostName.validated("\(HostName.label(from: child.lastPathComponent)).\(tld)") else {
                    return nil
                }
                return Site(host: host, folder: child, php: php, server: server)
            }
            .sorted { $0.host < $1.host }
    }
}
