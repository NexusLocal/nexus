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

    @Test func theAppWaitsForANexusdWithAnotherBuildUntilItHasTheBuildOfTheApp() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "12")
        let current = check.waitsForNewNexusd
        check.received(build: "11", updateBuild: "12")
        let startsThisBuild = check.waitsForNewNexusd
        check.received(build: "11")
        let restartsIt = check.waitsForNewNexusd
        check.received(build: "12")
        let started = check.waitsForNewNexusd

        #expect(!current)
        #expect(startsThisBuild)
        #expect(restartsIt)
        #expect(!started)
    }

    @Test func theAppDoesNotWaitWithoutAConnection() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        check.connectionEnded()

        #expect(!check.waitsForNewNexusd)
    }

    @Test func theAppDoesNotWaitForANewerNexusd() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "13")

        #expect(!check.waitsForNewNexusd)
    }

    @Test func aRestartOfTheUserCountsAsTheOneRestart() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        let begins = check.beginRestart()
        check.restartFailed()
        let restarts = check.takeRestart(tasksRun: false)

        #expect(begins)
        #expect(!restarts)
    }

    @Test func noSecondRestartBeginsWhileOneRuns() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        let first = check.beginRestart()
        let second = check.beginRestart()

        #expect(first)
        #expect(!second)
        #expect(check.restartRuns)
    }

    @Test func aFailedRestartLetsTheUserTryAgain() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        _ = check.beginRestart()
        check.restartFailed()
        let again = check.beginRestart()

        #expect(again)
    }

    @Test(arguments: [true, false])
    func theRestartRunsUntilTheConnectionEndsOrTheNewBuildAnswers(connectionEnds: Bool) {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "11")
        _ = check.beginRestart()
        check.received(build: "11")
        let whileTheOldNexusdAnswers = check.restartRuns
        connectionEnds ? check.connectionEnded() : check.received(build: "12")

        #expect(whileTheOldNexusdAnswers)
        #expect(!check.restartRuns)
    }

    @Test func theAppDoesNotWaitWhenNexusdHasTheSameBuildThatIsNotANumber() {
        var check = NexusdVersionCheck(appBuild: "unknown")

        check.received(build: "unknown")

        #expect(!check.waitsForNewNexusd)
    }

    @Test(arguments: [
        (NexusRequest.status, true),
        (.stopTask(id: "1"), true),
        (.start(service: "mysql"), true),
        (.stopAll, true),
        (.stopWorkspace(host: "shop.test", name: "a"), true),
        (.startWorkspace(host: "shop.test", name: "a"), true),
        (.startWorkspace(host: "shop.test", name: "a", keepAwake: true), false),
        (.restartApp(host: "shop.test", workspace: nil), true),
        (.fromAgent(agent: "claude", request: .stop(service: "mysql")), true),
        (.fromAgent(agent: "claude", request: .removeSite(host: "shop.test")), false),
        (.setKeepAwake(host: "shop.test", name: "a", keepAwake: true), false),
        (.removeSite(host: "shop.test"), false),
        (.lan(enabled: true), false),
    ])
    func onlyAQuestionOrAStopOrAStartReachesAnOlderNexusd(request: NexusRequest, safe: Bool) {
        #expect(request.isSafeForAnOlderNexusd == safe)
    }

    @Test func theAppStopsWaitingWhenARestartDidNotHelp() {
        var check = NexusdVersionCheck(appBuild: "12", lastRestartBuild: "12")

        check.received(build: "11")

        #expect(check.restartDidNotHelp)
        #expect(!check.waitsForNewNexusd)
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

    @Test func anOlderNexusdThatStartsTheBuildOfTheAppGetsTheRestartOfTheAppOnlyAtTheDeadline() {
        var check = NexusdVersionCheck(appBuild: "13")
        let start = Date(timeIntervalSince1970: 1_000_000)

        check.received(build: "12", updateBuild: "13", at: start)
        let beforeTheDeadline = check.takeRestart(tasksRun: false, at: start.addingTimeInterval(599))
        let atTheDeadline = check.takeRestart(tasksRun: false, at: start.addingTimeInterval(NexusdVersionCheck.longestWait))

        #expect(!beforeTheDeadline)
        #expect(atTheDeadline)
    }

    @Test func aNewConnectionToTheSameOlderNexusdKeepsTheDeadline() {
        var check = NexusdVersionCheck(appBuild: "12")
        let start = Date(timeIntervalSince1970: 1_000_000)

        check.received(build: "11", at: start)
        check.connectionEnded()
        check.received(build: "11", at: start.addingTimeInterval(60))

        #expect(check.restartDeadline == start.addingTimeInterval(NexusdVersionCheck.longestWait))
    }

    @Test func aRestartThatAlreadyCountsShowsNoDeadline() {
        var check = NexusdVersionCheck(appBuild: "13", lastRestartBuild: "13")

        check.received(build: "12", updateBuild: "13")

        #expect(check.waitsForNewNexusd)
        #expect(check.restartDeadline == nil)
    }

    @Test func aNewerNexusdThatStartsTheBuildOfTheAppGetsNoRestartFromTheApp() {
        var check = NexusdVersionCheck(appBuild: "13")

        check.received(build: "14", updateBuild: "13")
        let restarts = check.takeRestart(tasksRun: false)

        #expect(!restarts)
    }

    @Test func aTaskOfAnOlderNexusdGetsAtMostTheLongestWait() {
        var check = NexusdVersionCheck(appBuild: "12")
        let start = Date(timeIntervalSince1970: 1_000_000)

        check.received(build: "11", updateBuild: "12", at: start)
        check.received(build: "11", updateBuild: "12", at: start.addingTimeInterval(300))
        let deadline = check.restartDeadline
        let beforeTheEnd = check.takeRestart(tasksRun: true, at: start.addingTimeInterval(599))
        let atTheEnd = check.takeRestart(tasksRun: true, at: start.addingTimeInterval(600))

        #expect(deadline == start.addingTimeInterval(NexusdVersionCheck.longestWait))
        #expect(!beforeTheEnd)
        #expect(atTheEnd)
    }

    @Test func aNewerNexusdHasNoDeadline() {
        var check = NexusdVersionCheck(appBuild: "12")

        check.received(build: "13")

        #expect(check.restartDeadline == nil)
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
