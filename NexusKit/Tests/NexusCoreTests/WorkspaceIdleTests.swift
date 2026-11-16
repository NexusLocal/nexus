import Foundation
import Testing
@testable import NexusCore

struct WorkspaceIdleTests {
    @Test func theChoicesOfStopAfterHaveTheOrderAndTheTextsOfThePlan() {
        #expect(WorkspaceIdleTime.allCases.map(\.title) == ["15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours", "1 day", "Never"])
        #expect(WorkspaceIdleTime.never.duration == nil)
        #expect(WorkspaceIdleTime.oneHour.duration == 3600)
        #expect(WorkspaceIdleTime.oneDay.duration == 86_400)
    }

    @Test func aRecordFromBeforeTheIdleStopRuns() throws {
        let json = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}}}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))

        #expect(workspace.runState == .running)
        #expect(!workspace.keepAwake)
        #expect(workspace.stoppedAfter == nil)
    }

    @Test func aRecordWithTheStopTimeOfAnEarlierBuildStillDecodes() throws {
        let json = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}},"runState":"stopped","stoppedAt":785000000,"stoppedAfter":120}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        let written = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)

        #expect(workspace.runState == .stopped)
        #expect(workspace.stoppedAfter == .twoHours)
        #expect(!written.contains("stoppedAt"))
    }

    @Test(arguments: ["starting", "sleeping"])
    func aRecordKeepsOnlyRunningOrStopped(runState: String) throws {
        let json = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","runState":"\#(runState)","stoppedAfter":480}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))

        #expect(workspace.runState == .running)
        #expect(workspace.stoppedAfter == nil)
    }

    @Test func aStoppedRecordSurvivesAWrite() throws {
        let stopped = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, runState: .stopped, keepAwake: true, stoppedAfter: .twoHours)

        let decoded = try JSONDecoder().decode(Workspace.self, from: try JSONEncoder().encode(stopped))

        #expect(decoded == stopped)
    }

    @Test(arguments: [#"{}"#, #"{"stopIdleAfter":480}"#])
    func settingsWithoutAKnownStopAfterGiveOneHour(json: String) throws {
        let settings = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(json.utf8))

        #expect(settings.stopIdleAfter == .oneHour)
    }

    @Test func settingsKeepTheirStopAfter() throws {
        let settings = WorkspaceSettings(stopIdleAfter: .fifteenMinutes)

        let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: try JSONEncoder().encode(settings))

        #expect(decoded.stopIdleAfter == .fifteenMinutes)
    }
}
