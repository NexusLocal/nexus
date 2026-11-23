import Foundation

public struct NexusPaths: Sendable, Equatable {
    public let root: URL
    // The folder for a link to a phar without a space in its path (nexus wp). nexusd and the nexus
    // command run as the same user. So they have the same temporary folder.
    public let pharLinks: URL

    public init(root: URL, pharLinks: URL = FileManager.default.temporaryDirectory) {
        self.root = root
        self.pharLinks = pharLinks
    }

    public static var standard: NexusPaths {
        NexusPaths(root: .applicationSupportDirectory.appending(path: NexusVariant.current.name, directoryHint: .isDirectory))
    }

    public var runtimes: URL { folder("runtimes") }
    public var config: URL { folder("config") }
    public var data: URL { folder("data") }
    public var run: URL { folder("run") }
    public var logs: URL { folder("logs") }
    public var certs: URL { folder("certs") }
    public var trash: URL { folder("trash") }
    public var bin: URL { folder("bin") }
    public var mail: URL { folder("mail") }
    public var php: URL { folder("php") }

    public var allFolders: [URL] {
        [runtimes, config, data, run, logs, certs, trash, bin, mail, php]
    }

    // The mails that wait while the inbox does not run (Phase 3, 3b). nexus sendmail writes here
    // too when nexusd does not run.
    public var mailOutbox: URL {
        mail.appending(path: "outbox", directoryHint: .isDirectory)
    }

    public func runtime(_ name: String, line: String) -> URL {
        runtimes
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: line, directoryHint: .isDirectory)
    }

    public var runtimeStaging: URL {
        runtimes.appending(path: ".staging", directoryHint: .isDirectory)
    }

    public func dataFolder(service: String, line: String) -> URL {
        data.appending(path: "\(service)-\(line)", directoryHint: .isDirectory)
    }

    public func log(_ name: String) -> URL {
        logs.appending(path: "\(name).log", directoryHint: .notDirectory)
    }

    public var activityLog: URL {
        log("activity")
    }

    // The full output of each program that failed (owner, 2026-11-07).
    public var errorLog: URL {
        log("errors")
    }

    public var siteLogs: URL {
        logs.appending(path: "sites", directoryHint: .isDirectory)
    }

    public func siteLog(_ host: String) -> URL {
        siteLogs.appending(path: "\(host).log", directoryHint: .notDirectory)
    }

    // The files of the public links (group 4). The share id is part of a name. So these files never
    // go into a report.
    public var shareFolder: URL { data.appending(path: "share", directoryHint: .isDirectory) }
    public var cloudflaredHome: URL { shareFolder.appending(path: "cloudflared", directoryHint: .isDirectory) }
    public var cloudflaredConfig: URL { cloudflaredHome.appending(path: "config.yml", directoryHint: .notDirectory) }
    public var ownDomainConfig: URL { cloudflaredHome.appending(path: "own-domain.yml", directoryHint: .notDirectory) }
    public func sharePasswordFile(_ id: String) -> URL { shareFolder.appending(path: "\(id).htpasswd", directoryHint: .notDirectory) }
    public func shareScript(_ id: String) -> URL { shareFolder.appending(path: "\(id).js", directoryHint: .notDirectory) }
    public func shareVisitorLog(_ id: String) -> URL { logs.appending(path: "share-\(id).jsonl", directoryHint: .notDirectory) }
    public func shareRequestLog(_ id: String) -> URL { logs.appending(path: "share-\(id)-requests.jsonl", directoryHint: .notDirectory) }
    // The njs file of the list of the requests (group 4, 4f).
    public var shareRequestScript: URL { shareFolder.appending(path: "requests.js", directoryHint: .notDirectory) }
    public func tunnelLog(_ host: String) -> URL { log("cloudflared-\(host)") }
    public var ownDomainTunnelLog: URL { log("cloudflared-own-domain") }
    // The folder of the setup of the own domain (group 4, 4h). Its mode is 0700. It is the HOME of
    // the login. So a cert never reaches a quick link or the ~/.cloudflared of the user. The cert
    // file exists only until nexusd moves it into the Keychain. The login log holds the address of
    // the login page. That address is a secret until the login ends. So it is not in logs/.
    public var ownDomainFolder: URL { shareFolder.appending(path: "own-domain", directoryHint: .isDirectory) }
    public var ownDomainCommandConfig: URL { ownDomainFolder.appending(path: "config.yml", directoryHint: .notDirectory) }
    public var ownDomainLoginCert: URL { ownDomainFolder.appending(path: ".cloudflared/cert.pem", directoryHint: .notDirectory) }
    public var ownDomainLoginLog: URL { ownDomainFolder.appending(path: "login.log", directoryHint: .notDirectory) }

    // The pages that nginx serves itself. The settings of nginx get only the run folder.
    public static func nginxPages(inRun run: URL) -> URL {
        run.appending(path: "nginx/pages", directoryHint: .isDirectory)
    }

    public var nginxPages: URL {
        Self.nginxPages(inRun: run)
    }

    public static let devServerPagePrefix = "dev-server-"

    // The page of nginx for a host with a dev server (owner, 2026-11-15).
    public func devServerPage(_ host: String) -> URL {
        nginxPages.appending(path: "\(Self.devServerPagePrefix)\(host).html", directoryHint: .notDirectory)
    }

    public var nginxConfig: URL {
        config.appending(path: "nginx/nginx.conf", directoryHint: .notDirectory)
    }

    public var apacheConfig: URL {
        config.appending(path: "apache/httpd.conf", directoryHint: .notDirectory)
    }

    // The custom lines of each site, which the server block of nginx or the VirtualHost of Apache
    // includes (owner, 2026-11-14). nexusd writes them from the state.
    public func siteLinesFolder(_ server: WebServer) -> URL {
        (server == .apache ? apacheConfig : nginxConfig).deletingLastPathComponent().appending(path: "sites", directoryHint: .isDirectory)
    }

    public func siteLinesFile(_ host: String, server: WebServer) -> URL {
        siteLinesFolder(server).appending(path: "\(host).conf", directoryHint: .notDirectory)
    }

    public var phpConfigRoot: URL {
        config.appending(path: "php", directoryHint: .isDirectory)
    }

    public func phpConfigFolder(line: String) -> URL {
        phpConfigRoot.appending(path: line, directoryHint: .isDirectory)
    }

    // The PHP settings that only nexus wp reads, after the conf.d folder of the PHP version.
    public var wpCLIConfigFolder: URL {
        config.appending(path: "wp-cli/conf.d", directoryHint: .isDirectory)
    }

    public func phpSocket(line: String) -> URL {
        run.appending(path: "php-\(line).sock", directoryHint: .notDirectory)
    }

    public func xdebugSocket(line: String) -> URL {
        run.appending(path: "xdebug-\(line).sock", directoryHint: .notDirectory)
    }

    // The pool of PHP-FPM for requests of a link with hidden error details (group 4, 4d).
    public func phpShareSocket(line: String) -> URL {
        run.appending(path: "php-share-\(line).sock", directoryHint: .notDirectory)
    }

    // The prepend file of PHP sends each dump to this socket. Its path must stay below the 104
    // bytes of a Unix socket path.
    public var dumpSocket: URL {
        run.appending(path: "dumps.sock", directoryHint: .notDirectory)
    }

    // PHP touches files in this folder, for example the pause file after a failed send. All PHP
    // processes of Nexus share them.
    public var dumpFolder: URL {
        run.appending(path: "dumps", directoryHint: .isDirectory)
    }

    public var dumpLog: URL {
        logs.appending(path: "dumps.jsonl", directoryHint: .notDirectory)
    }

    // nexusd copies the PHP library of the dump viewer here from the app. So the path stays the
    // same when the app moves. An update of the app also does not replace a file that PHP uses.
    public var dumpLibrary: URL {
        php.appending(path: "dumps", directoryHint: .isDirectory)
    }

    public func databaseConfig(_ kind: DatabaseKind, line: String) -> URL {
        let name = kind == .mongodb ? "mongod.conf" : "my.cnf"
        return config.appending(path: "\(kind.rawValue)/\(line)/\(name)", directoryHint: .notDirectory)
    }

    public func redisConfig(line: String) -> URL {
        config.appending(path: "redis/\(line)/redis.conf", directoryHint: .notDirectory)
    }

    // PostgreSQL gets only a folder and names its socket after the port. MongoDB runs without a
    // socket, so its name is only a name that no other server uses.
    public func databaseSocket(_ kind: DatabaseKind, line: String, port: Int) -> URL {
        let name = kind == .postgresql ? ".s.PGSQL.\(port)" : "\(kind.rawValue)-\(line).sock"
        return run.appending(path: name, directoryHint: .notDirectory)
    }

    // A MongoDB server of a workspace has a socket, because the gate of its port sees with it that
    // the server is ready. mongod names that socket after the port in the folder that it gets.
    public func workspaceDatabaseSocket(_ kind: DatabaseKind, line: String, port: Int) -> URL {
        switch kind {
        case .postgresql:
            databaseSocket(kind, line: line, port: port)
        case .mongodb:
            run.appending(path: "mongodb-\(port).sock", directoryHint: .notDirectory)
        case .mysql, .mariadb:
            run.appending(path: "\(kind.rawValue)-\(line)-\(port).sock", directoryHint: .notDirectory)
        }
    }

    // The clones of the data folders of the instances (D66).
    public var workspaceData: URL {
        data.appending(path: "workspaces", directoryHint: .isDirectory)
    }

    // corepack runs pnpm and yarn for a Node.js app (D67). Node 26 does not ship it, so Nexus
    // installs it from npm into package and puts its links for pnpm and yarn in bin.
    public var corepack: URL { folder("corepack") }

    public var corepackPackage: URL {
        corepack.appending(path: "package", directoryHint: .isDirectory)
    }

    public var corepackLinks: URL {
        corepack.appending(path: "bin", directoryHint: .isDirectory)
    }

    // nexusd installs laravel/installer here with its own Composer (3j). So laravel new needs no
    // global install by the user.
    public var laravelInstaller: URL {
        folder("tools").appending(path: "laravel-installer", directoryHint: .isDirectory)
    }

    public func createFolders(using fileManager: FileManager = .default) throws {
        for folder in allFolders {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func folder(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}
