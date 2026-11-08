import Foundation

// The templates of a new site (Phase 4, 3i). Each one runs the official tool of its framework in
// non-interactive mode. The major version of each tool is fixed, so a new flag in a later major
// version does not break Nexus.
public enum SiteTemplate: String, Codable, Sendable, CaseIterable {
    case laravel
    case wordpress
    case next
    case nuxt
    case vite
    case astro

    public var displayName: String {
        switch self {
        case .laravel: "Laravel"
        case .wordpress: "WordPress"
        case .next: "Next.js"
        case .nuxt: "Nuxt"
        case .vite: "Vite"
        case .astro: "Astro"
        }
    }

    public var summary: String {
        switch self {
        case .laravel: "PHP framework"
        case .wordpress: "Blog or site with wp-admin"
        case .next: "React framework"
        case .nuxt: "Vue framework"
        case .vite: "React, Vue or Svelte app"
        case .astro: "Site with content pages"
        }
    }

    public var kind: SiteKind {
        isPHP ? .php : .node
    }

    public var isPHP: Bool {
        self == .laravel || self == .wordpress
    }

    // The package and its fixed major version for npx.
    public var creator: String? {
        switch self {
        case .laravel, .wordpress: nil
        case .next: "create-next-app@16"
        case .nuxt: "create-nuxt@4"
        case .vite: "create-vite@9"
        case .astro: "create-astro@5"
        }
    }
}

public enum LaravelStarterKit: String, Codable, Sendable, CaseIterable {
    case none
    case react
    case vue
    case svelte
    case livewire

    public var displayName: String {
        switch self {
        case .none: "None"
        case .react: "React"
        case .vue: "Vue"
        case .svelte: "Svelte"
        case .livewire: "Livewire"
        }
    }
}

public enum LaravelAuthentication: String, Codable, Sendable, CaseIterable {
    case builtIn = "built_in"
    case workos
    case none

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .workos: "WorkOS"
        case .none: "None"
        }
    }
}

public enum LaravelTests: String, Codable, Sendable, CaseIterable {
    case pest
    case phpunit

    public var displayName: String {
        switch self {
        case .pest: "Pest"
        case .phpunit: "PHPUnit"
        }
    }
}

public enum ViteFramework: String, Codable, Sendable, CaseIterable {
    case react
    case vue
    case svelte

    public var displayName: String {
        switch self {
        case .react: "React"
        case .vue: "Vue"
        case .svelte: "Svelte"
        }
    }
}

// What the New site sheet and nexus new ask for. database is the id of a Nexus instance. A Laravel
// site without one uses SQLite. php and node are version lines, and nil gives the newest one that
// fits the template.
public struct NewSite: Codable, Sendable, Equatable {
    public var template: SiteTemplate
    public var name: String
    public var parent: String
    public var git: Bool
    public var database: String?
    public var php: String?
    public var node: String?
    public var starterKit: LaravelStarterKit
    public var authentication: LaravelAuthentication
    public var teams: Bool
    public var tests: LaravelTests
    public var boost: Bool
    public var locale: String
    public var adminUser: String
    public var adminEmail: String
    public var network: WordPressNetworkKind?
    public var framework: ViteFramework
    public var packageManager: PackageManager

    public init(
        template: SiteTemplate,
        name: String,
        parent: String,
        git: Bool = true,
        database: String? = nil,
        php: String? = nil,
        node: String? = nil,
        starterKit: LaravelStarterKit = .none,
        authentication: LaravelAuthentication = .builtIn,
        teams: Bool = false,
        tests: LaravelTests = .pest,
        boost: Bool = true,
        locale: String = WordPressLocale.english,
        adminUser: String = "admin",
        adminEmail: String = "",
        network: WordPressNetworkKind? = nil,
        framework: ViteFramework = .react,
        packageManager: PackageManager = .npm
    ) {
        self.template = template
        self.name = name
        self.parent = parent
        self.git = git
        self.database = database
        self.php = php
        self.node = node
        self.starterKit = starterKit
        self.authentication = authentication
        self.teams = teams
        self.tests = tests
        self.boost = boost
        self.locale = locale
        self.adminUser = adminUser
        self.adminEmail = adminEmail
        self.network = network
        self.framework = framework
        self.packageManager = packageManager
    }
}

public enum NewSiteError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            "\(name.isEmpty ? "An empty name" : name) cannot be the name of a new site. Use 1 to 50 small letters, digits and hyphens, and start with a letter or a digit, for example shop."
        }
    }
}

// The name is the folder, the first part of the host and the npm package name. So it follows the
// strictest of these rules: npm accepts no capital letters, and a host accepts no underscore.
public enum NewSiteName {
    public static func validated(_ name: String) throws -> String {
        guard (1...50).contains(name.count),
              let first = name.first,
              first.isASCII, first.isLowercase || first.isNumber,
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              !name.hasSuffix("-") else {
            throw NewSiteError.invalidName(name)
        }

        return name
    }

    public static func databaseBase(of name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    // The tool writes into a hidden folder next to the new site. The scan of a parked folder skips a
    // folder whose name starts with a dot (D62). So nexusd adds the site only after the tool, and a
    // Node.js app does not start before its packages are installed.
    public static func workFolder(of name: String) -> String {
        ".nexus-new-\(name)"
    }
}

// The arguments of the tools. The tests check each template with them.
public enum SiteTemplateCommands {
    public static let laravelInstaller = "laravel/installer"
    public static let laravelInstallerVersion = "5.32.*"

    public static func laravelNew(_ site: NewSite, database: DatabaseKind?, hasNode: Bool) -> [String] {
        var arguments = ["new", site.name, "--no-interaction"]

        if site.starterKit != .none {
            arguments.append("--\(site.starterKit.rawValue)")

            switch site.authentication {
            case .builtIn:
                break
            case .workos:
                arguments.append("--workos")
            case .none:
                arguments.append("--no-authentication")
            }

            if site.teams {
                arguments.append("--teams")
            }
        }

        arguments.append("--\(site.tests.rawValue)")
        arguments.append(site.boost ? "--boost" : "--no-boost")
        arguments.append("--database=\(laravelConnection(database))")
        arguments.append(hasNode ? "--npm" : "--no-node")

        return arguments
    }

    public static func laravelConnection(_ kind: DatabaseKind?) -> String {
        switch kind {
        case .mysql: "mysql"
        case .mariadb: "mariadb"
        case .postgresql: "pgsql"
        case nil: "sqlite"
        }
    }

    // The arguments for npx. Each tool makes the files only. nexusd runs the install of the
    // packages with the package manager of the site, so each template has the same steps.
    public static func create(_ site: NewSite) -> [String]? {
        guard let creator = site.template.creator else {
            return nil
        }

        let manager = site.packageManager.rawValue
        let tail: [String] = switch site.template {
        case .laravel, .wordpress:
            []
        case .next:
            ["--ts", "--tailwind", "--eslint", "--app", "--no-src-dir", "--import-alias", "@/*", "--yes", "--use-\(manager)", "--disable-git", "--skip-install"]
        case .nuxt:
            ["--template", "minimal", "--packageManager", manager, "--no-gitInit", "--no-install", "--no-modules"]
        case .vite:
            ["--template", "\(site.framework.rawValue)-ts", "--no-interactive"]
        case .astro:
            ["--template", "basics", "--no-install", "--no-git", "--yes", "--skip-houston"]
        }

        return ["--yes", creator, site.name] + tail
    }

    public static func wordPressDownload(_ site: NewSite, path: String) -> [String] {
        ["core", "download", "--locale=\(site.locale)", "--path=\(path)"]
    }

    // The password comes on the standard input, so it is not in the process list. After the prompt,
    // WP-CLI 2.12 prints the whole command with the password. --quiet stops that line.
    public static func wordPressInstall(_ site: NewSite, url: String, path: String) -> [String] {
        let shared = ["--path=\(path)", "--url=\(url)", "--title=\(site.name)", "--admin_user=\(site.adminUser)", "--admin_email=\(site.adminEmail)", "--skip-email", "--quiet", "--prompt=admin_password"]

        switch site.network {
        case nil:
            return ["core", "install"] + shared
        case .subfolders:
            return ["core", "multisite-install"] + shared
        case .subdomains:
            return ["core", "multisite-install", "--subdomains"] + shared
        }
    }

    public static let wordPressIgnore = "/wp-config.php\n/wp-content/uploads/\n.DS_Store\n"
}
