import Foundation

public enum WebServer: String, Codable, Sendable, CaseIterable {
    case nginx
    case apache
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
