import Foundation

// The database and the addresses of a WordPress site (Phase 4, 3b). The probe reads them from
// wp-config.php without a run of the file, because wp-config.php loads all of WordPress at its end.
// A value that is not a literal gives nil, for example getenv('DB_NAME'). Bedrock gives these
// values in its .env.
public struct WordPressConfig: Codable, Sendable, Equatable {
    public var database: String?
    public var user: String?
    public var password: String?
    public var host: String?
    public var tablePrefix: String?
    public var home: String?
    public var siteURL: String?
    public var multisite: Bool?
    public var subdomainInstall: Bool?
    public var domainCurrentSite: String?

    public init(
        database: String? = nil,
        user: String? = nil,
        password: String? = nil,
        host: String? = nil,
        tablePrefix: String? = nil,
        home: String? = nil,
        siteURL: String? = nil,
        multisite: Bool? = nil,
        subdomainInstall: Bool? = nil,
        domainCurrentSite: String? = nil
    ) {
        self.database = database
        self.user = user
        self.password = password
        self.host = host
        self.tablePrefix = tablePrefix
        self.home = home
        self.siteURL = siteURL
        self.multisite = multisite
        self.subdomainInstall = subdomainInstall
        self.domainCurrentSite = domainCurrentSite
    }

    // WordPress accepts only these characters in the prefix of its tables. Nexus puts the prefix
    // into a query, so another prefix gives none.
    public var safeTablePrefix: String? {
        tablePrefix.flatMap { $0.wholeMatch(of: /[A-Za-z0-9_]+/) == nil ? nil : $0 }
    }

    public var address: DatabaseAddress? {
        host.map(DatabaseAddress.init(dbHost:))
    }
}

// DB_HOST as wpdb::parse_db_host reads it: a host, host:port, host:/socket or [IPv6]:port. A host
// without a port uses port 3306. mysqli uses a socket for the host localhost, also with a port. So
// localhost does not reach a Nexus instance on its port (A.0).
public enum DatabaseAddress: Equatable, Sendable {
    case tcp(host: String, port: Int)
    case socket(path: String?)

    public static let standardPort = 3306

    public init(dbHost: String) {
        let text = dbHost.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let rest = text[text.index(after: close)...]
            self = .tcp(host: String(text[text.index(after: text.startIndex)..<close]), port: rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? Self.standardPort : Self.standardPort)
            return
        }

        guard text.filter({ $0 == ":" }).count <= 1 else {
            self = .tcp(host: text, port: Self.standardPort)
            return
        }

        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let host = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""

        if rest.hasPrefix("/") {
            self = .socket(path: rest)
            return
        }

        guard !host.isEmpty, host.lowercased() != "localhost" else {
            self = .socket(path: nil)
            return
        }

        self = .tcp(host: host, port: Int(rest) ?? Self.standardPort)
    }

    // The port on this Mac, or nil for a socket or another host.
    public var localPort: Int? {
        guard case .tcp(let host, let port) = self, ["127.0.0.1", "::1"].contains(host) else {
            return nil
        }

        return port
    }
}

public enum WordPressFiles {
    // WordPress reads wp-config.php from its own folder. Without it there, WordPress reads the file
    // in the folder above, when that folder holds no other copy of WordPress (wp-settings.php).
    public static func configFile(core: URL) -> URL? {
        let own = core.appending(path: "wp-config.php")

        if exists(own) {
            return own
        }

        let parent = core.deletingLastPathComponent()
        let above = parent.appending(path: "wp-config.php")

        return exists(above) && !exists(parent.appending(path: "wp-settings.php")) ? above : nil
    }

    public static func versionFile(core: URL) -> URL {
        core.appending(path: "wp-includes/version.php")
    }

    // Bedrock reads .env and then .env.local. DATABASE_URL wins over the DB_ keys. Without DB_HOST
    // Bedrock uses localhost, and without DB_PREFIX it uses wp_.
    public static func bedrockConfig(project: URL) -> WordPressConfig {
        let env = EnvFile.values(of: project.appending(path: ".env"))
            .merging(EnvFile.values(of: project.appending(path: ".env.local"))) { _, local in local }
            .filter { !$0.value.isEmpty }
        let home = env["WP_HOME"]
        var config = WordPressConfig(
            database: env["DB_NAME"],
            user: env["DB_USER"],
            password: env["DB_PASSWORD"],
            host: env["DB_HOST"] ?? "localhost",
            tablePrefix: env["DB_PREFIX"] ?? "wp_",
            home: home,
            siteURL: env["WP_SITEURL"].map { siteURL in home.map { siteURL.replacingOccurrences(of: "${WP_HOME}", with: $0) } ?? siteURL }
        )

        if let url = env["DATABASE_URL"].flatMap(URLComponents.init(string:)), let host = url.host {
            config.database = String(url.path.dropFirst())
            config.user = url.user
            config.password = url.password
            config.host = url.port.map { "\(host):\($0)" } ?? host
        }

        return config
    }

    public static let beforeNexus = "// Before Nexus: "

    public static func settingDBHost(_ value: String, in text: String) -> String? {
        settingConstant("DB_HOST", to: value, in: text)
    }

    // Gives a constant a new value with a click of the user, as "Send mail to Nexus" does for a .env
    // (D44). The old line stays above it as a comment line. A file with no line or with two lines
    // for the constant, for example one in each branch of an if, gives nil. A line with another
    // statement after the define gives nil too, because the comment would hide that statement. With
    // replacingOldLine, a comment line of an earlier change goes first. So the comment line holds
    // the value of just before this change, as "Undo…" of a URL change needs it.
    public static func settingConstant(_ name: String, to value: String, in text: String, replacingOldLine: Bool = false) -> String? {
        guard let define = ConstantDefine(name), !value.contains("'"), !value.contains("\\") else {
            return nil
        }

        var lines = text.components(separatedBy: "\n")

        if replacingOldLine {
            lines.removeAll { define.oldLine(in: $0) != nil }
        }

        let matches = lines.indices.filter { define.starts(lines[$0]) }

        guard matches.count == 1, let index = matches.first, define.isWhole(lines[index]) else {
            return nil
        }

        let old = lines[index]
        let indent = String(old.prefix { $0 == " " || $0 == "\t" })
        lines[index] = "\(indent)define( '\(name)', '\(value)' );"
        lines.insert("\(indent)\(beforeNexus)\(old.trimmingCharacters(in: .whitespaces))", at: index)
        return lines.joined(separator: "\n")
    }

    // The way back of settingConstant: the old line comes back in place of the comment line, and
    // the define of Nexus below it goes. A file without such a comment line gives nil.
    public static func restoringConstant(_ name: String, in text: String) -> String? {
        guard let define = ConstantDefine(name) else {
            return nil
        }

        var lines = text.components(separatedBy: "\n")

        guard let mark = lines.indices.first(where: { define.oldLine(in: lines[$0]) != nil }), let old = define.oldLine(in: lines[mark]) else {
            return nil
        }

        let indent = String(lines[mark].prefix { $0 == " " || $0 == "\t" })
        lines[mark] = "\(indent)\(old)"

        if let line = lines.indices.first(where: { $0 > mark && define.starts(lines[$0]) }) {
            lines.remove(at: line)
        }

        return lines.joined(separator: "\n")
    }

    // The patterns of one constant, made once for all lines of a file.
    private struct ConstantDefine {
        let start: Regex<AnyRegexOutput>
        let whole: Regex<AnyRegexOutput>

        init?(_ name: String) {
            guard name.wholeMatch(of: /[A-Z_][A-Z0-9_]*/) != nil,
                  let start = try? Regex(#"^\s*\\?define\s*\(\s*['"]\#(name)['"]"#),
                  let whole = try? Regex(#"\s*\\?define\s*\(\s*['"]\#(name)['"]\s*,[^;]*\)\s*;\s*(\/\/.*|#.*)?"#) else {
                return nil
            }

            self.start = start
            self.whole = whole
        }

        func starts(_ line: String) -> Bool {
            line.contains(start)
        }

        func isWhole(_ line: String) -> Bool {
            line.wholeMatch(of: whole) != nil
        }

        func oldLine(in line: String) -> String? {
            let text = line.drop { $0 == " " || $0 == "\t" }

            guard text.hasPrefix(WordPressFiles.beforeNexus) else {
                return nil
            }

            let old = String(text.dropFirst(WordPressFiles.beforeNexus.count))
            return starts(old) ? old : nil
        }
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }
}
