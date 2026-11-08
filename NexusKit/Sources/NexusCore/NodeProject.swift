import Foundation

// The program that installs the packages of a Node project and runs its scripts (D67). Nexus ships
// Node with npm. pnpm and yarn come through corepack. bun is a program of its own.
public enum PackageManager: String, Codable, Sendable, CaseIterable {
    case npm
    case pnpm
    case yarn
    case bun

    // The lock files in the order that Nexus reads them. A project with two lock files mostly has
    // an old one that nobody removed, and the newer programs come first.
    static let lockFiles: [(name: String, manager: PackageManager)] = [
        ("bun.lock", .bun),
        ("bun.lockb", .bun),
        ("pnpm-lock.yaml", .pnpm),
        ("yarn.lock", .yarn),
        ("package-lock.json", .npm),
        ("npm-shrinkwrap.json", .npm),
    ]

    public var usesCorepack: Bool {
        self == .pnpm || self == .yarn
    }

    public func run(_ script: String) -> String {
        "\(rawValue) run \(script)"
    }
}

// The framework of a Node.js app, from its dependencies. The order matters: a SvelteKit app also
// depends on Vite.
public enum NodeFramework: String, Codable, Sendable, CaseIterable {
    case next
    case nuxt
    case astro
    case sveltekit
    case vite
    case express

    public var dependency: String {
        self == .sveltekit ? "@sveltejs/kit" : rawValue
    }

    public var displayName: String {
        switch self {
        case .next: "Next.js"
        case .nuxt: "Nuxt"
        case .astro: "Astro"
        case .sveltekit: "SvelteKit"
        case .vite: "Vite"
        case .express: "Express"
        }
    }

    // The dev server of Vite ignores PORT and listens only on [::1]. SvelteKit and Astro use that
    // server.
    public var usesViteServer: Bool {
        self == .vite || self == .sveltekit || self == .astro
    }

    // These servers take the extra hosts from __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS.
    public var checksHost: Bool {
        usesViteServer || self == .nuxt
    }

    // Next.js refuses /_next/* and its websocket for an origin that is not its own. It has no
    // environment variable for allowedDevOrigins. So nginx gives it the origin of its own address.
    public var checksOrigin: Bool {
        self == .next
    }
}

// How Nexus starts a Node.js app on its port (D67). Every app gets PORT. The Vite server gets
// --port and --strictPort after the script of the project, because it ignores PORT. Nuxt stops
// without HOST. Vite, Nuxt and Astro accept the hosts of the dev TLD through
// __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS. That key holds one name, so an alias in another TLD gets
// a warning. A command of the user gets the same environment and no flags. It can use {port:app}.
public struct NodeAppLaunch: Sendable, Equatable {
    public static let portName = "app"

    public let command: String
    public let environment: [String: String]
    public let warnings: [String]

    public init(command: String, environment: [String: String], warnings: [String] = []) {
        self.command = command
        self.environment = environment
        self.warnings = warnings
    }

    // Returns nil without a command of the user and without a script. hosts are the names that
    // nginx sends to the app.
    public static func make(command custom: String?, project: NodeProject?, port: Int, hosts: [String], tld: String) -> NodeAppLaunch? {
        var environment = ["PORT": "\(port)", "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS": ".\(tld)"]
        var warnings: [String] = []
        let blocked = hosts.filter { !$0.hasSuffix(".\(tld)") }

        if project?.framework == .nuxt {
            environment["HOST"] = "127.0.0.1"
        }

        if let framework = project?.framework, framework.checksHost, !blocked.isEmpty {
            warnings.append("\(framework.displayName) allows only the hosts in .\(tld) without a change. Add \(blocked.joined(separator: ", ")) to server.allowedHosts in the configuration of Vite.")
        }

        if let custom {
            return NodeAppLaunch(command: custom, environment: environment, warnings: warnings)
        }

        guard let project, let script = project.script, let command = project.command else {
            return nil
        }

        if project.scriptSetsPort {
            warnings.append("The \(script) script of package.json sets its own port, so Nexus cannot give the app port \(port). Remove the port from the script, or set a command that uses {port:app}.")
        }

        guard project.framework?.usesViteServer == true, !project.scriptSetsPort else {
            return NodeAppLaunch(command: command, environment: environment, warnings: warnings)
        }

        // npm gives the arguments after -- to the script. pnpm, yarn and bun give them without --,
        // and pnpm would give a -- to the script too.
        let separator = project.packageManager == .npm ? " -- " : " "

        return NodeAppLaunch(command: "\(command)\(separator)--port \(port) --strictPort", environment: environment, warnings: warnings)
    }
}

// What package.json and the lock file say about a Node project (D67). script is the dev script,
// or else the start script. A project without both has no command.
public struct NodeProject: Sendable, Equatable {
    public static let scripts = ["dev", "start"]

    public let script: String?
    public let framework: NodeFramework?
    public let packageManager: PackageManager
    // The text of the script, for example "vite --port 3000".
    public let scriptText: String?
    // A dependency that connects to MySQL, PostgreSQL or Redis.
    public let usesDatabaseClient: Bool

    // The clients and the ORMs that connect to a server on this Mac.
    static let databaseClients: Set<String> = [
        "pg", "postgres", "mysql", "mysql2", "mariadb", "@prisma/client", "drizzle-orm", "knex",
        "sequelize", "typeorm", "kysely", "@mikro-orm/core", "ioredis", "redis", "bullmq",
    ]

    public init(script: String?, framework: NodeFramework?, packageManager: PackageManager, scriptText: String? = nil, usesDatabaseClient: Bool = false) {
        self.script = script
        self.framework = framework
        self.packageManager = packageManager
        self.scriptText = scriptText
        self.usesDatabaseClient = usesDatabaseClient
    }

    public var command: String? {
        script.map(packageManager.run)
    }

    // A port in the script wins over PORT, and a second --port gives Vite two values. Only --port and
    // -p with a number count. So "tsc -p tsconfig.json" and "npm-run-all -p" do not.
    public var scriptSetsPort: Bool {
        guard let scriptText else {
            return false
        }

        return scriptText.range(of: #"(^|\s)(--port|-p)(\s+|=)\d"#, options: .regularExpression) != nil
    }

    // Returns nil for a folder without a package.json that Nexus can read.
    public static func read(in folder: URL) -> NodeProject? {
        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let scripts = package["scripts"] as? [String: Any] ?? [:]
        let dependencies = (package["dependencies"] as? [String: Any] ?? [:]).merging(package["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
        let script = Self.scripts.first { (scripts[$0] as? String)?.isEmpty == false }

        return NodeProject(
            script: script,
            framework: NodeFramework.allCases.first { dependencies[$0.dependency] != nil },
            packageManager: packageManager(of: folder, named: package["packageManager"] as? String),
            scriptText: script.flatMap { scripts[$0] as? String },
            usesDatabaseClient: !databaseClients.isDisjoint(with: dependencies.keys)
        )
    }

    // The lock file can be in a parent folder, for example in the root of a monorepo. Nexus looks
    // up to the root of the git checkout, and only in the folder itself without git. Without a lock
    // file, the packageManager key of package.json decides, as for corepack.
    private static func packageManager(of folder: URL, named declared: String?) -> PackageManager {
        let start = RealPath.of(folder)
        let top = gitRoot(from: start) ?? start
        var current = start

        while true {
            for (name, manager) in PackageManager.lockFiles where FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(name)) {
                return manager
            }

            guard current != top, current != "/" else {
                break
            }

            current = (current as NSString).deletingLastPathComponent
        }

        let name = declared?.split(separator: "@").first.map(String.init)
        return name.flatMap(PackageManager.init(rawValue:)) ?? .npm
    }

    private static func gitRoot(from path: String) -> String? {
        var current = path

        while current != "/" {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current
            }

            current = (current as NSString).deletingLastPathComponent
        }

        return nil
    }
}

extension Site {
    // The Node project in the folder of the site. A site in the public folder of a PHP project
    // reads the project folder.
    public var nodeProject: NodeProject? {
        NodeProject.read(in: URL(filePath: ProjectFolder.projectFolder(of: self), directoryHint: .isDirectory))
    }
}

extension SiteKind {
    // The kind of a new site (D67). composer.json makes a PHP site, also with a package.json for
    // Vite. The files of WordPress make a PHP site too, also with a package.json for the build of a
    // theme (Phase 4, 3a). A package.json with a dev or start script makes a Node.js app. A folder
    // with neither file is a PHP site. The public folder of a PHP project belongs to that project.
    public static func detected(in folder: URL) -> SiteKind {
        let project = URL(filePath: ProjectFolder.projectFolder(ofSiteFolder: folder), directoryHint: .isDirectory)

        if FileManager.default.fileExists(atPath: project.appending(path: "composer.json").path(percentEncoded: false)) {
            return .php
        }

        // Only the folder itself counts. A Node.js app can hold a WordPress folder for its content.
        if PHPProject.hasWordPress(project) {
            return .php
        }

        return NodeProject.read(in: project)?.script == nil ? .php : .node
    }
}
