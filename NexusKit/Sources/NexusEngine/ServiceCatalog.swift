import Foundation
import NexusCore
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
    public static let nginxID = "nginx"
    public static let apacheID = "apache"
    public static let httpPortKey = "http"
    public static let httpsPortKey = "https"
    public static let databaseStartTimeout: Duration = .seconds(30)
    // ExitTimeOut in the launchd plist of nexusd must stay longer, or launchd kills a database
    // while it writes its data to disk.
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
        "php-\(line)"
    }

    public func serviceID(for runtime: InstalledRuntime) -> String? {
        switch runtime.name {
        case "redis": "redis-\(runtime.line)"
        case "nginx": Self.nginxID
        case "httpd": Self.apacheID
        case "php": Self.phpID(line: runtime.line)
        default: Self.databaseKind(of: runtime).map { "\($0.rawValue)-\(runtime.line)" }
        }
    }

    public static func databaseKind(of runtime: InstalledRuntime) -> DatabaseKind? {
        DatabaseKind(rawValue: runtime.name)
    }

    // The ports of a service, each with a key in the port registry of the state. nginx has two:
    // "http" and "https". Apache only listens on 127.0.0.1, behind nginx.
    public func portRequirements(for runtime: InstalledRuntime) -> [PortRequirement] {
        switch runtime.name {
        case "redis": [PortRequirement(key: "redis-\(runtime.line)", standard: Self.redisStandardPort)]
        case "nginx": [PortRequirement(key: Self.httpPortKey, standard: 80), PortRequirement(key: Self.httpsPortKey, standard: 443)]
        case "httpd": [PortRequirement(key: Self.apacheID, standard: 8081)]
        default:
            if let kind = Self.databaseKind(of: runtime), let id = serviceID(for: runtime) {
                [PortRequirement(key: id, standard: kind.standardPort)]
            } else {
                []
            }
        }
    }

    public func definition(for runtime: InstalledRuntime, ports: [String: Int]) -> ServiceDefinition? {
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
        default:
            guard let kind = Self.databaseKind(of: runtime) else {
                return nil
            }

            return databaseDefinition(kind, id: id, runtime: runtime, port: requiredPorts[0])
        }
    }

    public func dataFolder(for runtime: InstalledRuntime) -> URL {
        paths.dataFolder(service: runtime.name, line: runtime.line)
    }

    private func databaseDefinition(_ kind: DatabaseKind, id: String, runtime: InstalledRuntime, port: Int) -> ServiceDefinition {
        let data = dataFolder(for: runtime)
        let socket = paths.databaseSocket(kind, line: runtime.line, port: port)

        guard kind.usesMySQLProtocol else {
            return ServiceDefinition(
                id: id,
                displayName: "\(kind.displayName) \(runtime.version)",
                executable: runtime.folder.appending(path: "bin/postgres"),
                arguments: [
                    "-D", data.path(percentEncoded: false),
                    "-p", String(port),
                    "-k", socket.deletingLastPathComponent().path(percentEncoded: false),
                    "-c", "listen_addresses=127.0.0.1",
                ],
                workingDirectory: data,
                ports: [port],
                logFile: paths.log(id),
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
            "--pid-file=\(paths.run.appending(path: "\(id).pid").path(percentEncoded: false))",
        ]

        // The X Protocol of MySQL listens on port 33060 in every instance. So a second instance
        // would not start.
        if kind == .mysql {
            arguments.append("--mysqlx=OFF")
        }

        return ServiceDefinition(
            id: id,
            displayName: "\(kind.displayName) \(runtime.version)",
            executable: runtime.folder.appending(path: kind == .mysql ? "bin/mysqld" : "bin/mariadbd"),
            arguments: arguments,
            workingDirectory: data,
            ports: [port],
            logFile: paths.log(id),
            startTimeout: Self.databaseStartTimeout,
            stopTimeout: Self.databaseStopTimeout
        )
    }
}
