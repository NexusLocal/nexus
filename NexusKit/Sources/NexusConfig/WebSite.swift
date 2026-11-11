import Foundation
import NexusCore

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsafePath(String)

    public var description: String {
        switch self {
        case .unsafePath(let path):
            "Nexus cannot use \(path) in a configuration file. The path has a character that the web servers read in a special way: a quote, a backslash, $, ;, *, ?, a brace, a bracket or a line break. Rename the folder."
        }
    }
}

// What answers the requests of a site. PHP runs in nginx through php-fpm, or in Apache behind
// nginx. A Node.js app that Nexus starts listens on a port of this Mac. A proxy site gets its
// requests from nginx at its address. A notice is a page of nginx that says why the site runs no
// PHP, for example a workspace of WordPress that Nexus cannot isolate yet (Phase 4, 3a).
public enum WebBackend: Sendable, Equatable {
    case php(server: WebServer, documentRoot: URL, socket: URL)
    case app(port: Int, framework: NodeFramework?)
    case proxy(address: String)
    case notice(title: String, text: String)
}

// A site as the web servers see it: every name, the backend and the files that it needs. A
// WordPress site gets the rules of WordPress in nginx.
public struct WebSite: Sendable, Equatable {
    public let hosts: [String]
    public let backend: WebBackend
    public let certificate: URL
    public let key: URL
    public let accessLog: URL
    public let project: PHPProjectType
    // A WordPress network in subfolders needs the rewrites of WordPress in nginx (Phase 4, 3g).
    public let network: WordPressNetworkKind?

    public init(hosts: [String], backend: WebBackend, certificate: URL, key: URL, accessLog: URL, project: PHPProjectType = .other, network: WordPressNetworkKind? = nil) {
        self.hosts = hosts
        self.backend = backend
        self.certificate = certificate
        self.key = key
        self.accessLog = accessLog
        self.project = project
        self.network = network
    }

    public var isWordPress: Bool {
        project.isWordPress
    }

    public var usesApache: Bool {
        if case .php(.apache, _, _) = backend {
            return true
        }

        return false
    }
}

public enum WebConfigPath {
    // Checks a site folder when the user adds it, so one bad folder does not block the
    // configuration of every other site later.
    public static func validate(_ url: URL) throws {
        _ = try ConfigText.quoted(url)
    }
}

enum ConfigText {
    private static let unsafeCharacters = CharacterSet(charactersIn: "\"\\$;{}*?[]").union(.controlCharacters).union(.newlines)

    // nginx reads a $ in a quoted value as a variable. Apache reads *, ? and [ ] in a Directory
    // path as a pattern. Both servers end a value at a quote. So a path with one of these
    // characters is refused, not escaped.
    static func quoted(_ url: URL, prefix: String = "") throws -> String {
        let path = url.path(percentEncoded: false)

        guard path.rangeOfCharacter(from: unsafeCharacters) == nil else {
            throw ConfigError.unsafePath(path)
        }

        return "\"\(prefix)\(path)\""
    }

    static func socket(_ url: URL, prefix: String = "") throws -> String {
        try SocketError.checkPath(url)
        return try quoted(url, prefix: prefix)
    }
}
