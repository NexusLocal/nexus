import Foundation
import Testing
@testable import NexusIPC

struct NexusdVersionCheckTests {
    @Test func aNexusdWithTheBuildOfTheAppNeedsNoRestart() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "12")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(!restarts)
        #expect(!check.restartDidNotHelp)
    }

    @Test func aNexusdWithAnotherBuildRestartsOneTime() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        let first = check.takeRestart(tasksRun: false)
        let second = check.takeRestart(tasksRun: false)

        #expect(first)
        #expect(!second)
    }

    @Test func aNexusdWithoutABuildCountsAsOld() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: nil)
        let restarts = check.takeRestart(tasksRun: false)

        #expect(restarts)
    }

    @Test func aNexusdThatStartsTheBuildOfTheAppGetsNoRestartFromTheApp() {
        var check = NexusdVersionCheck(appBuild: "13")

        check.received(build: "12", updateBuild: "13")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(!restarts)
    }

    @Test func aNexusdThatStartsTheBuildOfTheAppShowsNoProblemWhileItsWorkRuns() {
        var check = NexusdVersionCheck(appBuild: "13", lastRestartBuild: "13")

        check.received(build: "12", updateBuild: "13")

        #expect(!check.restartDidNotHelp)
    }

    // The app in another folder than the app of nexusd, for example in Downloads.
    @Test func aNexusdThatStartsAnotherBuildGetsTheRestartOfTheApp() {
        var check = NexusdVersionCheck(appBuild: "14")

        check.received(build: "12", updateBuild: "13")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(restarts)
    }

    @Test func theRestartWaitsForRunningTasks() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        let whileTasksRun = check.takeRestart(tasksRun: true)
        let afterTheTasks = check.takeRestart(tasksRun: false)

        #expect(!whileTasksRun)
        #expect(afterTheTasks)
    }

    @Test func aNexusdThatStaysOldAfterTheRestartShowsAsAProblem() {
        var check = NexusdVersionCheck(appBuild: "12")
        check.received(build: "11")
        _ = check.takeRestart(tasksRun: false)
        check.connectionEnded()

        check.received(build: "11")

        #expect(check.restartDidNotHelp)
    }

    @Test func aNexusdWithTheNewBuildAfterTheRestartShowsNoProblem() {
        var check = NexusdVersionCheck(appBuild: "12")
        check.received(build: "11")
        _ = check.takeRestart(tasksRun: false)
        check.connectionEnded()

        check.received(build: "12")

        #expect(!check.restartDidNotHelp)
    }

    @Test func anOldNexusdThatStillStopsItsServicesShowsNoProblem() {
        var check = NexusdVersionCheck(appBuild: "12")
        check.received(build: "11")
        _ = check.takeRestart(tasksRun: false)

        check.received(build: "11")

        #expect(!check.restartDidNotHelp)
    }

    @Test func aConnectionThatEndsBeforeTheRestartDoesNotCount() {
        var check = NexusdVersionCheck(appBuild: "12")
        check.connectionEnded()
        check.received(build: "11")

        _ = check.takeRestart(tasksRun: false)
        check.received(build: "11")

        #expect(!check.restartDidNotHelp)
    }

    @Test func aNewLaunchOfTheSameBuildDoesNotRestartAgain() {
        var check = NexusdVersionCheck(appBuild: "12", lastRestartBuild: "12")

        check.received(build: "11")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(!restarts)
        #expect(check.restartDidNotHelp)
    }

    @Test func aNewBuildOfTheAppRestartsAgain() {
        var check = NexusdVersionCheck(appBuild: "13", lastRestartBuild: "12")

        check.received(build: "12")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(restarts)
    }

    @Test func theServiceListOfAnOlderNexusdHasNoBuild() throws {
        let data = Data(#"{"services":[],"stoppedByStopAll":[]}"#.utf8)

        let list = try JSONDecoder().decode(ServiceList.self, from: data)

        #expect(list.build == nil)
    }
}
