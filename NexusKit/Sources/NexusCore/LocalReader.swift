import Foundation

// What Local by WP Engine has on this Mac (group 11, docs/group11-local.md). Local keeps its sites in
// sites.json of its data folder. Each site has its own PHP, web server and MySQL, and its own config
// templates in <site>/conf. Nexus only reads these files.
public struct LocalSetup: Sendable, Equatable {
    public struct Site: Sendable, Equatable {
        public let id: String
        public let name: String
        public let domain: String
        public let folder: URL
        public let runFolder: URL
        public let php: String?
        public let server: WebServer
        // mysql or mariadb.
        public let databaseKind: String
        public let databaseVersion: String?
        public let databasePort: Int?
        public let database: String
        public let user: String
        public let password: String
        public let network: WordPressNetworkKind?
        public let networkDomains: [String]
        // A site with a Node.js front end next to WordPress. Only WordPress moves.
        public let headless: Bool
        public let status: String?
        public let ownLines: [String]
        public let phpIniLines: [String]

        public var webRoot: URL {
            folder.appending(path: "app/public", directoryHint: .isDirectory)
        }

        // Sites of Local before 5.1 keep their data in mysql-raw-data.
        public var dataFolder: URL {
            let old = runFolder.appending(path: "mysql-raw-data", directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) ? old : runFolder.appending(path: "mysql/data", directoryHint: .isDirectory)
        }

        public var socket: URL {
            runFolder.appending(path: "mysql/mysqld.sock")
        }

        public var dump: URL {
            folder.appending(path: "app/sql/\(database).sql")
        }

        public var envrc: URL {
            folder.appending(path: "app/.envrc")
        }

        public var wpConfig: URL {
            webRoot.appending(path: "wp-config.php")
        }

        public init(id: String, name: String, domain: String, folder: URL, runFolder: URL, php: String?, server: WebServer, databaseKind: String, databaseVersion: String?, databasePort: Int?, database: String = "local", user: String = "root", password: String = "root", network: WordPressNetworkKind? = nil, networkDomains: [String] = [], headless: Bool = false, status: String? = nil, ownLines: [String] = [], phpIniLines: [String] = []) {
            self.id = id
            self.name = name
            self.domain = domain
            self.folder = folder
            self.runFolder = runFolder
            self.php = php
            self.server = server
            self.databaseKind = databaseKind
            self.databaseVersion = databaseVersion
            self.databasePort = databasePort
            self.database = database
            self.user = user
            self.password = password
            self.network = network
            self.networkDomains = networkDomains
            self.headless = headless
            self.status = status
            self.ownLines = ownLines
            self.phpIniLines = phpIniLines
        }
    }

    public let folder: URL
    public let sites: [Site]
    // The TLD of new sites in Local. The sites keep their own domains.
    public let tld: String
    // In the router mode localhost, WordPress has the URL http://localhost:<port>.
    public let localhostRouting: Bool

    public var hasSites: Bool {
        !sites.isEmpty
    }

    public init(folder: URL, sites: [Site], tld: String = "local", localhostRouting: Bool = false) {
        self.folder = folder
        self.sites = sites
        self.tld = tld
        self.localhostRouting = localhostRouting
    }

    // Each site has a certificate of its own for its domain and *.domain.
    public func certificate(of domain: String) -> URL {
        folder.appending(path: "run/router/nginx/certs/\(domain).crt")
    }
}

public enum LocalReader {
    public static let bundleIdentifier = "com.getflywheel.lightning.local"
    public static let appServices = URL(filePath: "/Applications/Local.app/Contents/Resources/extraResources/lightning-services", directoryHint: .isDirectory)

    public static func folder(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Local", directoryHint: .isDirectory)
    }

    public static func sitesFile(home: URL) -> URL {
        folder(home: home).appending(path: "sites.json")
    }

    public static func read(home: URL) -> LocalSetup? {
        read(local: folder(home: home), home: home, bundledServices: appServices)
    }

    // nil when Local has no sites.json. Local removes an entry without id or name when it reads the
    // file, so Nexus skips it too.
    public static func read(local: URL, home: URL, bundledServices: URL?) -> LocalSetup? {
        guard let sites = json(local.appending(path: "sites.json")) else {
            return nil
        }

        let statuses = json(local.appending(path: "site-statuses.json")) ?? [:]
        let defaults = json(local.appending(path: "settings-new-site-defaults.json")) ?? [:]
        let router = json(local.appending(path: "router.json")) ?? [:]
        let services = [local.appending(path: "lightning-services", directoryHint: .isDirectory)] + [bundledServices].compactMap { $0 }
        var result: [LocalSetup.Site] = []

        for (key, value) in sites.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any], let id = entry["id"] as? String, let name = entry["name"] as? String, let domain = entry["domain"] as? String, let path = entry["path"] as? String else {
                continue
            }

            result.append(site(entry, id: id, name: name, domain: domain, folder: expanded(path, home: home), local: local, status: statuses[key] as? String, services: services))
        }

        let tld = (defaults["tld"] as? String).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 } ?? "local"

        return LocalSetup(folder: local, sites: result.sorted { $0.domain < $1.domain }, tld: tld.isEmpty ? "local" : tld, localhostRouting: router["mode"] as? String == "localhost")
    }

    static func site(_ entry: [String: Any], id: String, name: String, domain: String, folder: URL, local: URL, status: String?, services: [URL]) -> LocalSetup.Site {
        let siteServices = entry["services"] as? [String: [String: Any]] ?? [:]

        func version(of service: String) -> String? {
            siteServices[service]?["version"] as? String
        }

        func port(of service: String, _ key: String) -> Int? {
            ((siteServices[service]?["ports"] as? [String: Any])?[key] as? [Any])?.first.flatMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
        }

        let databaseKind = siteServices["mariadb"] != nil ? "mariadb" : "mysql"
        let server: WebServer = siteServices["apache"] != nil || (entry["webServer"] as? String)?.hasPrefix("apache") == true ? .apache : .nginx
        let serverName = server == .apache ? "apache" : "nginx"
        let php = version(of: "php") ?? entry["phpVersion"] as? String
        let mysql = entry["mysql"] as? [String: Any] ?? [:]
        let network: WordPressNetworkKind? = switch entry["multiSite"] as? String {
        case "ms-subdomain"?: .subdomains
        case "ms-subdir"?: .subfolders
        default: nil
        }
        let domains = (entry["multiSiteDomains"] as? [String] ?? []).compactMap { URL(string: $0.contains("://") ? $0 : "http://\($0)")?.host() }.filter { $0 != domain }

        return LocalSetup.Site(
            id: id,
            name: name,
            domain: domain,
            folder: folder,
            runFolder: local.appending(path: "run/\(id)", directoryHint: .isDirectory),
            php: php,
            server: server,
            databaseKind: databaseKind,
            databaseVersion: version(of: databaseKind) ?? entry["mysqlVersion"] as? String,
            databasePort: port(of: databaseKind, "MYSQL"),
            database: mysql["database"] as? String ?? "local",
            user: mysql["user"] as? String ?? "root",
            password: mysql["password"] as? String ?? "root",
            network: network,
            networkDomains: domains,
            headless: siteServices.values.contains { $0["role"] as? String == "frontend" },
            status: status,
            ownLines: ownLines(site: folder.appending(path: "conf/\(serverName)/site.conf.hbs"), service: serverName, version: version(of: serverName), file: "site.conf.hbs", services: services),
            phpIniLines: php.map { phpIniLines(site: folder.appending(path: "conf/php/php.ini.hbs"), version: $0, services: services) } ?? []
        )
    }

    // The lines that the user added to the site template of nginx or Apache. Each line of the
    // original template counts once, so an added block keeps its closing brace. A line with {{ is
    // a part of the template of Local.
    static func ownLines(site: URL, service: String, version: String?, file: String, services: [URL]) -> [String] {
        guard let version, let text = try? String(contentsOf: site, encoding: .utf8) else {
            return []
        }

        let candidates = templates(service: service, version: version, path: "conf/\(file)", services: services)

        guard !candidates.isEmpty else {
            return []
        }

        return candidates.map { added(lines(of: text), to: lines(of: $0)) }.min { $0.count < $1.count } ?? []
    }

    // The php.ini lines that differ from the template of the same PHP version. A value with {{ is a
    // path of Local.
    static func phpIniLines(site: URL, version: String, services: [URL]) -> [String] {
        guard let text = try? String(contentsOf: site, encoding: .utf8) else {
            return []
        }

        let current = ValetReader.iniValues(text).filter { !$0.value.contains("{{") }
        let candidates = templates(service: "php", version: version, path: "conf/php.ini.hbs", services: services).map(ValetReader.iniValues)

        guard !candidates.isEmpty else {
            return []
        }

        let changed = candidates.map { original in current.filter { line in original.last { $0.key == line.key }?.value != line.value } }.min { $0.count < $1.count } ?? []

        return changed.map { "\($0.key) = \($0.value)" }
    }

    // A service folder is named <service>-<version>+<build>, for example nginx-1.26.1+3. The build
    // of a site is not in sites.json, so each build of the version is a candidate.
    static func templates(service: String, version: String, path: String, services: [URL]) -> [String] {
        services.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasPrefix("\(service)-\(version)+") }
                .sorted()
                .compactMap { try? String(contentsOf: folder.appending(path: "\($0)/\(path)"), encoding: .utf8) }
        }
    }

    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func added(_ current: [String], to original: [String]) -> [String] {
        var counts: [String: Int] = [:]

        for line in original {
            counts[line, default: 0] += 1
        }

        var result: [String] = []

        for line in current {
            if let count = counts[line], count > 0 {
                counts[line] = count - 1
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), !line.contains("{{") else {
                continue
            }

            result.append(line)
        }

        return result
    }

    static func expanded(_ path: String, home: URL) -> URL {
        if path == "~" || path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory).standardizedFileURL
        }

        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }

    static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
