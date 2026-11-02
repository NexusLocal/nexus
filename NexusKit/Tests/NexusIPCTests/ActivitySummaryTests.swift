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
    }

    @Test func theSettingsOfPHPNeverShow() {
        let request = NexusRequest.setCustomSettings(php: "8.5", lines: ["session.save_path = secret"])

        #expect(request.activitySummary == "setCustomSettings")
    }

    @Test func aQuestionOnlyReads() {
        #expect(NexusRequest.status.onlyReads)
        #expect(NexusRequest.tld(nil).onlyReads)
        #expect(!NexusRequest.tld("test").onlyReads)
        #expect(!NexusRequest.start(service: "nginx").onlyReads)
    }

    @Test func aResponseSaysHowItEnded() {
        #expect(NexusResponse.done(message: "ok").activitySummary == "done")
        #expect(!NexusResponse.done(message: "ok").failed)
        #expect(NexusResponse.failure(message: "no").activitySummary == "failed: no")
        #expect(NexusResponse.failure(message: "no").failed)
    }
}
