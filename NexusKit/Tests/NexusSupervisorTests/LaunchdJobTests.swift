import Foundation
import Testing
@testable import NexusSupervisor

struct LaunchdJobTests {
    private let list = """
        PID\tStatus\tLabel
        -\t0\tcom.apple.SafariHistoryServiceAgent
        1463\t0\thomebrew.mxcl.mailpit
        500\t0\thomebrew.mxcl.mysql@8.4
        62615\t0\tnl.roodfruit.nexus.daemon

        """

    @Test func theProgramOfAHomebrewServiceGetsItsFormula() {
        let job = LaunchdJob.of(pid: 1463, list: list) { _ in nil }

        #expect(job == LaunchdJob(label: "homebrew.mxcl.mailpit", pid: 1463))
        #expect(job?.homebrewFormula == "mailpit")
    }

    @Test func aChildOfAJobGetsTheJobOfItsParent() {
        let table: [Int32: ProcessEntry] = [
            600: ProcessEntry(parent: 500, user: 501, command: "mysqld"),
            500: ProcessEntry(parent: 1, user: 501, command: "mysqld_safe"),
        ]

        let job = LaunchdJob.of(pid: 600, list: list) { table[$0] }

        #expect(job?.homebrewFormula == "mysql@8.4")
    }

    @Test func theBrewComesFromTheFolderOfTheProgramOrFromEachHomebrewFolder() {
        let both: (String) -> Bool = { _ in true }
        let intel: (String) -> Bool = { $0 == "/usr/local/bin/brew" }

        #expect(LaunchdJob.brew(for: "/usr/local/Cellar/redis/8.2/bin/redis-server", exists: both)?.path(percentEncoded: false) == "/usr/local/bin/brew")
        #expect(LaunchdJob.brew(for: nil, exists: both)?.path(percentEncoded: false) == "/opt/homebrew/bin/brew")
        #expect(LaunchdJob.brew(for: nil, exists: intel)?.path(percentEncoded: false) == "/usr/local/bin/brew")
        #expect(LaunchdJob.brew(for: "/Applications/Other.app/Contents/MacOS/x", exists: both) == nil)
    }

    // Stops a real Homebrew service. So it runs only when the variable names the port of that
    // service. Start the service again after the test, for example: brew services start mailpit
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_STOP_HOMEBREW_SERVICE_ON_PORT"] != nil))
    func aRealHomebrewServiceStopsAndLaunchdDoesNotStartItAgain() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["NEXUS_STOP_HOMEBREW_SERVICE_ON_PORT"].flatMap { Int($0) })
        let owner = try #require(PortInspector.owner(of: port))
        let job = try #require(await LaunchdJob.of(pid: owner.mainPID ?? owner.pid))

        try await job.stopHomebrewService(executable: owner.executable)
        let freed = await PortInspector.becomesFree(port, within: .seconds(10))
        try await Task.sleep(for: .seconds(3))

        #expect(job.homebrewFormula != nil)
        #expect(freed)
        #expect(PortInspector.isFree(port))
    }

    @Test func aProgramWithoutAJobOrWithAnotherJobIsNoHomebrewService() {
        let none = LaunchdJob.of(pid: 700, list: list) { _ in ProcessEntry(parent: 1, user: 501, command: "httpd") }
        let other = LaunchdJob.of(pid: 62615, list: list) { _ in nil }

        #expect(none == nil)
        #expect(other?.homebrewFormula == nil)
    }
}
