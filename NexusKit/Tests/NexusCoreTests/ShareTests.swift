import Foundation
import Testing
@testable import NexusCore

struct ShareTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static let states: [ShareState] = [
        .starting(.downloadCloudflared),
        .starting(.buildAssets),
        .starting(.openLink),
        .open,
        .ended(.stopped),
        .ended(.endTime),
        .ended(.sleep),
        .ended(.connectionLost),
        .ended(.appQuit),
        .ended(.nexusdStopped),
        .ended(.siteGone),
        .ended(.failed("x")),
    ]

    static func record(_ state: ShareState) -> ShareRecord {
        ShareRecord(
            id: "0123456789abcdef0123456789abcdef",
            host: "fix.shop.test",
            site: "shop.test",
            workspace: "fix",
            options: ShareOptions(duration: .fourHours, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .random),
            mode: .publicHost,
            label: "shop",
            publicHost: "calm-river-tree-lamp.trycloudflare.com",
            password: "secret",
            port: 18_000,
            metricsPort: 18_001,
            started: started,
            endsAt: started.addingTimeInterval(14_400),
            state: state,
            usesVite: true,
            liveBlocked: "Vite 5.4.2 is too old for Live."
        )
    }

    static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test(arguments: states)
    func aRecordKeepsEachStateAfterASave(state: ShareState) throws {
        let record = Self.record(state)

        let saved = try JSONDecoder().decode(ShareRecord.self, from: JSONEncoder().encode(record))

        #expect(saved == record)
    }

    @Test func aRecordWithoutTheFieldsOfOtherPartsGetsNilAndNoPort() throws {
        let record = ShareRecord(id: "abc", host: "shop.test", site: "shop.test", options: .standard, mode: .localHost, started: Self.started, state: .starting(.openLink))

        let saved = try JSONDecoder().decode(ShareRecord.self, from: JSONEncoder().encode(record))

        #expect(saved == record)
        #expect(saved.port == 0)
        #expect(saved.label == nil)
        #expect(saved.password == nil)
        #expect(!saved.usesVite)
    }

    @Test func theStoredFormOfTheStatesAndTheOptionsStaysTheSame() throws {
        let options = ShareOptions(duration: .untilStopped, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .ownDomain)

        #expect(try Self.json(ShareState.starting(.downloadCloudflared)) == #"{"starting":{"_0":"download_cloudflared"}}"#)
        #expect(try Self.json(ShareState.open) == #"{"open":{}}"#)
        #expect(try Self.json(ShareState.ended(.connectionLost)) == #"{"ended":{"_0":{"connectionLost":{}}}}"#)
        #expect(try Self.json(ShareState.ended(.failed("x"))) == #"{"ended":{"_0":{"failed":{"_0":"x"}}}}"#)
        #expect(try Self.json(options) == #"{"address":"own_domain","duration":0,"hidesErrors":false,"keepsRequests":true,"password":true,"viteMode":"build"}"#)
        #expect(try Self.json([ShareHostMode.publicHost, .localHost]) == #"["public_host","local_host"]"#)
        #expect(ShareWarning.allCases.map(\.rawValue) == ["sends_real_mail", "oauth_login", "server_sent_events", "custom_access_rules", "vite_in_terminal", "mix_hot"])
    }

    @Test func theWarningOfLaravelMixKeepsItsValueAndShowsOnEachAddress() throws {
        let saved = try JSONDecoder().decode(ShareWarning.self, from: JSONEncoder().encode(ShareWarning.mixHot))

        #expect(try Self.json(ShareWarning.mixHot) == #""mix_hot""#)
        #expect(saved == .mixHot)
        #expect(!ShareWarning.mixHot.onlyForRandomAddress)
    }

    @Test func theOptionsKeepEachValueAfterASave() throws {
        let options = ShareOptions(duration: .oneHour, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .ownDomain)

        let saved = try JSONDecoder().decode(ShareOptions.self, from: JSONEncoder().encode(options))

        #expect(saved == options)
    }

    @Test func optionsWithoutKeysAreTheStandardOptions() throws {
        let options = try JSONDecoder().decode(ShareOptions.self, from: Data("{}".utf8))

        #expect(options == .standard)
        #expect(options == ShareOptions(duration: .eightHours, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .random))
    }

    @Test func aValueOfANewerNexusdGetsTheStandardValueAndTheOtherValuesStay() throws {
        let options = try JSONDecoder().decode(ShareOptions.self, from: Data(#"{"duration":30,"viteMode":"turbo","address":"other","password":true,"keepsRequests":"yes"}"#.utf8))

        #expect(options.duration == .eightHours)
        #expect(options.viteMode == .live)
        #expect(options.address == .random)
        #expect(!options.keepsRequests)
        #expect(options.password)
    }

    @Test func onlyAnEndedLinkIsNotActive() {
        #expect(Self.states.filter(\.isActive) == [.starting(.downloadCloudflared), .starting(.buildAssets), .starting(.openLink), .open])
    }

    @Test func eachReasonOfAnEndIsASentenceAndAFailureGivesItsOwnText() {
        let reasons: [ShareEndReason] = [.stopped, .endTime, .sleep, .connectionLost, .appQuit, .nexusdStopped, .siteGone]

        #expect(reasons.allSatisfy { $0.logText.hasSuffix(".") })
        #expect(ShareEndReason.failed("cloudflared stopped.").logText == "cloudflared stopped.")
    }

    @Test func theSheetNamesTheSecondLocalHostsInOneLine() {
        #expect(ShareText.alsoReaches([]) == nil)
        #expect(ShareText.alsoReaches(["cms.shop.test"]) == "Visitors can also open cms.shop.test through this link.")
        #expect(ShareText.alsoReaches(["api.shop.test", "cms.shop.test"]) == "Visitors can also open api.shop.test and cms.shop.test through this link.")
        #expect(ShareText.njsMissing == "A public link needs the njs module of nginx, the web server of Nexus. The installed nginx does not have it. Update nginx in Packages. Then try again.")
    }

    @Test func onlyOAuthAndStreamedTextAreHiddenOnAnOwnDomain() {
        #expect(ShareWarning.allCases.filter(\.onlyForRandomAddress) == [.oauthLogin, .serverSentEvents])
        #expect(!ShareWarning.customAccessRules.onlyForRandomAddress)
    }

    @Test func theWarningOfTheCustomAccessRulesKeepsItsValueAfterASave() throws {
        let saved = try JSONDecoder().decode([ShareWarning].self, from: JSONEncoder().encode([ShareWarning.customAccessRules]))

        #expect(try Self.json(ShareWarning.customAccessRules) == #""custom_access_rules""#)
        #expect(saved == [.customAccessRules])
    }

    @Test func theTextOfAPasswordThatNexusCannotSaveNamesTheReason() {
        #expect(ShareText.passwordNotSaved("The disk is full.") == "Nexus cannot save the password of the link in its data folder. The disk is full.")
    }

    @Test func theTimeOfTheEndHasHoursAndMinutesInTheZoneOfTheMac() throws {
        let end = try Date("2026-11-20T17:40:00Z", strategy: .iso8601)

        #expect(ShareText.time(end, in: try #require(TimeZone(identifier: "Europe/Amsterdam"))) == "18:40")
        #expect(ShareText.time(end, in: try #require(TimeZone(identifier: "UTC"))) == "17:40")
        #expect(ShareText.until(end) == "until \(ShareText.time(end))")
        #expect(ShareText.until(nil) == "until you stop it")
    }

    @Test func theAnswersAndTheLinesOfNexusShareNameTheHostTheCountAndTheTime() throws {
        let end = try Date("2026-11-20T17:40:00Z", strategy: .iso8601)

        #expect(ShareText.linkStopped("shop.test") == "The link to shop.test stopped.")
        #expect(ShareText.noOpenLink("shop.test") == "shop.test has no open link.")
        #expect(ShareText.stoppedLinks(1) == "Nexus stopped 1 link.")
        #expect(ShareText.stoppedLinks(2) == "Nexus stopped 2 links.")
        #expect(ShareText.opening("shop.test") == "Nexus opens a link to shop.test. This can take a minute.")
        #expect(ShareText.endsAt(end, in: try #require(TimeZone(identifier: "Europe/Amsterdam"))) == "The link ends at 18:40.")
        #expect(ShareText.passwordLine("plum-river-42") == "The user name is nexus. The password is plum-river-42.")
        #expect(ShareText.stopHint("shop.test") == "Stop the link with: nexus share stop shop.test")
        #expect(ShareText.openAlready("shop.test") == "shop.test has an open link already. Nexus did not change its options.")
        #expect(ShareText.portNotOpen(18_000) == "The web server of Nexus (nginx) did not open port 18000 for the link. Try again.")
        #expect(ShareText.cloudflaredStopped(log: "/tmp/cloudflared-shop.test.log") == "The program that makes the public links (cloudflared) stopped. Its log is /tmp/cloudflared-shop.test.log.")
    }

    @Test func theActivityLinesNameTheOptionsAndNoAddress() {
        let end = Self.started.addingTimeInterval(28_800)
        let changed = ShareOptions(duration: .untilStopped, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .random)

        #expect(ShareText.opensLine(host: "shop.test", options: .standard, endsAt: end, usesVite: true) == "Nexus opens a link to shop.test: ends \(ShareText.time(end)), password off, error details hidden, Vite Live, requests off.")
        #expect(ShareText.opensLine(host: "shop.test", options: .standard, endsAt: end, usesVite: false) == "Nexus opens a link to shop.test: ends \(ShareText.time(end)), password off, error details hidden, requests off.")
        #expect(ShareText.opensLine(host: "shop.test", options: changed, endsAt: nil, usesVite: true) == "Nexus opens a link to shop.test: ends when you stop it, password on, error details shown, Vite Build, requests on.")
        #expect(ShareText.openLine("shop.test") == "The link to shop.test is open.")
        #expect(ShareText.notOpenedLine("shop.test", reason: .stopped) == "The link to shop.test did not open: the user stopped it.")
        #expect(ShareText.stoppedLine("shop.test", reason: .endTime) == "The link to shop.test stopped: the end time passed.")
        #expect(ShareText.stoppedTitle("shop.test") == "The link to shop.test stopped")
    }

    @Test func aLineOfTheVisitorLogDecodesAlsoWithoutAVisitor() throws {
        let line = try JSONDecoder().decode(ShareLogLine.self, from: Data(#"{"time":1800000000.123,"request":"5f2b0c9d8e7a6b5c4d3e2f1a0b9c8d7e","status":200,"visitor":"203.0.113.7"}"#.utf8))
        let withoutVisitor = try JSONDecoder().decode(ShareLogLine.self, from: Data(#"{"time":1800000001.000,"request":"6a","status":502,"visitor":""}"#.utf8))

        #expect(line == ShareLogLine(time: 1_800_000_000.123, request: "5f2b0c9d8e7a6b5c4d3e2f1a0b9c8d7e", status: 200, visitor: "203.0.113.7"))
        #expect(withoutVisitor == ShareLogLine(time: 1_800_000_001, request: "6a", status: 502, visitor: ""))
        #expect(line.method == nil)
        #expect(line.requestHeaders == nil)
        #expect(line.bodyBytes == nil)
    }

    @Test func aLineOfTheRequestLogDecodesWithEachField() throws {
        let json = #"{"time":1800000000.5,"request":"4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6","status":200,"visitor":"3.18.12.63","method":"POST","uri":"/webhooks/stripe?x=1","host":"calm-river.trycloudflare.com","duration":0.184,"size":34,"contentType":"application/json","requestHeaders":[["Host","calm-river.trycloudflare.com"],["Cookie","hidden"]],"responseHeaders":[["Content-Type","application/json"]],"body":"eyJhIjoxfQ==","bodyBytes":7}"#

        let line = try JSONDecoder().decode(ShareLogLine.self, from: Data(json.utf8))

        #expect(line == ShareLogLine(time: 1_800_000_000.5, request: "4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6", status: 200, visitor: "3.18.12.63", method: "POST", uri: "/webhooks/stripe?x=1", host: "calm-river.trycloudflare.com", duration: 0.184, size: 34, contentType: "application/json", requestHeaders: [["Host", "calm-river.trycloudflare.com"], ["Cookie", "hidden"]], responseHeaders: [["Content-Type", "application/json"]], body: "eyJhIjoxfQ==", bodyBytes: 7))
        #expect(try JSONDecoder().decode(ShareLogLine.self, from: Data(#"{"time":1,"request":"r","status":204,"visitor":"","method":"GET","uri":"/","contentType":null,"body":null,"bodyBytes":null}"#.utf8)).contentType == nil)
    }

    @Test func aRequestOfALinkKeepsItsValuesAfterASave() throws {
        let request = PublicLinkRequest(host: "shop.test", visitor: "203.0.113.7", size: 1_024, contentType: "application/json")

        let saved = try JSONDecoder().decode(PublicLinkRequest.self, from: JSONEncoder().encode(request))

        #expect(saved == request)
    }

    @Test(arguments: [OwnDomainState.connecting(loginPage: "https://dash.cloudflare.com/argotunnel?callback=x"), .connecting(loginPage: nil), .connected, .failed("The login did not end.", keyMade: true)])
    func theOwnDomainKeepsItsValuesAfterASave(state: OwnDomainState) throws {
        let record = OwnDomainRecord(domain: "example.com", tunnelID: "6ff42ae2-765d-4adf-8112-31c55c1551ef", tunnelName: "nexus-macbook-pro", labels: ["shop.test": "shop"], dnsRecords: ["shop.example.com"], metricsPort: 18_010)

        let savedRecord = try JSONDecoder().decode(OwnDomainRecord.self, from: JSONEncoder().encode(record))
        let savedState = try JSONDecoder().decode(OwnDomainState.self, from: JSONEncoder().encode(state))

        #expect(savedRecord == record)
        #expect(savedState == state)
    }
}
