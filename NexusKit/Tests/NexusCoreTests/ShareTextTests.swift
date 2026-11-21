import Foundation
import Testing
@testable import NexusCore

struct ShareTextTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func zone() throws -> TimeZone {
        try #require(TimeZone(identifier: "Europe/Amsterdam"))
    }

    static func end() throws -> Date {
        try Date("2026-11-20T17:40:00Z", strategy: .iso8601)
    }

    @Test func theBarNamesTheHostAndTheEnd() throws {
        #expect(ShareText.publicUntil("shop.test", endsAt: try Self.end(), in: try Self.zone()) == "shop.test is public until 18:40.")
        #expect(ShareText.publicUntil("shop.test", endsAt: nil) == "shop.test is public until you stop it.")
    }

    @Test func theButtonThePanelAndTheSettingsHaveTheTextsOfTheApprovedDesign() throws {
        #expect([ShareText.shareButton, ShareText.linkOpensButton, ShareText.publicButton, ShareText.tryAgain] == ["Share…", "The link opens…", "Public", "Try Again"])
        #expect(ShareText.notOpenedTitle == "The link did not open.")
        #expect([ShareText.endsKey, ShareText.visitorsKey, ShareText.stylesKey] == ["The link ends", "Visitors", "Styles and scripts"])
        #expect(ShareText.endValue(try Self.end(), in: try Self.zone()) == "18:40")
        #expect(ShareText.endValue(nil) == "When I stop it")
        #expect(ShareText.defaultsFooter == "The confirmation window shows these defaults. A change there applies to that one share only.")
    }

    @Test func theVisitorsNameTheCountAndTheLastVisit() {
        #expect(ShareText.visitors(0, lastVisit: nil) == "No visitors yet")
        #expect(ShareText.visitors(2, lastVisit: Self.now.addingTimeInterval(-60), now: Self.now) == "2 visitors, the last one 1 minute ago")
        #expect(ShareText.visitors(1, lastVisit: Self.now.addingTimeInterval(-30), now: Self.now) == "1 visitor, the last one less than a minute ago")
        #expect(ShareText.visitors(3, lastVisit: nil) == "3 visitors")
        #expect(ShareText.visitors(2, lastVisit: Self.now.addingTimeInterval(-7200), now: Self.now) == "2 visitors, the last one 2 hours ago")
    }

    @Test(arguments: [(0, "Requests (0)"), (12, "Requests (12)"), (99, "Requests (99)"), (100, "Requests (99+)"), (250, "Requests (99+)")])
    func theCountOfTheRequestsStopsAt99(count: Int, title: String) {
        #expect(ShareText.requestsButton(count) == title)
    }

    @Test func theCountOfTheOpenLinksHasOneAndMore() {
        #expect(ShareText.openLinks(1) == "1 public link is open")
        #expect(ShareText.openLinks(7) == "7 public links are open")
    }

    @Test func eachStepHasItsOwnTitle() {
        let steps: [ShareStep] = [.downloadCloudflared, .buildAssets, .openLink]

        #expect(ShareText.stepTitle(.downloadCloudflared).contains("cloudflared"))
        #expect(Set(steps.map(ShareText.stepTitle)).count == 3)
    }

    @Test func onlyAnEndThatTheUserDidNotAskForGetsANotification() throws {
        let hint = "Share the site again and send the new address to the people who need it."

        #expect(ShareText.stoppedNotification(.sleep, endsAt: nil) == ShareText.sleepNotification)
        #expect(ShareText.stoppedNotification(.stopped, endsAt: nil) == nil)
        #expect(ShareText.stoppedNotification(.appQuit, endsAt: nil) == nil)
        #expect(ShareText.stoppedNotification(.siteGone, endsAt: nil) == nil)
        #expect(ShareText.stoppedNotification(.failed("x"), endsAt: nil) == "x")
        #expect(try #require(ShareText.stoppedNotification(.endTime, endsAt: try Self.end(), in: try Self.zone())).contains("18:40"))
        #expect(ShareText.stoppedNotification(.endTime, endsAt: nil) == "The link stopped at its end time. The old address no longer works.")
        #expect(try #require(ShareText.stoppedNotification(.connectionLost, endsAt: nil)).hasSuffix(hint))
        #expect(try #require(ShareText.stoppedNotification(.nexusdStopped, endsAt: nil)).hasSuffix(hint))
    }

    @Test func theQuitAndTheUpdateNameTheCountOfTheLinks() {
        #expect(ShareText.quitTitle(1) == "Quit Nexus and stop 1 public link?")
        #expect(ShareText.quitTitle(2) == "Quit Nexus and stop 2 public links?")
        #expect(ShareText.quitMessage == "Nexus stops each public link when it quits. Then the links no longer work for visitors.")
        #expect(ShareText.updateLine(1) == "1 public link stops too. Its address then no longer works.")
        #expect(ShareText.updateLine(2) == "2 public links stop too. Their addresses then no longer work.")
    }

    @Test func theChoicesHaveTheTextsOfTheDesign() {
        #expect(ShareDuration.allCases.map(\.title) == ["After 1 hour", "After 4 hours", "After 8 hours", "When I stop it"])
        #expect(ShareViteMode.allCases.map(\.title) == ["Live", "Build"])
        #expect(ShareAddressKind.random.title == "A new random address")
        #expect(ShareAddressKind.ownDomain.title == "An address on my domain")
    }

    @Test func theWarningsHaveTheApprovedTexts() {
        #expect(ShareWarning.sendsRealMail.text == "This site can send real mail. Visitors can make it send mail.")
        #expect(ShareWarning.oauthLogin.text == "Logins with Google, GitHub or another OAuth provider do not work on a random address. Use your own domain for them.")
        #expect(ShareWarning.serverSentEvents.text == "A page can stream text, for example an AI answer. On a random address that text arrives all at once.")
        #expect(ShareWarning.viteInTerminal.text == "Vite runs in a terminal. Nexus cannot stop it for Build. Stop it there first, or choose Live.")
        #expect(ShareWarning.customAccessRules.text == "The custom nginx lines of this site allow or deny addresses. The web server of Nexus (nginx) sees each visitor as this Mac. So these lines do not stop visitors.")
        #expect(ShareWarning.mixHot.text == "This site uses Laravel Mix with npm run hot. Visitors cannot load the styles and scripts of that hot server. Stop npm run hot and run npm run prod first.")
    }

    @Test(arguments: ShareWarning.allCases)
    func eachWarningHasATextThatEndsWithAFullStop(warning: ShareWarning) {
        #expect(warning.text.hasSuffix("."))
    }

    @Test func theSheetShowsViteInATerminalOnlyWithBuildAndOAuthAndStreamsOnlyOnARandomAddress() {
        var build = ShareOptions.standard
        build.viteMode = .build
        var ownDomain = ShareOptions.standard
        ownDomain.address = .ownDomain

        #expect(!ShareWarning.viteInTerminal.applies(to: .standard))
        #expect(ShareWarning.viteInTerminal.applies(to: build))
        #expect(ShareWarning.oauthLogin.applies(to: .standard))
        #expect(!ShareWarning.oauthLogin.applies(to: ownDomain))
        #expect(!ShareWarning.serverSentEvents.applies(to: ownDomain))
        #expect(ShareWarning.sendsRealMail.applies(to: ownDomain))
    }
}
