import Testing
@testable import NexusIPC

struct ToolCommandTests {
    let command = ToolCommand(executable: "/php/bin/php", environment: ["PHP_INI_SCAN_DIR": "/config/8.5/conf.d"], coverageFolder: "/config/8.5/coverage.d")

    @Test(arguments: [
        ["vendor/bin/pest", "--coverage"],
        ["artisan", "test", "--coverage", "--min=80"],
        ["vendor/bin/phpunit", "--coverage-html", "build"],
    ])
    func aCommandWithCoverageReadsTheFolderOfPCOVLast(arguments: [String]) {
        #expect(command.environment(for: arguments)["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d:/config/8.5/coverage.d")
    }

    @Test func anotherCommandKeepsPCOVOff() {
        #expect(command.environment(for: ["artisan", "queue:work"])["PHP_INI_SCAN_DIR"] == "/config/8.5/conf.d")
        #expect(ToolCommand(executable: "/node/bin/node").environment(for: ["--coverage"]).isEmpty)
    }
}
