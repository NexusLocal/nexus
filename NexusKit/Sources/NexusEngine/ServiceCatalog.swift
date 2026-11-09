import Foundation
import NexusConfig
import NexusCore
import NexusMail
import NexusRuntime
import NexusSupervisor

public struct PortRequirement: Sendable, Equatable {
    public let key: String
    public let standard: Int
}

// Turns an installed runtime into the service that runs it. Each kind of service knows its
// program, its ports and its arguments. Each version line of a database is one instance, with
// its own port and data folder (D34).
public struct ServiceCatalog: Sendable {
    public static let redisStandardPort = 6379
    // A workspace uses the indexes from 16 up, below this number (D47). Do not make it lower. Redis
    // does not start with a data file that holds a higher index.
    public static let redisDatabaseCount = 256
    public static let nginxID = ServiceID.nginx
    public static let apacheID = ServiceID.apache
    public static let httpPortKey = "http"
    public static let httpsPortKey = "https"
    // The mail service has three ports. nexusd itself listens on the SMTP port. Mailpit gets the
    // inbox and an SMTP port of its own, which only nexusd uses (Phase 3, 3b).
    public static let mailID = ServiceID.mail
    public static let smtpPortKey = ServiceID.smtpPortKey
    public static let inboxPortKey = ServiceID.inboxPortKey
    public static let mailpitSMTPPortKey = ServiceID.mailpitSMTPPortKey
    public static let smtpStandardPort = 1025
    public static let standardInboxMails = 1000
    public static let databaseStartTimeout: Duration = .seconds(30)
    // A stop of nexusd first waits for the background processes, 10 seconds at most. ExitTimeOut in
    // the launchd plist of nexusd must stay longer than these two times together, or launchd kills
    // a database while it writes its data to disk.
    public static let databaseStopTimeout: Duration = .seconds(30)

    // Every PHP process forks without exec. The Objective-C runtime and the system log of macOS
    // both crash in such a child: the first at +initialize (D26), the second when the SQLite of
    // macOS writes its first log line. 9 of 80 forks crashed without the second setting, 0 of 80
    // with it.
    public static let phpEnvironment = [
        "OBJC_DISABLE_INITIALIZE_FORK_SAFETY": "YES",
        "OS_ACTIVITY_MODE": "disable",
    ]

    private let paths: NexusPaths

    public init(paths: NexusPaths) {
        self.paths = paths
    }

    public static func phpID(line: String) -> String {
        ServiceID.php(line: line)
    }

    public func serviceID(for runtime: InstalledRuntime) -> String? {
        ServiceID.of(package: runtime.name, line: runtime.line)
    }

    public static func databaseKind(of runtime: InstalledRuntime) -> DatabaseKind? {
        DatabaseKind(rawValue: runtime.name)
    }

    // The ports of a service, each with a key in the port registry of the state. nginx has two:
    // "http" and "https". Apache only listens on 127.0.0.1, behind nginx.
    public func portRequirements(for runtime: InstalledRuntime) -> [PortRequirement] {
        switch runtime.name {
        case "redis": [PortRequirement(key: ServiceID.redis(line: runtime.line), standard: Self.redisStandardPort)]
        case "nginx": [PortRequirement(key: Self.httpPortKey, standard: 80), PortRequirement(key: Self.httpsPortKey, standard: 443)]
        case "httpd": [PortRequirement(key: Self.apacheID, standard: 8081)]
        case "mailpit": [
            PortRequirement(key: Self.smtpPortKey, standard: Self.smtpStandardPort),
            PortRequirement(key: Self.inboxPortKey, standard: 8025),
            PortRequirement(key: Self.mailpitSMTPPortKey, standard: 1026),
        ]
        default:
            if let kind = Self.databaseKind(of: runtime), let id = serviceID(for: runtime) {
                [PortRequirement(key: id, standard: kind.standardPort)]
            } else {
                []
            }
        }
    }

    public func definition(for runtime: InstalledRuntime, ports: [String: Int], inboxMails: Int = standardInboxMails) -> ServiceDefinition? {
        guard let id = serviceID(for: runtime) else {
            return nil
        }

        let requiredPorts = portRequirements(for: runtime).compactMap { ports[$0.key] }
        guard requiredPorts.count == portRequirements(for: runtime).count else {
            return nil
        }

        switch runtime.name {
        case "redis":
            let data = paths.dataFolder(service: "redis", line: runtime.line)
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

            return ServiceDefinition(
                id: id,
                displayName: "Redis \(runtime.version)",
                executable: runtime.folder.appending(path: "bin/redis-server"),
                arguments: [
                    "--port", String(requiredPorts[0]),
                    "--bind", "127.0.0.1",
                    "--dir", data.path(percentEncoded: false),
                    "--databases", String(Self.redisDatabaseCount),
                    "--daemonize", "no",
                    "--logfile", "",
                ],
                workingDirectory: data,
                ports: requiredPorts,
                logFile: paths.log(id)
            )
        case "nginx":
            let folder = paths.nginxConfig.deletingLastPathComponent()

            return ServiceDefinition(
                id: id,
                displayName: "nginx \(runtime.version)",
                executable: runtime.folder.appending(path: "sbin/nginx"),
                arguments: ["-p", folder.path(percentEncoded: false), "-c", paths.nginxConfig.path(percentEncoded: false), "-e", "stderr"],
                workingDirectory: folder,
                ports: requiredPorts,
                logFile: paths.log(id)
            )
        case "httpd":
            return ServiceDefinition(
                id: id,
                displayName: "Apache \(runtime.version)",
                executable: runtime.folder.appending(path: "bin/httpd"),
                arguments: ["-f", paths.apacheConfig.path(percentEncoded: false), "-DFOREGROUND"],
                workingDirectory: paths.apacheConfig.deletingLastPathComponent(),
                ports: requiredPorts,
                logFile: paths.log(id)
            )
        case "php":
            let folder = paths.phpConfigFolder(line: runtime.line)

            return ServiceDefinition(
                id: id,
                displayName: "PHP \(runtime.version)",
                executable: runtime.folder.appending(path: "sbin/php-fpm"),
                arguments: [
                    "--nodaemonize",
                    "--fpm-config", folder.appending(path: "php-fpm.conf").path(percentEncoded: false),
                    "-c", folder.appending(path: "php.ini").path(percentEncoded: false),
                ],
                environment: Self.phpEnvironment.merging(["PHP_INI_SCAN_DIR": folder.appending(path: "conf.d").path(percentEncoded: false)]) { _, new in new },
                workingDirectory: folder,
                logFile: paths.log(id)
            )
        case "mailpit":
            let data = dataFolder(for: runtime)
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

            return ServiceDefinition(
                id: id,
                displayName: "Mailpit \(runtime.version)",
                executable: runtime.folder.appending(path: "bin/mailpit"),
                arguments: Self.mailpitArguments(smtpPort: requiredPorts[2], inboxPort: requiredPorts[1], database: data.appending(path: "mailpit.db"), inboxMails: inboxMails),
                workingDirectory: data,
                ports: [requiredPorts[1], requiredPorts[2]],
                logFile: paths.log(id)
            )
        default:
            guard let kind = Self.databaseKind(of: runtime) else {
                return nil
            }

            return databaseDefinition(kind, id: id, displayName: "\(kind.displayName) \(runtime.version)", runtime: runtime, port: requiredPorts[0], data: dataFolder(for: runtime), socket: paths.databaseSocket(kind, line: runtime.line, port: requiredPorts[0]), logFile: paths.log(id), extra: [])
        }
    }

    public func dataFolder(for runtime: InstalledRuntime) -> URL {
        paths.dataFolder(service: runtime.name, line: runtime.line)
    }

    // The default of Mailpit is 0.0.0.0, so both addresses are set. Mailpit refuses a login
    // without TLS unless it gets --smtp-auth-allow-insecure. The user name of the login becomes
    // the tag of the mail. Nexus never gives a relay option, so no mail leaves the Mac. Mailpit
    // takes 100 recipients by default, and the receiver of nexusd takes more.
    static func mailpitArguments(smtpPort: Int, inboxPort: Int, database: URL, inboxMails: Int) -> [String] {
        [
            "--smtp", "127.0.0.1:\(smtpPort)",
            "--listen", "127.0.0.1:\(inboxPort)",
            "--database", database.path(percentEncoded: false),
            "--max", String(inboxMails),
            "--smtp-max-recipients", String(SMTPSession.maxRecipients),
            "--smtp-auth-accept-any",
            "--smtp-auth-allow-insecure",
            "--tags-username",
            "--disable-version-check",
        ]
    }

    // The server of a workspace (D66). It has a small buffer pool and no performance_schema, because
    // a Mac with 8 GB of memory must also run several workspaces. Its log goes to the log of the
    // instance.
    public func workspaceServerDefinition(id: String, instance: String, runtime: InstalledRuntime, port: Int, folder: URL, environment: [String: String]) -> ServiceDefinition? {
        guard let kind = Self.databaseKind(of: runtime) else {
            return nil
        }

        let extra = kind.usesMySQLProtocol
            ? ["--innodb-buffer-pool-size=33554432", "--performance-schema=OFF", "--key-buffer-size=8388608", "--table-open-cache=400"]
            : ["-c", "shared_buffers=32MB"]

        return databaseDefinition(kind, id: id, displayName: "\(kind.displayName) \(runtime.version) of a workspace", runtime: runtime, port: port, data: folder, socket: paths.workspaceDatabaseSocket(kind, line: runtime.line, port: port), logFile: paths.log(instance), extra: extra, environment: environment)
    }

    private func databaseDefinition(_ kind: DatabaseKind, id: String, displayName: String, runtime: InstalledRuntime, port: Int, data: URL, socket: URL, logFile: URL, extra: [String], environment: [String: String] = [:]) -> ServiceDefinition {
        guard kind.usesMySQLProtocol else {
            return ServiceDefinition(
                id: id,
                displayName: displayName,
                executable: runtime.folder.appending(path: "bin/postgres"),
                arguments: [
                    "-D", data.path(percentEncoded: false),
                    "-p", String(port),
                    "-k", socket.deletingLastPathComponent().path(percentEncoded: false),
                    "-c", "listen_addresses=127.0.0.1",
                ] + extra,
                environment: environment,
                workingDirectory: data,
                ports: [port],
                logFile: logFile,
                stopSignal: SIGINT,
                startTimeout: Self.databaseStartTimeout,
                stopTimeout: Self.databaseStopTimeout
            )
        }

        var arguments = [
            "--defaults-file=\(paths.databaseConfig(kind, line: runtime.line).path(percentEncoded: false))",
            "--basedir=\(runtime.folder.path(percentEncoded: false))",
            "--datadir=\(data.path(percentEncoded: false))",
            "--port=\(port)",
            "--bind-address=127.0.0.1",
            "--socket=\(socket.path(percentEncoded: false))",
            "--pid-file=\(socket.deletingPathExtension().appendingPathExtension("pid").path(percentEncoded: false))",
        ]

        // The X Protocol of MySQL listens on port 33060 in every instance. So a second instance
        // would not start. No tool of Nexus reads the binary log, and each restore writes each row
        // into it.
        if kind == .mysql {
            arguments += ["--mysqlx=OFF", "--skip-log-bin"]
        }

        return ServiceDefinition(
            id: id,
            displayName: displayName,
            executable: runtime.folder.appending(path: kind == .mysql ? "bin/mysqld" : "bin/mariadbd"),
            arguments: arguments + extra,
            environment: environment,
            workingDirectory: data,
            ports: [port],
            logFile: logFile,
            startTimeout: Self.databaseStartTimeout,
            stopTimeout: Self.databaseStopTimeout
        )
    }
}
