import Testing
@testable import NexusCore

struct ShellWordTests {
    @Test func aWordGetsQuotesOnlyWhenItNeedsThem() {
        #expect(ShellWord.quoted("shop_fix") == "shop_fix")
        #expect(ShellWord.quoted("/Users/me/shop/database.sqlite") == "/Users/me/shop/database.sqlite")
        #expect(ShellWord.quoted("/Users/Jane Doe/db.sqlite") == "'/Users/Jane Doe/db.sqlite'")
        #expect(ShellWord.quoted("/Users/jane's/db.sqlite") == #"'/Users/jane'\''s/db.sqlite'"#)
    }
}
