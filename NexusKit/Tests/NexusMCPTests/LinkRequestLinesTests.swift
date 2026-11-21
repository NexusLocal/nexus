import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusMCP

struct LinkRequestLinesTests {
    private static let english = Locale(identifier: "en_US")
    private static let utc = DumpTimeText(timeZone: TimeZone(identifier: "UTC")!)
    private static let started = Date(timeIntervalSince1970: 1_794_407_528)
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"

    private static func request(_ id: String, host: String = "shop.test", dumps: Int = 0, visitor: String? = "3.18.12.63") -> DumpedRequest {
        DumpedRequest(id: id, kind: .http, method: "POST", target: "/webhooks/stripe", url: "https://\(publicHost)/webhooks/stripe", host: host, site: host, started: started, status: 200, duration: 0.184, dumpCount: dumps, publicLink: PublicLinkRequest(host: host, visitor: visitor, size: 34, contentType: "application/json"))
    }

    private static let detail = ShareRequestDetail(
        id: "4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6",
        requestHeaders: [
            ShareHeader(name: "Host", value: publicHost),
            ShareHeader(name: "Content-Type", value: "application/json"),
            ShareHeader(name: "Stripe-Signature", value: "t=1794414394,v1=5257a8"),
            ShareHeader(name: "Cookie", value: "Hidden by Nexus"),
        ],
        requestBody: #"{"id":"evt_1Q","type":"payment_intent.succeeded"}"#,
        requestBodyBytes: 50,
        requestBodyCut: false,
        status: 200,
        responseHeaders: [ShareHeader(name: "Content-Type", value: "application/json")],
        size: 34
    )

    @Test func theTextOfARequestHasItsRequestAndItsAnswer() {
        let lines = LinkRequestLines.lines(of: Self.request("4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6", dumps: 1), detail: Self.detail, now: Self.started, times: Self.utc, locale: Self.english)

        #expect(lines.joined(separator: "\n") == """
        14:32:08  POST  https://calm-river-tree-lamp.trycloudflare.com/webhooks/stripe  200  184 ms  visitor 3.18.12.63
          request 4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6 · 1 dump
          Request headers
            Host: calm-river-tree-lamp.trycloudflare.com
            Content-Type: application/json
            Stripe-Signature: t=1794414394,v1=5257a8
            Cookie: Hidden by Nexus
          Body
            {
              "id": "evt_1Q",
              "type": "payment_intent.succeeded"
            }
          Answer  200 · 34 bytes · application/json
          Answer headers
            Content-Type: application/json
        """)
    }

    @Test func aRequestWithoutADetailOrWithoutABodySaysWhy() {
        let gone = LinkRequestLines.lines(of: Self.request("a1", visitor: nil), detail: nil, now: Self.started, times: Self.utc, locale: Self.english)
        let empty = ShareRequestDetail(id: "a1", requestHeaders: [], requestBodyCut: false, status: 204, responseHeaders: [], size: 0)
        let noBody = LinkRequestLines.lines(of: Self.request("a1"), detail: empty, now: Self.started, times: Self.utc, locale: Self.english)

        #expect(gone == [
            "14:32:08  POST  https://calm-river-tree-lamp.trycloudflare.com/webhooks/stripe  200  184 ms",
            "  request a1",
            "  [\(LinkRequestText.detailGone)]",
        ])
        #expect(noBody.contains("    [This request has no body.]"))
        #expect(noBody.contains("  Answer  204 · 0 bytes · application/json"))
    }

    @Test func theNewestKeepsTheHostAndTheLimitAndGivesTheOldestFirst() {
        let requests = [Self.request("c"), Self.request("blog", host: "blog.test"), DumpedRequest(id: "plain", kind: .http, method: "GET", target: "/", started: Self.started), Self.request("b"), Self.request("a")]

        #expect(LinkRequestLines.newest(requests, host: "shop.test", limit: 2).map(\.id) == ["b", "c"])
        #expect(LinkRequestLines.newest(requests, host: nil, limit: 10).map(\.id) == ["a", "b", "blog", "c"])
    }

    @Test func theJSONLineHasTheRequestAndTheDetail() throws {
        let line = try LinkRequestLines.json(request: Self.request("a1"), detail: Self.detail)
        let without = try LinkRequestLines.json(request: Self.request("a1"), detail: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        #expect((object["request"] as? [String: Any])?["id"] as? String == "a1")
        #expect(((object["detail"] as? [String: Any])?["requestHeaders"] as? [Any])?.count == 4)
        #expect(without.contains(#""detail":null"#))
        #expect(!line.contains("\n"))
    }
}
