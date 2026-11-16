import Foundation
import Testing
@testable import NexusIPC

struct ToolCommandTests {
    let command = ToolCommand(executable: "/php/bin/php", environment: ["PHP_INI_SCAN_DIR": "/config/8.5/conf.d"], coverageFolder: "/config/8.5/coverage.d")
    let withDumps = ToolCommand(executable: "/php/bin/php", environment: ["PHP_INI_SCAN_DIR": "/config/8.5/conf.d"], coverageFolder: "/config/8.5/coverage.d", dumpsFolder: "/config/8.5/dumps.d")

    @Test(arguments: [
        ["vendor/bin/pest", "--coverage"],
        ["artisan", "test", "--coverage", "--min=80"],
        ["vendor/bin/phpunit", "--coverage-html", "build"],
        ["vendor/bin/pest", "--tia"],
        ["vendor/bin/pest", "--mutate", "--parallel"],
    ])
    func aCommandWithCoverageReadsTheFolderOfPCOVLast(arguments: [String]) {
        #expect(command.environment(for: arguments)["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/coverage.d")
    }

    @Test func anotherCommandKeepsPCOVOff() {
        #expect(command.environment(for: ["artisan", "queue:work"])["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d")
        #expect(ToolCommand(executable: "/node/bin/node").environment(for: ["--coverage"]).isEmpty)
    }

    @Test(arguments: [
        [],
        ["artisan", "queue:work"],
        ["artisan", "test"],
        ["vendor/bin/pest"],
    ])
    func eachCommandReadsTheFolderOfTheDumpViewerLast(arguments: [String]) {
        #expect(withDumps.environment(for: arguments)["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/dumps.d")
    }

    @Test func coverageAndTheDumpViewerCanBeOnTogether() {
        #expect(withDumps.environment(for: ["vendor/bin/pest", "--coverage"])["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/coverage.d:/config/8.5/dumps.d")
        #expect(ToolCommand(executable: "/php/bin/php", dumpsFolder: "/config/8.5/dumps.d").environment(for: ["artisan", "tinker"])["PHP_INI_SCAN_DIR"] == "/config/8.5/dumps.d")
    }

    @Test func aCommandOfAnOlderNexusdHasNoFolderOfTheDumpViewer() throws {
        let old = Data(#"{"executable":"/php/bin/php","arguments":[],"environment":{},"path":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(ToolCommand.self, from: old)
        let roundTrip = try JSONDecoder().decode(ToolCommand.self, from: try JSONEncoder().encode(withDumps))

        #expect(decoded.dumpsFolder == nil)
        #expect(decoded.xdebugFolder == nil)
        #expect(roundTrip == withDumps)
    }

    @Test func aDebugCommandReadsTheFolderOfXdebugAfterConfD() {
        let debug = ToolCommand(executable: "/php/bin/php", environment: ["PHP_INI_SCAN_DIR": "/config/8.5/conf.d"], coverageFolder: "/config/8.5/coverage.d", xdebugFolder: "/config/8.5/xdebug.d")

        let environment = debug.environment(for: ["artisan", "my:command"])

        #expect(environment["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/xdebug.d")
        #expect(environment["XDEBUG_SESSION"] == "nexus")
        #expect(environment["COMPOSER_ALLOW_XDEBUG"] == "1")
    }

    @Test func debugCoverageAndTheDumpViewerCanBeOnTogether() {
        var debug = withDumps
        debug.xdebugFolder = "/config/8.5/xdebug.d"

        let environment = debug.environment(for: ["artisan", "test", "--coverage"])

        #expect(environment["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/xdebug.d:/config/8.5/coverage.d:/config/8.5/dumps.d")
    }

    @Test func aCommandWithoutTheFolderOfXdebugNeverLoadsXdebug() {
        let environment = withDumps.environment(for: ["artisan", "queue:work"])

        #expect(environment["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/dumps.d")
        #expect(environment["XDEBUG_SESSION"] == nil)
        #expect(environment["COMPOSER_ALLOW_XDEBUG"] == nil)
    }

    @Test func anOlderNexusCommandSendsNoDebugKey() throws {
        let encoded = String(decoding: try JSONEncoder().encode(NexusRequest.tool(.php, folder: "/Sites/shop", debug: true)), as: UTF8.self)
        let old = Data(#"{"tool":{"_0":"php","folder":"/Sites/shop"}}"#.utf8)

        let decoded = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: old)

        #expect(encoded.contains(#""debug":true"#))
        #expect(encoded.contains(#""_0":"php""#))
        #expect(decoded == .tool(.php, folder: "/Sites/shop", argumentFolder: nil, debug: nil))
    }
}
