import Foundation

// The check of the dump file of a WordPress site (owner, 2026-11-09, docs/dump-url-rewrite.md).
// Nexus reads the whole file once, without a load. It finds the tables with the prefix of the
// site, the live URLs and the number of links, and the tables that WP-CLI must change after the
// load. The result fits the file only while the size and the date of the file stay the same. A new
// dump of the same name gets the check again before the next workspace.
public struct WordPressDumpCheck: Codable, Sendable, Hashable {
    public let file: String
    public let size: Int64
    public let modified: Double
    public let prefix: String
    public let addedURLs: [String]
    public let home: String?
    public let siteURL: String?
    public let isNetwork: Bool
    public let networkDomain: String?
    public let links: Int
    public let uncertainTables: [String]
    public let uncertainLinks: Int
    // The order of the columns of the posts tables in the main database, for a dump without
    // CREATE TABLE.
    public let postsColumns: [String: [String]]
    public let problem: String?

    public init(
        file: String,
        size: Int64,
        modified: Double,
        prefix: String,
        addedURLs: [String],
        home: String? = nil,
        siteURL: String? = nil,
        isNetwork: Bool = false,
        networkDomain: String? = nil,
        links: Int = 0,
        uncertainTables: [String] = [],
        uncertainLinks: Int = 0,
        postsColumns: [String: [String]] = [:],
        problem: String? = nil
    ) {
        self.file = file
        self.size = size
        self.modified = modified
        self.prefix = prefix
        self.addedURLs = addedURLs
        self.home = home
        self.siteURL = siteURL
        self.isNetwork = isNetwork
        self.networkDomain = networkDomain
        self.links = links
        self.uncertainTables = uncertainTables
        self.uncertainLinks = uncertainLinks
        self.postsColumns = postsColumns
        self.problem = problem
    }

    public func fits(file: String, size: Int64, modified: Double, prefix: String, addedURLs: [String]) -> Bool {
        self.file == file && self.size == size && abs(self.modified - modified) < 0.001 && self.prefix == prefix && self.addedURLs == addedURLs
    }

    // The URL that WordPress uses, then the added URLs. siteurl counts only when the rule of home
    // does not cover it.
    public var liveURLs: [String] {
        var urls: [String] = []

        for url in [home, siteURL].compactMap({ $0 }) + addedURLs where !urls.contains(where: { WordPressURL.same($0, url) }) {
            urls.append(url)
        }

        if let home, let siteURL, Self.suffix(of: siteURL, below: home) != nil {
            urls.removeAll { WordPressURL.same($0, siteURL) && !WordPressURL.same($0, home) }
        }

        return urls
    }

    // home goes to the home of the workspace, and siteurl to its siteurl. Usually siteurl is home
    // with a path such as /wp. Then the rule of home covers both.
    public func rules(home newHome: String, siteURL newSiteURL: String) -> [LiveURLRule] {
        var rules: [LiveURLRule] = []

        if let home {
            rules.append(LiveURLRule(from: home, to: newHome))
        }

        if let siteURL, home.map({ !WordPressURL.same($0, siteURL) }) ?? true {
            let suffix = home.flatMap { Self.suffix(of: siteURL, below: $0) }
            let covered = suffix.map { Self.trimmed(newSiteURL) == Self.trimmed(newHome) + $0 } ?? false

            if !covered {
                rules.append(LiveURLRule(from: siteURL, to: newSiteURL))
            }
        }

        for url in addedURLs where !rules.contains(where: { WordPressURL.same($0.from, url) }) {
            rules.append(LiveURLRule(from: url, to: newHome))
        }

        return rules
    }

    // The URLs for WP-CLI after the load, also with and without www.
    public var fallbackURLs: [String] {
        liveURLs.flatMap { url -> [String] in
            guard let parts = URLParts(url) else {
                return [url]
            }

            let other = parts.host.hasPrefix("www.") ? String(parts.host.dropFirst(4)) : "www.\(parts.host)"
            let otherURL = "\(parts.scheme ?? "https")://\(parts.port.map { "\(other):\($0)" } ?? other)\(parts.path)"

            return [url, otherURL]
        }
    }

    // /wp for https://shop.com/wp below https://shop.com.
    public static func suffix(of url: String, below base: String) -> String? {
        guard let parts = URLParts(url), let baseParts = URLParts(base), parts.host == baseParts.host, parts.port == baseParts.port else {
            return nil
        }

        guard parts.path.hasPrefix(baseParts.path + "/") else {
            return nil
        }

        return String(parts.path.dropFirst(baseParts.path.count))
    }

    private static func trimmed(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)

        while text.hasSuffix("/") {
            text.removeLast()
        }

        return text
    }
}

extension WordPressURL {
    // The host in small letters, for the check of each table before WP-CLI.
    public static func host(of url: String) -> String? {
        URLParts(url)?.host
    }

    // A live URL that the user adds: http or https, a host, and maybe a port and a path.
    public static func liveURL(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)

        guard let parts = URLParts(text), parts.isWeb, parts.host.contains(".") || parts.host == "localhost" else {
            return nil
        }

        return "\(parts.scheme ?? "https")://\(parts.port.map { "\(parts.host):\($0)" } ?? parts.host)\(parts.path)"
    }
}
