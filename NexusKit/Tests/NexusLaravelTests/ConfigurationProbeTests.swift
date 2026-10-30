import Foundation
import NexusCore
import Testing
@testable import NexusLaravel

struct ConfigurationProbeTests {
    private struct Application {
        let root: URL
        let php: URL
    }

    private func application(php script: String, files: [String: String] = [:]) throws -> Application {
        let root = FileManager.default.temporaryDirectory.appending(path: "nexus-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = [
            "artisan": "",
            "bootstrap/app.php": "",
            "vendor/autoload.php": "",
            "config/database.php": "<?php env('DB_DATABASE'); env('REDIS_DB'); env('PATH'); env('PHPRC');",
        ]

        for (path, text) in defaults.merging(files, uniquingKeysWith: { _, own in own }) {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        let php = root.appending(path: "php")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: php)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path(percentEncoded: false))
        return Application(root: root, php: php)
    }

    private let answer = #"""
    printf 'noise from the application\n@@nexus-probe@@{"configuration":{"version":"12.0.0","settings":{"database.default":"main","database.connections.main.database":"%s","database.redis.default.database":%s,"services.mail.key":"secret","app.url":"https://shop.test"},"databaseConnections":["main"],"redisConnections":["default"]}}' "${DB_DATABASE:-shop}" "${REDIS_DB:-1}" | sed 's/:\([0-9]*\)nxm}/:\1}/; s/:\([0-9]*\)nxm,/:\1,/'
    """#

    @Test func theRealPassGivesTheValuesAndTheMarkerPassesGiveTheKeys() async throws {
        let application = try application(php: answer)
        defer { try? FileManager.default.removeItem(at: application.root) }

        let configuration = try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)

        #expect(configuration.version == "12.0.0")
        #expect(configuration.databaseConnections == ["main"])
        #expect(configuration.redisConnections == ["default"])
        #expect(configuration.settings["database.default"] == ConfigSetting(value: .text("main")))
        #expect(configuration.settings["database.connections.main.database"] == ConfigSetting(value: .text("shop"), keys: ["DB_DATABASE"], exact: true))
        #expect(configuration.settings["database.redis.default.database"] == ConfigSetting(value: .number(1), keys: ["REDIS_DB"], exact: true))
        #expect(configuration.settings["app.url"] == ConfigSetting(value: .text("https://shop.test")))
    }

    @Test func aSectionThatNexusDoesNotUseIsLeftOut() async throws {
        let application = try application(php: answer)
        defer { try? FileManager.default.removeItem(at: application.root) }

        let configuration = try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)

        #expect(configuration.settings["services.mail.key"] == nil)
    }

    @Test func aMarkerNeverReplacesTheEnvironmentOfTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "nexus-probe-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let application = try application(php: "echo \"$PATH $PHPRC\" >> '\(marker.path(percentEncoded: false))'\n\(answer)")
        defer { try? FileManager.default.removeItem(at: application.root) }

        _ = try await ConfigurationProbe(php: application.php, environment: ["PHPRC": "/nexus/php.ini"]).run(root: application.root)

        let lines = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isNewline)
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { !$0.contains("nxm") && $0.hasSuffix("/nexus/php.ini") })
    }

    @Test func aCachedConfigurationStopsTheProbeBeforePHPStarts() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "nexus-probe-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let application = try application(php: "touch '\(marker.path(percentEncoded: false))'", files: ["bootstrap/cache/config.php": "<?php return [];"])
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.cachedConfiguration) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test func anApplicationWithoutItsDependenciesStopsTheProbe() async throws {
        let application = try application(php: answer)
        defer { try? FileManager.default.removeItem(at: application.root) }
        try FileManager.default.removeItem(at: application.root.appending(path: "vendor"))

        await #expect(throws: ProbeError.noDependencies) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func anErrorInTheApplicationGivesItsMessage() async throws {
        let application = try application(php: #"printf '@@nexus-probe@@{"error":"RuntimeException: no such file in config/app.php:3"}'"#)
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.notLoaded("RuntimeException: no such file in config/app.php:3")) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPHPThatHangsIsStoppedAtTheTimeout() async throws {
        let application = try application(php: "exec sleep 300")
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.timedOut) {
            try await ConfigurationProbe(php: application.php, environment: [:], timeout: .milliseconds(200)).run(root: application.root)
        }
    }

    @Test func aPHPThatStopsWithoutAResultGivesItsErrorOutput() async throws {
        let application = try application(php: "echo 'Parse error' >&2")
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.notLoaded("Parse error\n")) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func aPHPThatStopsWithOnlyNormalOutputGivesThatOutput() async throws {
        let application = try application(php: "printf 'Site is down'")
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.notLoaded("Site is down")) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func aPHPThatExitsWithAnErrorStatusGivesItsErrorOutput() async throws {
        let application = try application(php: "echo 'The environment file is invalid!' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.notLoaded("php stopped with exit status 1: The environment file is invalid!")) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func aConfigurationThatRejectsAMarkerSaysThatTheMarkerIsTheCause() async throws {
        let failure = #"printf '@@nexus-probe@@{"error":"UnhandledMatchError: Unhandled match case"}'; exit 0"#
        let application = try application(php: "case \"$DB_DATABASE\" in *[0-9]*) \(failure);; esac\n\(answer)")
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.markerRejected("UnhandledMatchError: Unhandled match case")) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func textAfterTheResultGivesAClearFailure() async throws {
        let application = try application(php: #"printf '@@nexus-probe@@{"configuration":{}} bye'"#)
        defer { try? FileManager.default.removeItem(at: application.root) }

        await #expect(throws: ProbeError.self) {
            try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)
        }
    }

    @Test func xdebugIsOffInEachPass() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "nexus-probe-arguments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let application = try application(php: "echo \"$1 $2\" >> '\(marker.path(percentEncoded: false))'\n\(answer)")
        defer { try? FileManager.default.removeItem(at: application.root) }

        _ = try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)

        let lines = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isNewline)
        #expect(lines == Array(repeating: "-d xdebug.mode=off", count: 4))
    }

    @Test func aDatabaseKeyBehindAFlagThatIsOffIsNotAKeyOfThatSetting() async throws {
        let script = #"""
        if [ -n "$USE_X" ]; then name="$X_DB"; else name=main; fi
        printf '@@nexus-probe@@{"configuration":{"version":"12.0.0","settings":{"database.connections.x.database":"%s","database.flag":"%s"},"databaseConnections":["x"],"redisConnections":[]}}' "$name" "$USE_X"
        """#
        let application = try application(php: script, files: ["config/database.php": "<?php env('USE_X'); env('X_DB');"])
        defer { try? FileManager.default.removeItem(at: application.root) }

        let configuration = try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)

        #expect(configuration.settings["database.connections.x.database"] == ConfigSetting(value: .text("main")))
        #expect(configuration.settings["database.flag"]?.keys == ["USE_X"])
    }

    @Test func aRedisIndexThatOnlyAcceptsANumberKeepsItsKey() async throws {
        let script = #"""
        case "$REDIS_DB" in *nxm|'') index=1;; *) index="$REDIS_DB";; esac
        printf '@@nexus-probe@@{"configuration":{"version":"12.0.0","settings":{"database.redis.default.database":%s},"databaseConnections":[],"redisConnections":["default"]}}' "$index"
        """#
        let application = try application(php: script)
        defer { try? FileManager.default.removeItem(at: application.root) }

        let configuration = try await ConfigurationProbe(php: application.php, environment: [:]).run(root: application.root)

        #expect(configuration.settings["database.redis.default.database"] == ConfigSetting(value: .number(1), keys: ["REDIS_DB"], exact: true))
    }
}
