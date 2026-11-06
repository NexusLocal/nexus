import Foundation
import NexusCore
import Testing

struct MailSettingsTests {
    private static let sizes: [(text: String, bytes: Int?)] = [
        ("100MB", 104_857_600),
        ("2gb", 2_147_483_648),
        ("10 MB", 10_485_760),
        ("5000", 5000),
        ("much", nil),
    ]

    @Test(arguments: sizes)
    func aSizeReadsWithItsUnit(text: String, bytes: Int?) {
        #expect(MailSettings.bytes(of: text) == bytes)
    }

    @Test func theDefaultsAreInsideTheirRangesAndAValueOutsideGivesAProblem() {
        var settings = MailSettings()
        let defaults = settings.problem
        settings.outboxDays = 91

        #expect(defaults == nil)
        #expect(settings.problem == "The outbox keeps a mail from 1 to 90 days.")
    }

    @Test func aSettingThatTheFileDoesNotHaveGetsItsDefault() throws {
        let settings = try JSONDecoder().decode(MailSettings.self, from: Data(#"{"outboxMails":20}"#.utf8))

        #expect(settings.outboxMails == 20)
        #expect(settings.inboxMails == 1000)
        #expect(settings.whenFull == .removeOldest)
    }
}
