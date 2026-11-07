import Foundation
import Testing
@testable import NexusCore

struct WordPressURLTests {
    @Test(arguments: [
        ("https://blog.test:8443", "https://blog.test:8443/", true),
        ("https://BLOG.test:8443", "https://blog.test:8443", true),
        ("https://blog.test:443", "https://blog.test", true),
        ("http://blog.test:80/", "http://blog.test", true),
        ("http://blog.test:8888", "https://blog.test:8443", false),
        ("https://blog.test", "https://blog.test:8443", false),
        ("https://blog.test/wp", "https://blog.test", false),
        ("http://blog.test", "https://blog.test", false),
    ])
    func urlsAreTheSameWithoutTheStandardPortAndTheLastSlash(first: String, second: String, same: Bool) {
        #expect(WordPressURL.same(first, second) == same)
    }

    @Test func theSixFormsChangeHTTPSFirst() {
        let passes = WordPressURL.replacements(from: "http://blog.test:8888/", to: "https://blog.test:8443")

        #expect(passes.map(\.search) == [
            "https://blog.test:8888",
            "http://blog.test:8888",
            "https%3A%2F%2Fblog.test%3A8888",
            "http%3A%2F%2Fblog.test%3A8888",
            #"https:\/\/blog.test:8888"#,
            #"http:\/\/blog.test:8888"#,
        ])
        #expect(passes.map(\.replace) == [
            "https://blog.test:8443",
            "https://blog.test:8443",
            "https%3A%2F%2Fblog.test%3A8443",
            "https%3A%2F%2Fblog.test%3A8443",
            #"https:\/\/blog.test:8443"#,
            #"https:\/\/blog.test:8443"#,
        ])
        #expect(passes.allSatisfy { $0.counts })
    }

    @Test func aFormThatIsTheNewURLAlreadyIsNoPass() {
        let passes = WordPressURL.replacements(from: "http://blog.test", to: "https://blog.test")

        #expect(passes.map(\.search) == ["http://blog.test", "http%3A%2F%2Fblog.test", #"http:\/\/blog.test"#])
    }

    @Test func aNewURLThatStartsWithTheOldURLKeepsThePlacesThatHaveItAlready() {
        let passes = WordPressURL.replacements(from: "https://blog.test", to: "https://blog.test:8443", token: "nexus-keep-1")
        var text = "https://blog.test/a https://blog.test:8443/b http://blog.test/c"

        for pass in passes {
            text = text.replacingOccurrences(of: pass.search, with: pass.replace)
        }

        #expect(Array(passes.prefix(4).map(\.search)) == ["https://blog.test:8443", "https://blog.test", "nexus-keep-1", "http://blog.test"])
        #expect(passes.filter { $0.counts }.count == 6)
        #expect(text == "https://blog.test:8443/a https://blog.test:8443/b https://blog.test:8443/c")
    }

    @Test func theDomainOfANetworkHasThePortWhenItIsNotTheStandardPort() {
        #expect(WordPressURL.domain(of: "https://blog.test:8443/") == "blog.test:8443")
        #expect(WordPressURL.domain(of: "https://Blog.test") == "blog.test")
    }

    @Test func twoOldURLsThatDifferOnlyInTheSchemeGetOneSetOfPasses() {
        let plan = WordPressURLPlan(to: "https://shop.test:8443", databaseFrom: "http://shop.test", configFrom: "https://shop.test/")

        #expect(plan.oldURLs.count == 1)
    }

    @Test func anotherChangeOfAConstantKeepsTheValueOfJustBeforeIt() throws {
        let text = "<?php\ndefine( 'WP_HOME', 'http://a.test' );\n"
        let first = try #require(WordPressFiles.settingConstant("WP_HOME", to: "https://a.test:8443", in: text, replacingOldLine: true))
        let second = try #require(WordPressFiles.settingConstant("WP_HOME", to: "https://a.test", in: first, replacingOldLine: true))

        #expect(second == "<?php\n// Before Nexus: define( 'WP_HOME', 'https://a.test:8443' );\ndefine( 'WP_HOME', 'https://a.test' );\n")
        #expect(WordPressFiles.restoringConstant("WP_HOME", in: second) == "<?php\ndefine( 'WP_HOME', 'https://a.test:8443' );\n")
    }

    @Test func theSiteAddressOfBedrockHasNoFolderOfWordPress() {
        let config = WordPressConfig(home: "http://shop.test", siteURL: "http://shop.test/wp")

        #expect(WordPressURL.siteAddress(home: "https://www.shop.nl/wp/", isBedrock: true, config: config) == "https://www.shop.nl")
        #expect(WordPressURL.siteAddress(home: "https://www.shop.nl", isBedrock: true, config: config) == "https://www.shop.nl")
        #expect(WordPressURL.siteAddress(home: "http://localhost:8888/wp", isBedrock: false, config: config) == "http://localhost:8888/wp")
    }

    @Test func thePlanChangesBothOldURLsOnceWithTheLongestFirst() {
        let both = WordPressURLPlan(to: "https://shop.test:8443", databaseFrom: "http://shop.test", configFrom: "https://www.shop.nl")
        let same = WordPressURLPlan(to: "https://shop.test:8443", databaseFrom: "http://shop.test/", configFrom: "http://shop.test")

        #expect(both.oldURLs == ["https://www.shop.nl", "http://shop.test"])
        #expect(same.oldURLs == ["http://shop.test/"])
    }

    @Test func aConstantGetsANewValueAndItsOldLineBack() throws {
        let text = "<?php\ndefine( 'WP_HOME', 'http://blog.test:8888' );\ndefine('WP_SITEURL', 'http://blog.test:8888/wp');\n"
        let changed = try #require(WordPressFiles.settingConstant("WP_HOME", to: "https://blog.test:8443", in: text))

        #expect(changed == "<?php\n// Before Nexus: define( 'WP_HOME', 'http://blog.test:8888' );\ndefine( 'WP_HOME', 'https://blog.test:8443' );\ndefine('WP_SITEURL', 'http://blog.test:8888/wp');\n")
        #expect(WordPressFiles.restoringConstant("WP_HOME", in: changed) == text)
        #expect(WordPressFiles.restoringConstant("WP_SITEURL", in: changed) == nil)
        #expect(WordPressFiles.settingConstant("WP_HOMEPAGE", to: "x", in: text) == nil)
    }
}
