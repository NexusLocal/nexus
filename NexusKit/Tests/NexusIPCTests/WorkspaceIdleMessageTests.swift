import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct WorkspaceIdleMessageTests {
    private func siteList(runState: WorkspaceRunState = .stopped, stopIdleAfter: WorkspaceIdleTime = .twoHours) -> SiteList {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, runState: runState, keepAwake: true, stoppedAfter: .oneHour)
        let site = SiteInfo(hosts: ["shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", workspaces: [workspace])

        return SiteList(sites: [site], layout: [], parkedFolders: [], defaults: SiteDefaults(), tld: "test", stopIdleAfter: stopIdleAfter)
    }

    @Test(arguments: [
        (WorkspaceState.ready, WorkspaceRunState.running, "Ready"),
        (.ready, .stopped, "Stopped"),
        (.ready, .starting, "Starting"),
        (.preparing, .stopped, "Preparing"),
        (.notIsolated("The connection cms is fixed."), .running, "Not isolated"),
        (.notIsolated("\(WorkspaceDumpText.failed) The file is no SQL dump."), .running, "The dump did not load"),
        (.notIsolated("\(WorkspaceDumpText.gone) Choose another file."), .running, "The dump file is gone"),
        (.notIsolated("\(WorkspaceDumpText.gone) Choose another file."), .stopped, "Stopped"),
    ])
    func theStateTextShowsTheRunStateInPlaceOfEachStateExceptPreparing(state: WorkspaceState, runState: WorkspaceRunState, text: String) {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: state, runState: runState)

        #expect(workspace.stateText == text)
    }

    @Test func theRunStateAndTheSettingSurviveTheWire() throws {
        let list = siteList()

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: NexusMessageCoding.encode(list))

        #expect(decoded == list)
    }

    @Test func aRunStateAndAnIdleTimeOfANewerNexusdGiveNilAndTheListStillDecodes() throws {
        let text = String(decoding: try NexusMessageCoding.encode(siteList()), as: UTF8.self)
            .replacing("\"stopped\"", with: "\"sleeps\"")
            .replacing("\"stopIdleAfter\":120", with: "\"stopIdleAfter\":7")

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: Data(text.utf8))

        #expect(text.contains("\"sleeps\""))
        #expect(decoded.stopIdleAfter == nil)
        #expect(decoded.sites.first?.workspaces?.first?.runState == nil)
        #expect(decoded.sites.first?.workspaces?.first?.keepAwake == true)
    }

    @Test func aWorkspaceAndAToolCommandFromBeforeTheIdleStopHaveNoValues() throws {
        let workspace = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(#"{"name":"fix","worktree":"/w/fix","folder":"/w/fix"}"#.utf8))
        let command = try JSONDecoder().decode(ToolCommand.self, from: Data(#"{"executable":"/bin/php","arguments":[],"environment":{},"path":[]}"#.utf8))

        #expect(workspace.runState == nil)
        #expect(workspace.keepAwake == nil)
        #expect(workspace.stoppedAfter == nil)
        #expect(command.startProblem == nil)
    }

    @Test func aToolRequestOfAnOlderNexusCommandHasNoActivity() throws {
        let old = Data(#"{"tool":{"_0":"php","folder":"/Sites/shop"}}"#.utf8)
        let encoded = String(decoding: try JSONEncoder().encode(NexusRequest.tool(.php, folder: "/Sites/shop", activity: false)), as: UTF8.self)

        let decoded = try JSONDecoder().decode(NexusRequest.self, from: old)

        #expect(decoded == .tool(.php, folder: "/Sites/shop", argumentFolder: nil, debug: nil, activity: nil))
        #expect(encoded.contains(#""activity":false"#))
    }

    @Test func theRequestsOfTheIdleStopNameTheirWorkspaceInTheActivityLog() {
        #expect(NexusRequest.stopWorkspace(host: "shop.test", name: "fix").activitySummary == "stopWorkspace shop.test fix")
        #expect(NexusRequest.startWorkspace(host: "shop.test", name: "fix").activitySummary == "startWorkspace shop.test fix")
        #expect(NexusRequest.startWorkspace(host: "shop.test", name: "fix", keepAwake: true).activitySummary == "startWorkspace shop.test fix --keep")
        #expect(NexusRequest.setKeepAwake(host: "shop.test", name: "fix", keepAwake: false).activitySummary == "setKeepAwake shop.test fix false")
        #expect(!NexusRequest.stopWorkspace(host: "shop.test", name: "fix").onlyReads)
        #expect(!NexusRequest.setKeepAwake(host: "shop.test", name: "fix", keepAwake: true).onlyReads)
    }

    @Test func eachRequestThatNamesAWorkspaceGivesItsHostAndNameButAStopGivesNone() {
        let target = DatabaseTarget.workspace(site: "shop.test", name: "fix", instance: "mysql-8.4")
        let named: [NexusRequest] = [
            .databaseConnections(host: "shop.test", workspace: "fix"),
            .serverDatabases(target),
            .createDatabase(target, name: "shop"),
            .importDump(DumpImport(file: "/w/shop.sql", target: target, name: "shop")),
            .inspectDump(DumpInspection(file: "/w/shop.sql", target: target)),
            .restartApp(host: "shop.test", workspace: "fix"),
            .retryWorkspace(host: "shop.test", name: "fix"),
            .startWorkspace(host: "shop.test", name: "fix"),
            .setKeepAwake(host: "shop.test", name: "fix", keepAwake: true),
            .fromAgent(agent: "Claude Code", request: .startWorkspace(host: "shop.test", name: "fix")),
        ]
        let unnamed: [NexusRequest] = [
            .stopWorkspace(host: "shop.test", name: "fix"),
            .fromAgent(agent: "Claude Code", request: .stopWorkspace(host: "shop.test", name: "fix")),
            .removeWorkspace(host: "shop.test", name: "fix", force: false),
            .databaseConnections(host: "shop.test", workspace: nil),
            .restartApp(host: "shop.test", workspace: nil),
            .serverDatabases(.instance("mysql-8.4")),
        ]

        #expect(named.allSatisfy { $0.namedWorkspace?.host == "shop.test" && $0.namedWorkspace?.name == "fix" })
        #expect(unnamed.allSatisfy { $0.namedWorkspace == nil })
    }
}
