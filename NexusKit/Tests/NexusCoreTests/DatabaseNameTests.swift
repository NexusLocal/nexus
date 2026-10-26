import Testing
@testable import NexusCore

struct DatabaseNameTests {
    @Test func aNameWithLettersDigitsUnderscoresAndHyphensIsValid() throws {
        #expect(try DatabaseName.validated("3rdrisk_platform") == "3rdrisk_platform")
        #expect(try DatabaseName.validated("shop-ticket-123") == "shop-ticket-123")
    }

    @Test(arguments: ["", "a;b", "shop db", "shop`", "shop'", "shöp", "--force", String(repeating: "a", count: 64)])
    func aNameThatNeedsQuotesOrIsTooLongIsRefused(_ name: String) {
        #expect(throws: DatabaseNameError.invalid(name)) {
            try DatabaseName.validated(name)
        }
    }
}
