import Foundation

// The site URL of WordPress and the URL of Nexus (Phase 4, 3d).
public enum WordPressURL {
    // The same scheme, host, port and path. The case of the host, the standard port of the scheme
    // and a slash at the end do not count.
    public static func same(_ first: String, _ second: String) -> Bool {
        guard let firstParts = Parts(first), let secondParts = Parts(second) else {
            return first == second
        }

        return firstParts == secondParts
    }

    // The host with the port when the port is not the standard port of the scheme. A network keeps
    // this value in wp_blogs, wp_site and DOMAIN_CURRENT_SITE.
    public static func domain(of url: String) -> String? {
        Parts(url).map { parts in parts.port.map { "\(parts.host):\($0)" } ?? parts.host }
    }

    // The six forms of the old URL that wp search-replace changes: https and http, each plain,
    // URL-encoded and with the escaped slashes of JSON (A.4). The https form comes first. So the
    // pass of the http form never finds the new URL that the pass before it wrote.
    public static func replacements(from old: String, to new: String, token: String = newToken()) -> [TextReplacement] {
        let oldAddress = trimmed(withoutScheme(old))
        let newURL = trimmed(new)
        let forms: [(String) -> String] = [
            { $0 },
            { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0 },
            { $0.replacingOccurrences(of: "/", with: "\\/") },
        ]

        return forms.flatMap { form in
            ["https", "http"].flatMap { scheme in
                TextReplacement.passes(search: form("\(scheme)://\(oldAddress)"), replace: form(newURL), token: token)
            }
        }
    }

    // The text of the passes without the scheme.
    static func address(_ url: String) -> String {
        trimmed(withoutScheme(url))
    }

    public static func newToken() -> String {
        "nexus-keep-\(UUID().uuidString.lowercased())"
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func withoutScheme(_ url: String) -> String {
        url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
    }

    private static func trimmed(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)

        while text.hasSuffix("/") {
            text.removeLast()
        }

        return text
    }

    private struct Parts: Equatable {
        let scheme: String
        let host: String
        let port: Int?
        let path: String

        init?(_ text: String) {
            guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else {
                return nil
            }

            let standardPort = ["https": 443, "http": 80][scheme]

            self.scheme = scheme
            self.host = host
            port = components.port == standardPort ? nil : components.port
            path = WordPressURL.trimmed(components.path)
        }
    }
}

// One pass of wp search-replace. Only a pass that counts changes a URL. The others keep the places
// that have the new URL already.
public struct TextReplacement: Equatable, Sendable {
    public let search: String
    public let replace: String
    public let counts: Bool

    // A new text that starts with the old text, for example https://shop.test:8443 after
    // https://shop.test, needs three passes. The places that have the new text already get a token
    // first, and the new text again after the change. Without them, they would get
    // https://shop.test:8443:8443. A regular expression could skip them too, but WP-CLI then reads
    // every row of every table.
    static func passes(search: String, replace: String, token: String) -> [TextReplacement] {
        guard search != replace else {
            return []
        }

        let change = TextReplacement(search: search, replace: replace, counts: true)

        guard replace.hasPrefix(search) else {
            return [change]
        }

        return [
            TextReplacement(search: replace, replace: token, counts: false),
            change,
            TextReplacement(search: token, replace: replace, counts: false),
        ]
    }
}

// What the button "Change the URLs" changes (Phase 4, 3d). databaseFrom is the home option when it
// differs from the URL of Nexus. configFrom is WP_HOME of wp-config.php or of the .env of Bedrock
// when it differs. The app sends the plan back, and nexusd refuses when the plan is not true any
// more.
public struct WordPressURLPlan: Codable, Sendable, Equatable {
    public let to: String
    public let databaseFrom: String?
    public let configFrom: String?
    public let configFile: String?

    public init(to: String, databaseFrom: String? = nil, configFrom: String? = nil, configFile: String? = nil) {
        self.to = to
        self.databaseFrom = databaseFrom
        self.configFrom = configFrom
        self.configFile = configFile
    }

    // The links in the database can have both old URLs. WordPress made them with WP_HOME when it
    // was set, and the home option can still have the URL of production. Each URL gets the https
    // and the http forms. So two URLs that differ only in the scheme need one set of passes. A
    // longer URL goes first, so a shorter one that starts it does not change it halfway.
    public var oldURLs: [String] {
        var urls: [String] = []

        for url in [databaseFrom, configFrom].compactMap({ $0 }) where !urls.contains(where: { WordPressURL.address($0) == WordPressURL.address(url) }) {
            urls.append(url)
        }

        return urls.sorted { $0.count > $1.count }
    }
}

extension WordPressURL {
    // Bedrock serves WordPress from /wp. Its installer writes that folder into the home option,
    // while WP_HOME gives the address of the site. So the site address is the home option without
    // the folder of WP_SITEURL.
    public static func siteAddress(home: String, isBedrock: Bool, config: WordPressConfig) -> String {
        guard isBedrock else {
            return home
        }

        var folder = "/wp"

        if let configHome = config.home, let siteURL = config.siteURL, siteURL.hasPrefix(trimmed(configHome)) {
            folder = String(siteURL.dropFirst(trimmed(configHome).count))
        }

        let address = trimmed(home)

        guard !folder.isEmpty, folder != "/", address.hasSuffix(trimmed(folder)) else {
            return address
        }

        return String(address.dropLast(trimmed(folder).count))
    }
}

// The last change of the URLs of a site. "Undo…" puts back the dump and the old line of WP_HOME.
// It stays until the trash removes the dump. dump is a path in the trash, or nil when only WP_HOME
// changed. networkDomain is the old domain of a network, when DOMAIN_CURRENT_SITE changed.
public struct WordPressURLChange: Codable, Sendable, Equatable {
    public let plan: WordPressURLPlan
    public let database: String
    public let instance: String
    public let dump: String?
    public let replacements: Int
    public let date: Date
    public var expires: Date
    public let networkDomain: String?

    public init(plan: WordPressURLPlan, database: String, instance: String, dump: String?, replacements: Int, date: Date, expires: Date, networkDomain: String? = nil) {
        self.plan = plan
        self.database = database
        self.instance = instance
        self.dump = dump
        self.replacements = replacements
        self.date = date
        self.expires = expires
        self.networkDomain = networkDomain
    }
}
