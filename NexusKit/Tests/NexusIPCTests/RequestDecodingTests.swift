import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct RequestDecodingTests {
    @Test(arguments: [
        NexusRequest.setWorkspaceSettings(WorkspaceSettings(stopIdleAfter: .twoHours)),
        .setDumpSettings(DumpSettings(catchLogs: true, pageMode: .always)),
        .setMailSettings(MailSettings()),
        .setCustomSettings(php: "8.5", lines: ["memory_limit = 1G", "max_execution_time = 60"]),
        .requestEntries(request: "abc", afterNumber: 3, kinds: [.dump, .query, .log, .job]),
        .fromAgent(agent: "claude", request: .startWorkspace(host: "shop.test", name: "feature", keepAwake: true)),
        .herdMovePlan,
        .moveFromHerd(HerdMoveRequest(skipped: ["site:legacy.test"], php: ["site:api.test": "8.4"], databaseLines: ["database:mysql:3306:shop": "9.7"])),
    ])
    func eachRequestOfThisBuildIsRead(request: NexusRequest) throws {
        let data = try NexusMessageCoding.encode(request)

        #expect(try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data) == request)
    }

    @Test func aFieldThatNexusdDoesNotKnowIsRefusedWithItsName() {
        let data = Data(#"{"stopWorkspace":{"host":"shop.test","name":"feature","keepAwake":true}}"#.utf8)

        let error = #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }

        #expect(error?.path == "stopWorkspace.keepAwake")
    }

    @Test func eachRequestOfTheHelperIsRead() throws {
        for request in [HelperRequest.setResolver(tld: "test", port: 53), .takeOverResolver(tld: "test", port: 53), .removeResolver(tld: "test"), .setHosts(["127.0.0.1 shop.local"])] {
            #expect(try NexusMessageCoding.decodeWithoutLoss(HelperRequest.self, from: NexusMessageCoding.encode(request)) == request)
        }
    }

    @Test func aFieldInTheRequestOfAnAgentIsRefused() {
        let data = Data(#"{"fromAgent":{"agent":"claude","request":{"stopWorkspace":{"host":"shop.test","name":"feature","force":true}}}}"#.utf8)

        #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }
    }

    @Test func aValueThatTheSettingsReplaceWithTheirDefaultIsRefused() {
        let data = Data(#"{"setWorkspaceSettings":{"_0":{"stopIdleAfter":45}}}"#.utf8)

        #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }
    }

    @Test func theSettingsOfAnOlderCommandWithFewerFieldsAreRead() throws {
        let data = Data(#"{"setDumpSettings":{"_0":{"catchDumps":true}}}"#.utf8)

        let request = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)

        #expect(request == .setDumpSettings(DumpSettings(catchDumps: true, catchLogs: true)))
    }

    @Test func theOrderOfASetDoesNotMatter() throws {
        let data = Data(#"{"requestEntries":{"request":"abc","afterNumber":3,"kinds":["job","log","query","dump"]}}"#.utf8)

        let request = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)

        #expect(request == .requestEntries(request: "abc", afterNumber: 3, kinds: [.dump, .query, .log, .job]))
    }

    @Test func anElementThatTheDecoderDropsIsRefused() {
        let data = Data(#"{"requestEntries":{"request":"abc","afterNumber":3,"kinds":["dump","dump"]}}"#.utf8)

        #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }
    }

    @Test func aNullThatTheSettingsReplaceWithTheirDefaultIsRead() throws {
        let data = Data(#"{"setDumpSettings":{"_0":{"catchDumps":true,"catchLogs":null}}}"#.utf8)

        let request = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)

        #expect(request == .setDumpSettings(DumpSettings(catchDumps: true, catchLogs: true)))
    }

    @Test func anEmptyOptionalFieldIsRead() throws {
        let data = Data(#"{"oldWorkspaces":{"host":"shop.test","days":null}}"#.utf8)

        let request = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)

        #expect(request == .oldWorkspaces(host: "shop.test"))
    }
}
