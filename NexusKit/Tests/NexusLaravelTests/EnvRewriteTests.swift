import Testing
@testable import NexusLaravel

struct EnvRewriteTests {
    private let hosts = [
        HostRewrite(from: "my.shop.test", to: "my.shop-fix.test"),
        HostRewrite(from: ".shop.test", to: ".shop-fix.test"),
    ]

    private func rewrite(_ text: String, keys: [String: String] = [:]) -> String {
        EnvRewrite.apply(to: text, hosts: hosts, keys: keys)
    }

    @Test func theKeysThatLookLikeARedisIndexGiveTheirNumbers() {
        let text = """
        REDIS_DB=2
        REDIS_CACHE_DB="20"
        export REDIS_SESSIONS_DATABASE=21
        HORIZON_DB='22'
        REDIS_PORT=16379
        DB_DATABASE=shop
        APP_DEBUG=1
        # REDIS_QUEUE_DB=23
        REDIS_REPORTS_DB=24
        REDIS_LOCK_DB=25 # the locks

        """

        #expect(EnvRewrite.redisIndexes(in: text) == [2, 20, 21, 22, 24, 25])
    }

    @Test(arguments: [
        ("APP_URL=https://my.shop.test", "APP_URL=https://my.shop-fix.test"),
        ("APP_URL=\"https://my.shop.test/\"", "APP_URL=\"https://my.shop-fix.test/\""),
        ("export APP_URL=https://my.shop.test:8443", "export APP_URL=https://my.shop-fix.test:8443"),
        ("SESSION_DOMAIN=.shop.test", "SESSION_DOMAIN=.shop-fix.test"),
        ("SESSION_DOMAIN=*.shop.test", "SESSION_DOMAIN=*.shop-fix.test"),
        ("API_URL=https://api.shop.test", "API_URL=https://api.shop-fix.test"),
        ("OTHER=notmy.shop.test", "OTHER=notmy.shop-fix.test"),
        ("MAIL_FROM_ADDRESS=hello@my.shop.test", "MAIL_FROM_ADDRESS=hello@my.shop-fix.test"),
        ("APP_URL=https://MY.SHOP.TEST", "APP_URL=https://my.shop-fix.test"),
    ])
    func aHostInAValueGetsTheWorkspaceHost(line: String, expected: String) {
        #expect(rewrite(line) == expected)
    }

    @Test(arguments: [
        "OTHER=notshop.test",
        "OTHER=not-my.shop-test",
        "OTHER=my.shop.testing",
        "OTHER=my.shop.test-two",
        "OTHER=my.shop.test.example",
        "OTHER=shop.test",
        "# APP_URL=https://my.shop.test",
        "   # APP_URL=https://my.shop.test",
        "APP_URL=\"${APP_SCHEMA}://${APP_HOST}\"",
        "SESSION_DOMAIN=\".${APP_HOST}\"",
        "PLAIN LINE my.shop.test",
    ])
    func anotherValueStaysAsItIs(line: String) {
        #expect(rewrite(line) == line)
    }

    @Test func aKeyGetsItsNewValueAndAllOtherLinesStay() {
        let text = "# Database\nDB_HOST=127.0.0.1\nDB_DATABASE=shop # the main one\n\nREDIS_DB=\n"

        let result = rewrite(text, keys: ["DB_DATABASE": "shop_fix", "REDIS_DB": "16"])

        #expect(result == "# Database\nDB_HOST=127.0.0.1\nDB_DATABASE=shop_fix\n\nREDIS_DB=16\n")
    }

    @Test func aKeyWithoutALineGetsALineAtTheEnd() {
        #expect(rewrite("APP_NAME=Shop\n", keys: ["B_KEY": "2", "A_KEY": "1"]) == "APP_NAME=Shop\nA_KEY=1\nB_KEY=2\n")
    }

    @Test func aFileWithoutANewLineAtTheEndGetsOneBeforeANewKey() {
        #expect(rewrite("APP_NAME=Shop", keys: ["A_KEY": "1"]) == "APP_NAME=Shop\nA_KEY=1\n")
    }

    @Test func anEmptyFileGetsTheKeys() {
        #expect(rewrite("", keys: ["A_KEY": "1"]) == "A_KEY=1\n")
    }

    @Test func aValueWithSpecialCharactersGetsQuotes() {
        #expect(rewrite("A=1", keys: ["A": "two words"]) == "A=\"two words\"")
        #expect(rewrite("A=1", keys: ["A": "a#b"]) == "A=\"a#b\"")
        #expect(rewrite("A=1", keys: ["A": "say \"hi\""]) == "A=\"say \\\"hi\\\"\"")
    }

    @Test func aKeyOnTwoLinesChangesOnBothLines() {
        #expect(rewrite("A=1\nA=2\n", keys: ["A": "3"]) == "A=3\nA=3\n")
    }

    @Test func theChangesNameEachKeyWithAHostOnce() {
        let text = "APP_URL=\"https://my.shop.test\"\nSESSION_DOMAIN=.shop.test\nAPP_NAME=Shop\n# X=my.shop.test\n"

        let changes = EnvRewrite.hostChanges(in: text, hosts: hosts)

        #expect(changes.map(\.key) == ["APP_URL", "SESSION_DOMAIN"])
        #expect(changes.map(\.value) == ["https://my.shop-fix.test", ".shop-fix.test"])
    }
}
