import Foundation
import Testing
@testable import NexusCore

struct LiveURLRewriterTests {
    let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://shop.com", to: "https://shop-ticket-150.test")])!

    func rewritten(_ text: String, with rewriter: LiveURLRewriter? = nil) -> String {
        guard let result = (rewriter ?? self.rewriter).rewrite(Array(text.utf8)) else {
            return text
        }

        return String(decoding: result.bytes, as: UTF8.self)
    }

    @Test(arguments: [
        ("https://www.shop.com/about", "https://shop-ticket-150.test/about"),
        ("https://shop.com/about", "https://shop-ticket-150.test/about"),
        ("http://www.shop.com", "https://shop-ticket-150.test"),
        ("http://shop.com", "https://shop-ticket-150.test"),
        ("//shop.com/logo.png", "//shop-ticket-150.test/logo.png"),
        (#"https:\/\/shop.com\/x"#, #"https:\/\/shop-ticket-150.test\/x"#),
        ("https%3A%2F%2Fshop.com%2Fx", "https%3A%2F%2Fshop-ticket-150.test%2Fx"),
        ("https%3a%2f%2fshop.com", "https%3a%2f%2fshop-ticket-150.test"),
        ("HTTPS://Shop.com/About", "https://shop-ticket-150.test/About"),
        ("See https://shop.com.", "See https://shop-ticket-150.test."),
        ("info@shop.com", "info@shop.com"),
        ("mailto:info@shop.com", "mailto:info@shop.com"),
        ("Welcome to shop.com", "Welcome to shop.com"),
        ("https://shop.com.au", "https://shop.com.au"),
        ("https://shop.community", "https://shop.community"),
        ("https://shop.com:8080/x", "https://shop.com:8080/x"),
        ("https://cdn.shop.com/x.jpg", "https://cdn.shop.com/x.jpg"),
        ("ftp://shop.com", "ftp://shop.com"),
        ("xhttps://shop.com", "xhttps://shop.com"),
        ("https://shop.com-old.net", "https://shop.com-old.net"),
        (#"<a href="https://shop.com">"#, #"<a href="https://shop-ticket-150.test">"#),
    ])
    func eachFormOfTheTableChangesOrStays(text: String, expected: String) {
        #expect(rewritten(text) == expected)
    }

    @Test func aWorkspaceURLThatStartsWithTheOldURLDoesNotChangeTwice() {
        let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://shop.test", to: "https://shop.test:8443")])!

        #expect(rewritten("https://shop.test/a https://shop.test", with: rewriter) == "https://shop.test:8443/a https://shop.test:8443")
    }

    @Test func thePortOfNexusIsEncodedInTheEncodedForm() {
        let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://shop.com", to: "https://shop-ticket-150.test:8443")])!

        #expect(rewritten("https%3A%2F%2Fshop.com%2Fx", with: rewriter) == "https%3A%2F%2Fshop-ticket-150.test%3A8443%2Fx")
        #expect(rewritten(#"https:\/\/shop.com"#, with: rewriter) == #"https:\/\/shop-ticket-150.test:8443"#)
    }

    @Test func aHomeWithAPathChangesOnlyBelowThatPath() {
        let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://shop.com/blog", to: "https://shop-ticket-150.test")])!

        #expect(rewritten("https://shop.com/blog/post", with: rewriter) == "https://shop-ticket-150.test/post")
        #expect(rewritten("https://shop.com/contact", with: rewriter) == "https://shop.com/contact")
        #expect(rewritten("https://shop.com/blogger", with: rewriter) == "https://shop.com/blogger")
    }

    @Test func theLongestLiveURLWins() {
        let rewriter = LiveURLRewriter(rules: [
            LiveURLRule(from: "https://shop.com", to: "https://ws.test"),
            LiveURLRule(from: "https://shop.com/wp", to: "https://ws.test/core"),
        ])!

        #expect(rewritten("https://shop.com/wp/wp-admin https://shop.com/about", with: rewriter) == "https://ws.test/core/wp-admin https://ws.test/about")
    }

    @Test func aLiveURLWithAPortMatchesOnlyThatPort() {
        let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://staging.shop.com:8080", to: "https://ws.test")])!

        #expect(rewritten("https://staging.shop.com:8080/x https://staging.shop.com/x", with: rewriter) == "https://ws.test/x https://staging.shop.com/x")
    }

    @Test func aLiveURLWithWwwAlsoMatchesWithoutIt() {
        let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://www.shop.com/", to: "https://ws.test")])!

        #expect(rewritten("http://shop.com/a https://WWW.shop.com", with: rewriter) == "https://ws.test/a https://ws.test")
    }
}

struct SerializedPHPTests {
    let rewriter = LiveURLRewriter(rules: [LiveURLRule(from: "https://shop.com", to: "https://shop-ticket-150.test")])!

    func rewritten(_ text: String) -> ValueRewrite {
        SerializedPHP.rewrite(Array(text.utf8), with: rewriter)
    }

    func text(_ result: ValueRewrite) -> String? {
        guard case .changed(let bytes, _) = result else {
            return nil
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func aStringGetsItsNewLength() {
        #expect(text(rewritten(#"s:29:"https://shop.com/img/logo.png";"#)) == #"s:41:"https://shop-ticket-150.test/img/logo.png";"#)
    }

    @Test func anArrayKeepsItsKeysAndChangesItsValues() {
        let value = #"a:2:{s:16:"https://shop.com";s:16:"https://shop.com";i:5;s:20:"https://shop.com/éa";}"#

        #expect(text(rewritten(value)) == #"a:2:{s:16:"https://shop.com";s:28:"https://shop-ticket-150.test";i:5;s:32:"https://shop-ticket-150.test/éa";}"#)
    }

    @Test func anObjectOfAClassThatIsNotLoadedChangesToo() {
        let value = #"O:8:"Elements":2:{s:3:"url";s:16:"https://shop.com";s:4:"size";d:1.5;}"#

        #expect(text(rewritten(value)) == #"O:8:"Elements":2:{s:3:"url";s:28:"https://shop-ticket-150.test";s:4:"size";d:1.5;}"#)
    }

    @Test func serializedPHPInsideAStringChangesFirst() {
        let inner = #"a:1:{i:0;s:16:"https://shop.com";}"#
        let value = "s:\(inner.utf8.count):\"\(inner)\";"
        let newInner = #"a:1:{i:0;s:28:"https://shop-ticket-150.test";}"#

        #expect(text(rewritten(value)) == "s:\(newInner.utf8.count):\"\(newInner)\";")
    }

    @Test func jsonInsideAStringChangesItsEscapedSlashes() {
        let json = #"{"url":"https:\/\/shop.com\/a"}"#
        let value = "a:1:{s:4:\"json\";s:\(json.utf8.count):\"\(json)\";}"
        let newJSON = #"{"url":"https:\/\/shop-ticket-150.test\/a"}"#

        #expect(text(rewritten(value)) == "a:1:{s:4:\"json\";s:\(newJSON.utf8.count):\"\(newJSON)\";}")
    }

    @Test func aCustomObjectGetsItsNewContentLength() {
        let content = #"x:i:0;s:16:"https://shop.com";"#
        let value = "C:11:\"ArrayObject\":\(content.utf8.count):{\(content)}"
        let changed = text(rewritten(value)) ?? ""

        #expect(changed.hasPrefix("C:11:\"ArrayObject\":\(content.utf8.count + 12):{"))
        #expect(SerializedPHP.isValid(Array(changed.utf8)))
    }

    @Test func aValueWithWrongLengthsChangesAsPlainText() {
        #expect(text(rewritten(#"s:5:"https://shop.com";"#)) == #"s:5:"https://shop-ticket-150.test";"#)
    }

    @Test func aValueWithoutALiveLinkStaysTheSame() {
        #expect(rewritten(#"a:1:{i:0;s:3:"abc";}"#) == .unchanged)
    }

    @Test func anEscapedStringOfOldPHPGoesToWPCLI() {
        #expect(rewritten(#"S:16:"https://shop.com";"#) == .unsafe)
    }
}

struct SQLDumpFilterTests {
    static let rules = [LiveURLRule(from: "https://shop.com", to: "https://ws.test")]

    func filtered(_ sql: String, plan: SQLDumpFilter.Plan = .init(prefix: "wp_", rules: rules), block: Int = 7) -> (sql: String, report: SQLDumpFilter.Report) {
        let filter = SQLDumpFilter(plan: plan)
        var output = Data()
        let input = Array(sql.utf8)
        var start = 0

        while start < input.count {
            let end = min(input.count, start + block)
            input[start..<end].withUnsafeBytes { chunk in
                filter.feed(chunk) { output.append(contentsOf: $0) }
            }
            start = end
        }

        filter.finish { output.append(contentsOf: $0) }
        return (String(decoding: output, as: UTF8.self), filter.report)
    }

    static let createPosts = """
    CREATE TABLE `wp_posts` (
      `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
      `post_content` longtext NOT NULL COMMENT 'see https://shop.com',
      `post_status` enum('publish','draft') NOT NULL DEFAULT 'publish',
      `guid` varchar(255) NOT NULL DEFAULT '',
      PRIMARY KEY (`ID`),
      KEY `post_status` (`post_status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

    """

    @Test(arguments: [1, 2, 3, 7, 64, 100_000])
    func theRowsOfThePrefixChangeAndGuidStays(block: Int) {
        let sql = Self.createPosts + "INSERT INTO `wp_posts` VALUES (1,'<a href=\"https://shop.com/a\">It\\'s</a>','publish','https://shop.com/?p=1'),(2,'x','draft','https://shop.com/?p=2');\n"
        let result = filtered(sql, block: block)

        #expect(result.sql == Self.createPosts + "INSERT INTO `wp_posts` VALUES (1,'<a href=\\\"https://ws.test/a\\\">It\\'s</a>','publish','https://shop.com/?p=1'),(2,'x','draft','https://shop.com/?p=2');\n")
        #expect(result.report.links == 1)
        #expect(result.report.tables == ["wp_posts"])
        #expect(result.report.uncertainTables.isEmpty)
    }

    @Test func aTableWithoutThePrefixStays() {
        let sql = "INSERT INTO `other_posts` VALUES (1,'https://shop.com');\nINSERT INTO `wp_options` VALUES (1,'home','https://shop.com','yes');\n"

        #expect(filtered(sql).sql == "INSERT INTO `other_posts` VALUES (1,'https://shop.com');\nINSERT INTO `wp_options` VALUES (1,'home','https://ws.test','yes');\n")
    }

    @Test func theCheckFindsHomeSiteURLAndTheTables() {
        let sql = """
        INSERT INTO `wp_comments` VALUES (1,'https://shop.com/x');
        INSERT INTO `wp_options` (`option_id`, `option_name`, `option_value`, `autoload`) VALUES (1,'siteurl','https://shop.com/wp','yes'),(2,'home','https://shop.com','yes');
        INSERT INTO `wp_site` VALUES (1,'shop.com','/');
        INSERT INTO `wp_blogs` VALUES (1,1,'shop.com','/');

        """
        let report = filtered(sql, plan: .init(prefix: "wp_")).report

        #expect(report.home == "https://shop.com")
        #expect(report.siteURL == "https://shop.com/wp")
        #expect(report.networkDomain == "shop.com")
        #expect(report.tables == ["wp_comments", "wp_options", "wp_site", "wp_blogs"])
        #expect(report.links == 0)
    }

    @Test func aColumnListGivesTheOrderOfTheColumns() {
        let sql = "INSERT INTO wp_posts (guid, ID, post_content) VALUES ('https://shop.com/?p=1', 1, 'https://shop.com/b');\n"

        #expect(filtered(sql).sql == "INSERT INTO wp_posts (guid, ID, post_content) VALUES ('https://shop.com/?p=1', 1, 'https://ws.test/b');\n")
    }

    @Test func aDumpWithoutCreateTableUsesTheColumnsOfThePlan() {
        let sql = "INSERT INTO `wp_2_posts` VALUES (1,'https://shop.com/b','https://shop.com/?p=1');\n"
        let plan = SQLDumpFilter.Plan(prefix: "wp_", rules: Self.rules, columns: ["wp_2_posts": ["ID", "post_content", "guid"]])

        #expect(filtered(sql, plan: plan).sql == "INSERT INTO `wp_2_posts` VALUES (1,'https://ws.test/b','https://shop.com/?p=1');\n")
    }

    @Test func postsWithoutAKnownGuidColumnGoToWPCLI() {
        let sql = "INSERT INTO `wp_posts` VALUES (1,'https://shop.com/b');\n"
        let result = filtered(sql)

        #expect(result.sql == sql)
        #expect(result.report.uncertainTables == ["wp_posts"])
    }

    @Test func quotesCommentsAndPrefixesOfStringsStay() {
        let sql = """
        -- a comment with ' a quote
        /* another 'one' */
        # and "one" more
        /*!40101 SET NAMES utf8mb4 */;
        INSERT INTO `wp_options` VALUES (1,'it''s','https://shop.com',_binary 'https://shop.com/x',"https://shop.com/\\"y");

        """
        let expected = """
        -- a comment with ' a quote
        /* another 'one' */
        # and "one" more
        /*!40101 SET NAMES utf8mb4 */;
        INSERT INTO `wp_options` VALUES (1,'it''s','https://ws.test',_binary 'https://ws.test/x',"https://ws.test/\\"y");

        """

        #expect(filtered(sql).sql == expected)
    }

    @Test func aHexValueChangesAndStaysHex() {
        let value = Array(#"s:16:"https://shop.com";"#.utf8)
        let hex = String(decoding: SQLDumpFilter.encodeHex(value, lowercase: false), as: UTF8.self)
        let newHex = String(decoding: SQLDumpFilter.encodeHex(Array(#"s:15:"https://ws.test";"#.utf8), lowercase: false), as: UTF8.self)
        let sql = "INSERT INTO `wp_options` VALUES (1,'a',0x\(hex),X'\(hex)');\n"

        #expect(filtered(sql).sql == "INSERT INTO `wp_options` VALUES (1,'a',0x\(newHex),X'\(newHex)');\n")
    }

    @Test func aTriggerWithAnotherDelimiterStays() {
        let sql = """
        DELIMITER ;;
        /*!50003 CREATE*/ /*!50003 TRIGGER t BEFORE INSERT ON wp_posts FOR EACH ROW BEGIN SET NEW.post_content = 'https://shop.com'; INSERT INTO wp_log VALUES ('x'); END */;;
        DELIMITER ;
        INSERT INTO `wp_options` VALUES (1,'home','https://shop.com','yes');

        """
        let result = filtered(sql)

        #expect(result.sql.contains("SET NEW.post_content = 'https://shop.com'"))
        #expect(result.sql.contains("(1,'home','https://ws.test','yes')"))
    }

    @Test func windowsLineEndsAndAByteOrderMarkDoNotMatter() {
        let sql = "\u{FEFF}SET NAMES utf8mb4;\r\nINSERT INTO `wp_options` VALUES (1,'home','https://shop.com\r\n','yes');\r\n"

        #expect(filtered(sql, block: 3).sql == "\u{FEFF}SET NAMES utf8mb4;\r\nINSERT INTO `wp_options` VALUES (1,'home','https://ws.test\\r\\n','yes');\r\n")
    }

    @Test func serializedValuesInARowGetTheirNewLengths() {
        let sql = #"INSERT INTO `wp_options` VALUES (1,'widget','a:1:{i:0;s:16:\"https://shop.com\";}','yes');"# + "\n"

        #expect(filtered(sql).sql == #"INSERT INTO `wp_options` VALUES (1,'widget','a:1:{i:0;s:15:\"https://ws.test\";}','yes');"# + "\n")
    }

    @Test func otherStatementsGoThroughUnchanged() {
        let sql = "LOCK TABLES `wp_posts` WRITE;\nUPDATE wp_options SET option_value = 'https://shop.com';\nCREATE TABLE `wp_x` (`a` text COMMENT 'https://shop.com');\n"

        #expect(filtered(sql).sql == sql)
    }

    @Test func anInsertWithSelectGoesToWPCLIWhenItHasALink() {
        let sql = "INSERT INTO `wp_options` SELECT 1,'home','https://shop.com','yes';\n"
        let result = filtered(sql)

        #expect(result.sql == sql)
        #expect(result.report.uncertainTables == ["wp_options"])
    }
}

struct WordPressDumpCheckTests {
    func check(home: String?, siteURL: String?, added: [String] = []) -> WordPressDumpCheck {
        WordPressDumpCheck(file: "/d.sql", size: 1, modified: 1, prefix: "wp_", addedURLs: added, home: home, siteURL: siteURL)
    }

    @Test func aSiteURLBelowHomeNeedsNoOwnRule() {
        let rules = check(home: "https://shop.com", siteURL: "https://shop.com/wp").rules(home: "https://ws.test", siteURL: "https://ws.test/wp")

        #expect(rules == [LiveURLRule(from: "https://shop.com", to: "https://ws.test")])
    }

    @Test func aSiteURLInAnotherFolderGetsItsOwnRule() {
        let rules = check(home: "https://shop.com", siteURL: "https://shop.com/wp").rules(home: "https://ws.test", siteURL: "https://ws.test")

        #expect(rules == [LiveURLRule(from: "https://shop.com", to: "https://ws.test"), LiveURLRule(from: "https://shop.com/wp", to: "https://ws.test")])
    }

    @Test func anAddedURLGoesToTheHomeOfTheWorkspace() {
        let found = check(home: "https://shop.com", siteURL: "https://shop.com", added: ["https://staging.shop.com"])

        #expect(found.rules(home: "https://ws.test", siteURL: "https://ws.test") == [
            LiveURLRule(from: "https://shop.com", to: "https://ws.test"),
            LiveURLRule(from: "https://staging.shop.com", to: "https://ws.test"),
        ])
        #expect(found.liveURLs == ["https://shop.com", "https://staging.shop.com"])
        #expect(found.fallbackURLs == ["https://shop.com", "https://www.shop.com", "https://staging.shop.com", "https://www.staging.shop.com"])
    }

    @Test func theCheckFitsOnlyTheSameFileAndURLs() {
        let found = check(home: "https://shop.com", siteURL: nil)

        #expect(found.fits(file: "/d.sql", size: 1, modified: 1.0001, prefix: "wp_", addedURLs: []))
        #expect(!found.fits(file: "/d.sql", size: 2, modified: 1, prefix: "wp_", addedURLs: []))
        #expect(!found.fits(file: "/d.sql", size: 1, modified: 1, prefix: "wp_", addedURLs: ["https://a.com"]))
    }

    @Test(arguments: [
        ("https://staging.shop.com/", "https://staging.shop.com"),
        (" http://Shop.com:8080/blog ", "http://shop.com:8080/blog"),
        ("shop.com", nil),
        ("ftp://shop.com", nil),
        ("https://", nil),
    ])
    func anAddedURLNeedsASchemeAndAHost(value: String, expected: String?) {
        #expect(WordPressURL.liveURL(value) == expected)
    }
}
