import Foundation
import NexusCore
import Testing

struct LinkRequestTextTests {
    private static let english = Locale(identifier: "en_US")

    @Test func theIndentedJSONKeepsTheOrderOfTheKeys() {
        let text = #"{"type":"payment_intent.succeeded","id":"evt_1Q","data":{"object":{"amount":2450,"items":[1,2]}}}"#

        #expect(LinkRequestText.indentedJSON(text) == """
        {
          "type": "payment_intent.succeeded",
          "id": "evt_1Q",
          "data": {
            "object": {
              "amount": 2450,
              "items": [
                1,
                2
              ]
            }
          }
        }
        """)
    }

    @Test func aStringWithBracesCommasAndQuotesStaysOneValue() {
        let text = #"{"note":"a {b}, [c]: \"d\" \\","n":1.0}"#

        #expect(LinkRequestText.indentedJSON(text) == """
        {
          "note": "a {b}, [c]: \\"d\\" \\\\",
          "n": 1.0
        }
        """)
    }

    @Test func anEmptyObjectAndAnEmptyArrayStay() {
        #expect(LinkRequestText.indentedJSON(#"{"a":{ },"b":[]}"#) == "{\n  \"a\": {},\n  \"b\": []\n}")
        #expect(LinkRequestText.indentedJSON("{}") == "{}")
        #expect(LinkRequestText.indentedJSON("[]") == "[]")
        #expect(LinkRequestText.indentedJSON("1.0") == "1.0")
    }

    @Test func aTextThatIsNotOneJSONValueHasNoIndents() {
        #expect(LinkRequestText.indentedJSON(#"{"a":1}{"b":2}"#) == nil)
        #expect(LinkRequestText.indentedJSON(#"{"a":"#) == nil)
        #expect(LinkRequestText.shownBody(#"{"a":"#) == #"{"a":"#)
        #expect(LinkRequestText.shownBody("email=ann%40example.com") == "email=ann%40example.com")
        #expect(LinkRequestText.shownBody(" [1,2]") == "[\n  1,\n  2\n]")
        #expect(LinkRequestText.shownBody("12") == "12")
    }

    @Test(arguments: [
        (0, "0 bytes"),
        (1, "1 byte"),
        (999, "999 bytes"),
        (1000, "1 KB"),
        (1250, "1.3 KB"),
        (12_000, "12 KB"),
        (999_999, "1 MB"),
        (3_400_000, "3.4 MB"),
    ])
    func aSizeCountsAThousandBytesAsOneKB(bytes: Int, text: String) {
        #expect(LinkRequestText.size(bytes, locale: Self.english) == text)
    }

    @Test func theNoteOfABodyFollowsItsRules() {
        #expect(LinkRequestText.bodyNote(body: "{}", bytes: 200_000, cut: true, locale: Self.english) == "Nexus keeps only the first 64 KB of this body.")
        #expect(LinkRequestText.bodyNote(body: "{}", bytes: 2, cut: false, locale: Self.english) == nil)
        #expect(LinkRequestText.bodyNote(body: nil, bytes: 3_200_000, cut: true, locale: Self.english) == "Nexus did not keep this body of 3.2 MB, because it is larger than 1 MB.")
        #expect(LinkRequestText.bodyNote(body: nil, bytes: 12_000, cut: false, locale: Self.english) == "This body of 12 KB is not text. So Nexus does not show it.")
        #expect(LinkRequestText.bodyNote(body: nil, bytes: nil, cut: false, locale: Self.english) == "This request has no body.")
        #expect(LinkRequestText.bodyNote(body: "", bytes: 0, cut: false, locale: Self.english) == "This request has no body.")
    }

    @Test func theFilterNamesTheHostOnlyWithMoreLinks() {
        #expect(LinkRequestText.filterLabel(host: "shop.test", linkCount: 1) == "Public link")
        #expect(LinkRequestText.filterLabel(host: "shop.test", linkCount: 2) == "Public link of shop.test")
        #expect(LinkRequestText.markHelp(host: "shop.test") == "This request came through the public link of shop.test.")
        #expect(LinkRequestText.footer == "Nexus keeps the newest 500 requests of each public link. It deletes them when the link ends.")
    }
}
