import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// Turns an installed runtime into the service that runs it. Each kind of service knows its
// program, its standard port and its arguments. Step 2 has Redis. The web servers, PHP and the
// databases follow in steps 4 and 5.
public struct ServiceCatalog: Sendable {
    public static let redisStandardPort = 6379

    private let paths: NexusPaths

    public init(paths: NexusPaths) {
        self.paths = paths
    }

    public func serviceID(for runtime: InstalledRuntime) -> String? {
        switch runtime.name {
        case "redis": "redis-\(runtime.line)"
        default: nil
        }
    }

    public func standardPort(for runtime: InstalledRuntime) -> Int? {
        switch runtime.name {
        case "redis": Self.redisStandardPort
        default: nil
        }
    }

    public func definition(for runtime: InstalledRuntime, port: Int) -> ServiceDefinition? {
        guard let id = serviceID(for: runtime) else {
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
                    "--port", String(port),
                    "--bind", "127.0.0.1",
                    "--dir", data.path(percentEncoded: false),
                    "--databases", "256",
                    "--daemonize", "no",
                    "--logfile", "",
                ],
                workingDirectory: data,
                ports: [port],
                logFile: paths.log(id)
            )
        default:
            return nil
        }
    }
}
