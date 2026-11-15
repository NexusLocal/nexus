import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct ActivitySummaryTests {
    @Test func aRequestNamesItsService() {
        #expect(NexusRequest.start(service: "nginx").activitySummary == "start nginx")
        #expect(NexusRequest.install(name: "php", line: "8.5").activitySummary == "install php 8.5")
    }

    @Test func aRequestWithoutValuesShowsItsName() {
        #expect(NexusRequest.stopAll.activitySummary == "stopAll")
    }

    @Test func aPasswordNeverShows() {
        let account = DatabaseAccount(user: "root", password: "hunter2")

        #expect(NexusRequest.setAccount(instance: "mysql-8.4", account: account).activitySummary == "setAccount mysql-8.4")
        #expect(NexusRequest.setNewInstanceAccount(account).activitySummary == "setNewInstanceAccount")
        #expect(NexusRequest.importSite(SiteImport(backup: "/tmp/foo.wpress", name: "foo", parent: "/tmp", password: "hunter2")).activitySummary == "importSite foo")
    }

    @Test func theSettingsOfPHPNeverShow() {
        let request = NexusRequest.setCustomSettings(php: "8.5", lines: ["session.save_path = secret"])

        #expect(request.activitySummary == "setCustomSettings")
    }

    @Test func theLinesOfASiteNeverShow() {
        let request = NexusRequest.setSiteLines(host: "shop.test", lines: ["proxy_set_header Authorization secret;"])

        #expect(request.activitySummary == "setSiteLines shop.test")
    }

    @Test func aQuestionOnlyReads() {
        #expect(NexusRequest.status.onlyReads)
        #expect(NexusRequest.siteLines(host: "shop.test").onlyReads)
        #expect(!NexusRequest.setSiteLines(host: "shop.test", lines: []).onlyReads)
        #expect(NexusRequest.tld(nil).onlyReads)
        #expect(!NexusRequest.tld("test").onlyReads)
        #expect(!NexusRequest.start(service: "nginx").onlyReads)
    }

    @Test func aResponseSaysHowItEnded() {
        #expect(NexusResponse.done(message: "ok").activitySummary == "done")
        #expect(!NexusResponse.done(message: "ok").failed)
        #expect(NexusResponse.failure(message: "no").activitySummary == "failed: no")
        #expect(NexusResponse.failure(message: "no").failed)

        let lines = NexusResponse.invalidSiteLines(SiteLinesError(host: "shop.test", server: .nginx, line: 1, message: "unknown directive \"client_max_body_siz\""))

        #expect(lines.activitySummary == "failed: the lines are not valid")
        #expect(lines.failed)
    }

    @Test func aRefusedLineSaysWhichLineAndThatTheOldLinesStay() {
        let error = SiteLinesError(host: "shop.test", server: .nginx, line: 1, message: "unknown directive \"client_max_body_siz\"")
        let noLine = SiteLinesError(host: "blog.test", server: .apache, line: nil, message: "Invalid command 'X'")

        #expect(error.description == "Line 1: unknown directive \"client_max_body_siz\". shop.test keeps its old nginx lines.")
        #expect(noLine.description == "Invalid command 'X'. blog.test keeps its old Apache lines.")
    }
}
