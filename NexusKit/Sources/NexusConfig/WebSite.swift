import Foundation
import NexusCore

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsafePath(String)
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .unsafePath(let path):
            "Nexus cannot use \(path) in a configuration file. The path has a character that the web servers read in a special way: a quote, a backslash, $, ;, *, ?, a brace, a bracket or a line break. Rename the folder."
        case .socketPathTooLong(let path):
            "The socket path \(path) is longer than the 103 bytes that macOS permits."
        }
    }
}

// A site as the web servers see it: every name, the folders and the files that it needs.
public struct WebSite: Sendable, Equatable {
    public let hosts: [String]
    public let documentRoot: URL
    public let server: WebServer
    public let phpSocket: URL
    public let certificate: URL
    public let key: URL
    public let accessLog: URL

    public init(hosts: [String], documentRoot: URL, server: WebServer, phpSocket: URL, certificate: URL, key: URL, accessLog: URL) {
        self.hosts = hosts
        self.documentRoot = documentRoot
        self.server = server
        self.phpSocket = phpSocket
        self.certificate = certificate
        self.key = key
        self.accessLog = accessLog
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
        let path = url.path(percentEncoded: false)

        guard path.utf8.count <= 103 else {
            throw ConfigError.socketPathTooLong(path)
        }

        return try quoted(url, prefix: prefix)
    }
}
