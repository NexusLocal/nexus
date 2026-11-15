import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct UseNexusInfoTests {
    private static let appURL = EnvValueChange(key: "APP_URL", oldValue: "http://localhost:8888", newValue: "https://shop.test:8443")
    private static let redis = [EnvValueChange(key: "REDIS_PORT", oldValue: "6379", newValue: "16379")]

    private static let mysql84 = UseNexusChoice(
        instance: "mysql-8.4",
        name: "MySQL 8.4",
        changes: [
            EnvValueChange(key: "DB_HOST", oldValue: "localhost", newValue: "127.0.0.1"),
            EnvValueChange(key: "DB_SOCKET", oldValue: "/Applications/MAMP/tmp/mysql/mysql.sock", newValue: nil),
        ],
        databaseExists: false,
        canCopy: true
    )

    private static let mysql80 = UseNexusChoice(
        instance: "mysql-8.0",
        name: "MySQL 8.0",
        changes: [EnvValueChange(key: "DB_PORT", oldValue: "8889", newValue: "13307")],
        databaseExists: true,
        canCopy: false
    )

    private func info(appURL: EnvValueChange? = appURL, database: Bool = true, redis: [EnvValueChange] = redis) -> UseNexusInfo {
        UseNexusInfo(
            host: "shop.test",
            url: "https://shop.test:8443",
            appURL: appURL,
            appURLValue: appURL?.oldValue,
            database: database ? UseNexusDatabase(connection: "mysql", database: "shop", choices: [Self.mysql84, Self.mysql80]) : nil,
            redis: redis
        )
    }

    @Test func theNoticeOfTheDesignNamesEachPart() {
        let info = self.info()

        #expect(info.noticeTitle == "The .env of shop.test does not use Nexus")
        #expect(info.noticeMessage == "APP_URL, the database connection mysql and Redis point to other places. So the site may not work in Nexus.")
    }

    @Test func theNoticeWithOnlyAPPURLNamesTheURLOfNexus() {
        #expect(info(database: false, redis: []).noticeMessage == "APP_URL is http://localhost:8888. Nexus serves this site on https://shop.test:8443.")
    }

    @Test func theNoticeWithOnePartStartsWithACapital() {
        #expect(info(appURL: nil, redis: []).noticeMessage == "The database connection mysql points to another place. So the site may not work in Nexus.")
        #expect(info(appURL: nil, database: false).noticeMessage == "Redis points to another place. So the site may not work in Nexus.")
    }

    @Test func theNoticeWithTwoPartsJoinsThem() {
        #expect(info(redis: []).noticeMessage == "APP_URL and the database connection mysql point to other places. So the site may not work in Nexus.")
        #expect(info(appURL: nil).noticeMessage == "The database connection mysql and Redis point to other places. So the site may not work in Nexus.")
    }

    @Test func theSheetAsksForTheHost() {
        #expect(info().sheetTitle == "Use Nexus for shop.test?")
    }

    @Test func theDoneMessagesNameWhatNexusDid() {
        #expect(UseNexusInfo.doneTitle(host: "shop.test") == "The .env of shop.test uses Nexus now")
        #expect(UseNexusInfo.failedTitle(host: "shop.test") == "The .env of shop.test did not change")
        #expect(UseNexusInfo.doneMessage(database: "shop", server: "MySQL 8.4", step: .copied, keys: 6) == "Nexus copied shop to MySQL 8.4 and changed 6 keys. The old values stay as comment lines.")
        #expect(UseNexusInfo.doneMessage(database: "shop", server: "MySQL 8.4", step: .copied, keys: 1) == "Nexus copied shop to MySQL 8.4 and changed 1 key. The old value stays as a comment line.")
        #expect(UseNexusInfo.doneMessage(database: "shop", server: "MySQL 8.4", step: .made, keys: 6) == "Nexus made the empty database shop on MySQL 8.4 and changed 6 keys. The old values stay as comment lines.")
        #expect(UseNexusInfo.doneMessage(database: "shop", server: "MySQL 8.4", step: .made, keys: 1) == "Nexus made the empty database shop on MySQL 8.4 and changed 1 key. The old value stays as a comment line.")
        #expect(UseNexusInfo.doneMessage(database: nil, server: nil, step: .unchanged, keys: 6) == "Nexus changed 6 keys. The old values stay as comment lines.")
        #expect(UseNexusInfo.doneMessage(database: "shop", server: "MySQL 8.4", step: .unchanged, keys: 1) == "Nexus changed 1 key. The old value stays as a comment line.")
    }

    @Test func theTextsOfAChoiceNameTheDatabaseAndTheServer() {
        #expect(Self.mysql84.copyTitle(database: "shop") == "Copy the data of shop to MySQL 8.4")
        #expect(Self.mysql84.copyHelp(database: "shop") == "The old server still runs, and shop is not on MySQL 8.4 yet. The old server does not change.")
        #expect(Self.mysql84.emptyDatabaseText(database: "shop") == "Nexus makes the empty database shop on MySQL 8.4.")
        #expect(Self.mysql84.emptyDatabaseText(database: nil) == nil)
        #expect(Self.mysql80.emptyDatabaseText(database: "shop") == nil)
    }

    @Test func theChangesOfAChoiceComeBetweenAPPURLAndRedis() {
        let info = self.info()

        #expect(info.changes(choosing: "mysql-8.4") == [Self.appURL] + Self.mysql84.changes + Self.redis)
        #expect(info.changes(choosing: "mysql-8.0") == [Self.appURL] + Self.mysql80.changes + Self.redis)
        #expect(info.changes(choosing: nil) == [Self.appURL] + Self.redis)
    }

    @Test func aDatabaseServerOfAnOlderAppHasNoSocket() throws {
        let older = Data(#"{"host":"127.0.0.1","port":8889,"account":{"user":"root","password":"root"}}"#.utf8)

        let server = try NexusMessageCoding.decode(DatabaseServer.self, from: older)

        #expect(server == DatabaseServer(host: "127.0.0.1", port: 8889, account: .standard))
        #expect(server.socket == nil)
    }

    @Test func theRequestAndTheAnswerGoThroughTheCoding() throws {
        let request = NexusRequest.useNexus(UseNexusRequest(host: "shop.test", instance: "mysql-8.4", copy: true, changes: info().changes(choosing: "mysql-8.4")))
        let answer = NexusResponse.useNexusInfo(nil)
        let full = NexusResponse.useNexusInfo(info())

        #expect(try NexusMessageCoding.decode(NexusRequest.self, from: NexusMessageCoding.encode(request)) == request)
        #expect(try NexusMessageCoding.decode(NexusResponse.self, from: NexusMessageCoding.encode(answer)) == answer)
        #expect(try NexusMessageCoding.decode(NexusResponse.self, from: NexusMessageCoding.encode(full)) == full)
    }

    @Test func theActivityLogNamesOnlyTheHostAndTheCopy() {
        let request = NexusRequest.useNexus(UseNexusRequest(host: "shop.test", instance: "mysql-8.4", copy: true, changes: info().changes(choosing: "mysql-8.4")))

        #expect(request.activitySummary == "useNexus shop.test with a copy")
        #expect(NexusRequest.useNexusInfo(host: "shop.test").onlyReads)
    }
}
