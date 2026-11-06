import Foundation
import Testing
@testable import NexusMail

struct MailpitAPIErrorTests {
    @Test(arguments: [
        (MailpitAPIError.noMail("7GfftBRB"), "The inbox has no mail with the id 7GfftBRB."),
        (MailpitAPIError.noMail("latest"), "The inbox is empty."),
        (MailpitAPIError.status(500, "api/v1/messages"), "Mailpit answered api/v1/messages with HTTP status 500."),
    ])
    func theAppShowsTheTextOfTheError(error: MailpitAPIError, text: String) {
        #expect((error as Error).localizedDescription == text)
    }
}
