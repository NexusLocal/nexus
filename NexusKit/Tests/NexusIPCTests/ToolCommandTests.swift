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
        #expect(roundTrip == withDumps)
    }
}
