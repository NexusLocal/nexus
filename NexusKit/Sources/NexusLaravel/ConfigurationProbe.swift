import Foundation
import NexusCore
import NexusSupervisor

public enum ProbeError: Error, Equatable, CustomStringConvertible {
    case notLaravel(folder: String)
    case noDependencies
    case cachedConfiguration
    case notLoaded(String)
    case markerRejected(String)
    case timedOut

    public var description: String {
        switch self {
        case .notLaravel(let folder):
            "\(folder) is not in a Laravel application. Nexus found no folder with both an artisan file and bootstrap/app.php."
        case .noDependencies:
            "The application has no vendor/autoload.php. Run composer install first."
        case .cachedConfiguration:
            "The application has bootstrap/cache/config.php. A cached configuration ignores the environment. Run php artisan config:clear, and then run the probe again."
        case .notLoaded(let reason):
            "The configuration of the application does not load: \(reason)"
        case .markerRejected(let reason):
            "The configuration of the application loads with its real values. It does not load with the test value that the probe gives each env key: \(reason)"
        case .timedOut:
            "The application did not load its configuration in \(Int(ConfigurationProbe.timeout.components.seconds)) seconds."
        }
    }
}

// Finds which env key feeds each setting of a Laravel application (D43). A pass with the real
// environment gives the values. A pass with a text marker and a pass with a numeric marker for
// each env key give the keys. A real environment value wins over .env in Laravel. A last pass does
// what a workspace does: it changes only the keys of the database names and the Redis indexes.
// A marker on every key also turns on a flag such as USE_X, and a workspace leaves this flag as it
// is. A key that the probe does not find gives a fixed setting. Nexus does not isolate a fixed
// setting (D48), so a missed key cannot make a workspace write into the main database.
public struct ConfigurationProbe: Sendable {
    public static let timeout: Duration = .seconds(30)

    private static let sections = ["database.", "session.", "cache.", "queue.", "broadcasting.", "reverb."]

    private let php: URL
    private let environment: [String: String]
    private let timeout: Duration

    public init(php: URL, environment: [String: String], timeout: Duration = Self.timeout) {
        self.php = php
        self.environment = environment
        self.timeout = timeout
    }

    public func run(root: URL) async throws -> LaravelConfiguration {
        let file = { (path: String) in FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) }

        guard !file("bootstrap/cache/config.php") else {
            throw ProbeError.cachedConfiguration
        }

        guard file("vendor/autoload.php") else {
            throw ProbeError.noDependencies
        }

        let processEnvironment = ChildEnvironment.base().merging(environment) { _, own in own }
        let keys = LaravelProject.envKeys(of: root).filter { processEnvironment[$0] == nil }
        let markers = ProbeMarkers(keys: keys)
        let real = try await pass(root: root, markers: [:])
        async let textPass = markerPass(root: root, markers: markers.textEnvironment)
        async let numericPass = markerPass(root: root, markers: markers.numericEnvironment)
        let (text, numeric) = try await (textPass, numericPass)

        let wanted = real.settings.filter { path, _ in path == "app.url" || Self.sections.contains { path.hasPrefix($0) } }
        var settings = wanted.reduce(into: [String: ConfigSetting]()) { settings, entry in
            settings[entry.key] = markers.setting(value: entry.value, textPass: text.settings[entry.key], numericPass: numeric.settings[entry.key])
        }

        let databaseNames = real.databaseConnections.map { "database.connections.\($0).database" }
        let redisIndexes = real.redisConnections.map { "database.redis.\($0).database" }
        let workspaceMarkers = markers.workspaceEnvironment(
            databaseKeys: databaseNames.flatMap { settings[$0]?.keys ?? [] },
            redisKeys: redisIndexes.flatMap { settings[$0]?.keys ?? [] }
        )
        let workspace = try await markerPass(root: root, markers: workspaceMarkers)

        for path in databaseNames + redisIndexes {
            if let value = real.settings[path] {
                settings[path] = markers.setting(value: value, textPass: workspace.settings[path], numericPass: workspace.settings[path])
            }
        }

        return LaravelConfiguration(version: real.version, settings: settings, databaseConnections: real.databaseConnections, redisConnections: real.redisConnections)
    }

    // The real pass came first and it worked. So a failure here comes from a marker value, for
    // example in a match on APP_ENV without a default arm.
    private func markerPass(root: URL, markers: [String: String]) async throws -> ProbePass {
        do {
            return try await pass(root: root, markers: markers)
        } catch ProbeError.notLoaded(let reason) {
            throw ProbeError.markerRejected(reason)
        }
    }

    // Xdebug is off, because a listening editor could otherwise stop a pass until the timeout.
    private func pass(root: URL, markers: [String: String]) async throws -> ProbePass {
        let command = Command(
            executable: php,
            arguments: ["-d", "xdebug.mode=off", "-r", ProbeScript.source, "--", RealPath.trimmed(root.path(percentEncoded: false))],
            environment: environment.merging(markers) { _, marker in marker },
            workingDirectory: root,
            stopSignal: SIGKILL
        )

        do {
            return try await result(of: output(of: command))
        } catch let failure as CommandError {
            throw ProbeError.notLoaded(failure.description)
        }
    }

    private func output(of command: Command) async throws -> CommandOutput {
        try await withThrowingTaskGroup(of: CommandOutput?.self) { group in
            group.addTask { try await CommandRunner.run(command) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            defer { group.cancelAll() }

            guard let finished = try await group.next(), let output = finished else {
                throw ProbeError.timedOut
            }

            return output
        }
    }

    private func result(of output: CommandOutput) throws -> ProbePass {
        guard let separator = output.standardOutput.range(of: ProbeScript.separator, options: .backwards) else {
            let reason = output.standardError.isEmpty ? output.standardOutput : output.standardError
            throw ProbeError.notLoaded(reason.isEmpty ? "PHP stopped before it gave a result." : String(reason.suffix(2000)))
        }

        let text = output.standardOutput[separator.upperBound...]

        guard let result = try? JSONDecoder().decode(ProbeResult.self, from: Data(text.utf8)) else {
            throw ProbeError.notLoaded("Nexus cannot read the result of PHP: \(text.suffix(200))")
        }

        guard let configuration = result.configuration else {
            throw ProbeError.notLoaded(result.error ?? "PHP gave no configuration.")
        }

        return configuration
    }
}

private struct ProbeResult: Decodable {
    let error: String?
    let configuration: ProbePass?
}

private struct ProbePass: Decodable {
    let version: String
    let settings: [String: ConfigValue]
    let databaseConnections: [String]
    let redisConnections: [String]
}
