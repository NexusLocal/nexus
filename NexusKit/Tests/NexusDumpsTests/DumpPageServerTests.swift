import Foundation
import NexusCore
import NexusTestSupport
import Testing
@testable import NexusDumps

@Suite(.timeLimit(.minutes(1)))
struct DumpPageServerTests {
    private func server(_ handle: @escaping DumpPageServer.Handler = { request in .message("\(request.method) \(request.path) \(request.query["request"] ?? "")", status: 200) }) throws -> DumpPageServer {
        let server = DumpPageServer(port: 0, token: "secret", handle: handle)
        try server.start()
        return server
    }

    private func request(method: String = "POST", host: String = "127.0.0.1:8026", origin: String? = "http://127.0.0.1:8026", token: String? = "secret", contentType: String? = "application/json") -> PageRequest {
        var headers = ["host": host]
        headers["origin"] = origin
        headers["x-nexus-token"] = token
        headers["content-type"] = contentType
        return PageRequest(method: method, path: "/api/clear", headers: headers)
    }

    @Test func aRequestGivesItsPathItsQueryAndItsHeadersInLowerCase() throws {
        let parsed = try #require(PageRequest.parse(requestLine: "GET /api/dumps?request=a%201&after=12 HTTP/1.1", headerLines: ["Host: 127.0.0.1:8026", "X-Nexus-Token:  abc "]))

        #expect(parsed.method == "GET")
        #expect(parsed.path == "/api/dumps")
        #expect(parsed.query == ["request": "a 1", "after": "12"])
        #expect(parsed.headers == ["host": "127.0.0.1:8026", "x-nexus-token": "abc"])
    }

    @Test func aLineThatIsNotHTTPGivesNoRequest() {
        #expect(PageRequest.parse(requestLine: "GET /", headerLines: []) == nil)
        #expect(PageRequest.parse(requestLine: "GET http://example.com/ HTTP/1.1", headerLines: []) == nil)
        #expect(PageRequest.parse(requestLine: "GET / SMTP", headerLines: []) == nil)
        #expect(PageRequest.parse(requestLine: "GET / HTTP/1.1", headerLines: ["no colon"]) == nil)
    }

    @Test func aGetNeedsOnlyTheHostOfTheServer() {
        let guarding = PageGuard(port: 8026, token: "secret")

        #expect(guarding.refusal(of: request(method: "GET", origin: nil, token: nil, contentType: nil)) == nil)
        #expect(guarding.refusal(of: request(method: "GET", host: "LOCALHOST:8026", origin: nil, token: nil)) == nil)
        #expect(guarding.refusal(of: request(method: "GET", host: "evil.example:8026"))?.status == 403)
        #expect(guarding.refusal(of: request(method: "GET", host: "127.0.0.1:9000"))?.status == 403)
    }

    @Test func aPostNeedsTheOriginOfThePageTheTokenAndJSON() {
        let guarding = PageGuard(port: 8026, token: "secret")

        #expect(guarding.refusal(of: request()) == nil)
        #expect(guarding.refusal(of: request(origin: "http://localhost:8026")) == nil)
        #expect(guarding.refusal(of: request(origin: nil))?.status == 403)
        #expect(guarding.refusal(of: request(origin: "http://evil.example"))?.status == 403)
        #expect(guarding.refusal(of: request(token: nil))?.status == 403)
        #expect(guarding.refusal(of: request(token: "guess"))?.status == 403)
        #expect(guarding.refusal(of: request(contentType: "text/plain"))?.status == 415)
        #expect(guarding.refusal(of: request(method: "DELETE"))?.status == 405)
    }

    @Test func theServerAnswersOnlyWithTheHostOfTheServer() throws {
        let server = try server()
        defer { server.stop() }

        let answer = try PageClient.get("/api/dumps?request=a1", port: server.port)
        let otherHost = try PageClient.get("/api/dumps?request=a1", port: server.port, host: "rebound.example")

        #expect(answer.status == 200)
        #expect(answer.body == #"{"message":"GET /api/dumps a1"}"#)
        #expect(answer.headers["x-frame-options"] == "DENY")
        #expect(answer.headers["cache-control"] == "no-store")
        #expect(otherHost.status == 403)
    }

    @Test func aPostReachesTheHandlerOnlyWithTheToken() throws {
        let server = try server()
        defer { server.stop() }

        let accepted = try PageClient.post("/api/clear", json: #"{"all":true}"#, port: server.port, token: "secret")
        let refused = try PageClient.post("/api/clear", json: #"{"all":true}"#, port: server.port, token: "guess")
        let otherOrigin = try PageClient.post("/api/clear", json: #"{"all":true}"#, port: server.port, token: "secret", origin: "http://evil.example")

        #expect(accepted.status == 200)
        #expect(accepted.body == #"{"message":"POST /api/clear "}"#)
        #expect(refused.status == 403)
        #expect(otherOrigin.status == 403)
    }

    @Test func anOpenPageGetsEachEvent() throws {
        let server = try server()
        defer { server.stop() }
        let page = try PageClient.events(port: server.port)
        defer { page.close() }

        var head: [String] = []

        while let line = try page.readLine(), String(decoding: line, as: UTF8.self) != "retry: 2000" {
            head.append(String(decoding: line, as: UTF8.self))
        }

        let blank = try page.readLine()
        server.send(event: "change", value: ["cleared": true])
        let event = try page.readLine().map { String(decoding: $0, as: UTF8.self) }
        let data = try page.readLine().map { String(decoding: $0, as: UTF8.self) }

        #expect(head.first == "HTTP/1.1 200 OK")
        #expect(head.contains("Content-Type: text/event-stream"))
        #expect(server.hasPages)
        #expect(blank == Data())
        #expect(event == "event: change")
        #expect(data == #"data: {"cleared":true}"#)
    }

    @Test func thePageHasItsTokenAndItsNonceAndNoPlaceholder() {
        let html = DumpPage.html(token: "abc123", nonce: "n0nce", title: "Nexus <Dumps>")

        #expect(html.contains(#"<meta name="nexus-token" content="abc123">"#))
        #expect(html.contains(#"<script nonce="n0nce">"#))
        #expect(html.contains(#"<style nonce="n0nce">"#))
        #expect(html.contains("<title>Nexus &lt;Dumps&gt;</title>"))
        #expect(html.contains("Nexus keeps the newest \(DumpStore.dumpLimit) dumps."))
        #expect(html.hasSuffix("</script>\n</body>\n</html>\n"))
        #expect(!html.contains("{{"))
        #expect(!html.contains("innerHTML"))
    }

    @Test func theServerAnswersThePageItselfWithItsTokenAndANonce() throws {
        let server = try server { _ in .message("The handler does not answer the page.", status: 500) }
        defer { server.stop() }

        let page = try PageClient.get("/", port: server.port)
        let policy = page.headers["content-security-policy"] ?? ""
        let nonce = policy.firstMatch(of: /script-src 'nonce-([0-9a-f]+)'/).map { String($0.1) } ?? "none"

        #expect(page.status == 200)
        #expect(page.headers["content-type"] == "text/html; charset=utf-8")
        #expect(page.body.contains(#"<meta name="nexus-token" content="secret">"#))
        #expect(page.body.contains(#"<script nonce="\#(nonce)">"#))
    }
}
