import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

public struct PortRequirement: Sendable, Equatable {
    public let key: String
    public let standard: Int
}

// Turns an installed runtime into the service that runs it. Each kind of service knows its
// program, its ports and its arguments. The databases follow in step 5.
public struct ServiceCatalog: Sendable {
    public static let redisStandardPort = 6379
    public static let nginxID = "nginx"
    public static let apacheID = "apache"
    public static let httpPortKey = "http"
    public static let httpsPortKey = "https"

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
        default: nil
        }
    }

    // The ports of a service, each with a key in the port registry of the state. nginx has two:
    // "http" and "https". Apache only listens on 127.0.0.1, behind nginx.
    public func portRequirements(for runtime: InstalledRuntime) -> [PortRequirement] {
        switch runtime.name {
        case "redis": [PortRequirement(key: "redis-\(runtime.line)", standard: Self.redisStandardPort)]
        case "nginx": [PortRequirement(key: Self.httpPortKey, standard: 80), PortRequirement(key: Self.httpsPortKey, standard: 443)]
        case "httpd": [PortRequirement(key: Self.apacheID, standard: 8081)]
        default: []
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
                    "--databases", "256",
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
            return nil
        }
    }
}
