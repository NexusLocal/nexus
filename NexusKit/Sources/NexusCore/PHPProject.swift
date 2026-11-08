import Foundation

// The type of a PHP project (Phase 4, 3a). Each screen and each setting shows the parts of the
// type that it belongs to (owner, 2026-11-06). Bedrock and Radicle hold WordPress too. So they
// come first. A classic WordPress site has its files in the folder or in one folder below it.
public enum PHPProjectType: String, Codable, Sendable, CaseIterable {
    case laravel
    case wordpress
    case bedrock
    case other

    public var displayName: String {
        switch self {
        case .laravel: "Laravel"
        case .wordpress: "WordPress"
        case .bedrock: "Bedrock"
        case .other: "PHP"
        }
    }

    public var isWordPress: Bool {
        self == .wordpress || self == .bedrock
    }
}

// The type of the project and the document root of a site. Both read files of the project. So a
// list of the sites or a write of the web configuration reads them one time for each site and gives
// them to each step.
public struct SiteLayout: Sendable, Equatable {
    public let projectType: PHPProjectType
    public let documentRoot: URL
    // The kind of a WordPress network, or nil for a site that is no network (Phase 4, 3g).
    public let network: WordPressNetworkKind?

    public init(of site: Site) {
        let folder = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)

        projectType = PHPProject.type(of: site)
        documentRoot = site.documentRoot
        network = projectType.isWordPress ? PHPProject.network(in: folder, type: projectType) : nil
    }

    public static func of(_ sites: [Site]) -> [String: SiteLayout] {
        Dictionary(sites.map { ($0.host, SiteLayout(of: $0)) }) { first, _ in first }
    }

    public var subdomainNetwork: Bool {
        network == .subdomains
    }

    // The names that nginx, Apache and the certificate get. A network on subdomains gets each name
    // below its host without a step of the user (owner, 2026-11-07). Only the DNS server of Nexus
    // answers such names. So this works only for a host in the dev TLD.
    public func hosts(of site: Site, tld: String) -> [String] {
        let wildcard = "*.\(site.host)"

        guard subdomainNetwork, site.host.hasSuffix(".\(tld)"), !site.hosts.contains(wildcard) else {
            return site.hosts
        }

        return site.hosts + [wildcard]
    }
}

public enum WordPressNetworkKind: String, Codable, Sendable {
    case subdomains
    case subfolders
}

// The one place that finds WordPress. nexus wp uses it for the core folder too (Phase 4, 3c).
public enum PHPProject {
    // WP-CLI looks for this file. Each copy of WordPress has it. A folder with only a wp-config.php
    // has no WordPress to run.
    static let coreFile = "wp-load.php"

    // Bedrock serves web/ and Radicle serves public/. Both keep WordPress in wp/ of that folder.
    static let bedrockCores = ["web/wp", "public/wp"]

    public static func type(of folder: URL) -> PHPProjectType {
        if isBedrock(folder) {
            return .bedrock
        }

        if isLaravel(folder) {
            return .laravel
        }

        return wordPressFolder(in: folder) == nil ? .other : .wordpress
    }

    // The project folder of a site, as ProjectFolder gives it.
    public static func type(of site: Site) -> PHPProjectType {
        guard site.kind == .php else {
            return .other
        }

        return type(of: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory))
    }

    // Bedrock and Radicle of Roots. Before composer install WordPress is not there yet. So
    // composer.json decides, or the files of Bedrock itself.
    public static func isBedrock(_ folder: URL) -> Bool {
        if text(of: folder.appending(path: "composer.json"))?.contains("roots/bedrock-autoloader") == true {
            return true
        }

        return exists(folder.appending(path: "web/wp-config.php")) && exists(folder.appending(path: "config/application.php"))
    }

    // The folder that holds WordPress: the folder itself, wp/ of Bedrock or Radicle, or the one
    // folder below it that has WordPress. Two such folders give none. A folder below it can be a
    // symbolic link to a copy of WordPress.
    public static func wordPressFolder(in folder: URL) -> URL? {
        if hasWordPress(folder) {
            return folder
        }

        if let bedrock = bedrockCores.map({ folder.appending(path: $0, directoryHint: .isDirectory) }).first(where: hasWordPress) {
            return bedrock
        }

        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let found = children.filter(hasWordPress)

        return found.count == 1 ? found[0] : nil
    }

    // WordPress is a network with MULTISITE. SUBDOMAIN_INSTALL gives its kind. An old network has
    // VHOST. A classic site has them in wp-config.php. Bedrock has them in config/application.php
    // or in its .env files. The files do not run. So only a plain true on a line that is no comment
    // counts. A classic site has wp-config.php in its folder in most cases. So that file comes first,
    // before a search for the folder of WordPress.
    public static func network(in folder: URL, type: PHPProjectType) -> WordPressNetworkKind? {
        let configFiles: [URL]

        if type == .bedrock {
            configFiles = ["config/application.php", "config/environments/development.php"].map { folder.appending(path: $0) }
        } else if exists(folder.appending(path: "wp-config.php")) {
            configFiles = [folder.appending(path: "wp-config.php")]
        } else {
            configFiles = wordPressFolder(in: folder).flatMap(WordPressFiles.configFile(core:)).map { [$0] } ?? []
        }

        let code = configFiles.compactMap(text(of:)).flatMap { $0.components(separatedBy: "\n") }.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !["//", "#", "*", "/*"].contains { trimmed.hasPrefix($0) }
        }
        let env = EnvFile.values(of: folder.appending(path: ".env")).merging(EnvFile.values(of: folder.appending(path: ".env.local"))) { _, local in local }
        let isOn = { (key: String) in ["true", "1"].contains(env[key]?.lowercased() ?? "") }

        guard code.contains(where: { $0.contains(multisiteDefine) }) || isOn("MULTISITE") else {
            return nil
        }

        let subdomains = code.contains { $0.contains(subdomainDefine) || $0.contains(vhostDefine) } || isOn("SUBDOMAIN_INSTALL")
        return subdomains ? .subdomains : .subfolders
    }

    nonisolated(unsafe) private static let multisiteDefine = /['"]MULTISITE['"]\s*,\s*(?i:true|1)\s*\)/
    nonisolated(unsafe) private static let subdomainDefine = /['"]SUBDOMAIN_INSTALL['"]\s*,\s*(?i:true|1|'1'|"1")\s*\)/
    nonisolated(unsafe) private static let vhostDefine = /['"]VHOST['"]\s*,\s*['"]yes['"]\s*\)/

    public static func hasWordPress(_ folder: URL) -> Bool {
        exists(folder.appending(path: coreFile))
    }

    static func isLaravel(_ folder: URL) -> Bool {
        exists(folder.appending(path: "artisan")) && exists(folder.appending(path: "bootstrap/app.php"))
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    private static func text(of file: URL) -> String? {
        FileManager.default.contents(atPath: file.path(percentEncoded: false)).map { String(decoding: $0, as: UTF8.self) }
    }
}
