import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

struct LinkRequestReaderTests {
    private let record = ShareRecord(id: "0123456789abcdef0123456789abcdef", host: "shop.test", site: "shop.test", options: .standard, mode: .localHost, publicHost: "calm-river.trycloudflare.com", started: Date(timeIntervalSince1970: 1_800_000_000), state: .open)

    private func line(method: String? = "GET", uri: String? = "/", status: Int = 200, contentType: String? = nil, body: Data? = nil, bodyBytes: Int? = nil, visitor: String = "3.18.12.63") -> ShareLogLine {
        ShareLogLine(
            time: 1_800_000_010.5,
            request: "4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6",
            status: status,
            visitor: visitor,
            method: method,
            uri: uri,
            host: "calm-river.trycloudflare.com",
            duration: 0.5,
            size: 34,
            contentType: contentType,
            requestHeaders: [["Host", "calm-river.trycloudflare.com"], ["Cookie", "Hidden by Nexus"], ["Broken"]],
            responseHeaders: [["Content-Type", "application/json"]],
            body: body?.base64EncodedString(),
            bodyBytes: bodyBytes ?? body?.count
        )
    }

    @Test func aStaticFileThatDidNotFailStaysOutOfTheList() {
        #expect(LinkRequestReader.isStaticFile(line(uri: "/build/app.css", contentType: "text/css")))
        #expect(LinkRequestReader.isStaticFile(line(uri: "/app.js?v=3", status: 304)))
        #expect(LinkRequestReader.isStaticFile(line(uri: "/@vite/client", contentType: "text/javascript; charset=utf-8")))
        #expect(LinkRequestReader.isStaticFile(line(method: "HEAD", uri: "/logo", contentType: "image/png")))
        #expect(!LinkRequestReader.isStaticFile(line(uri: "/", contentType: "text/html")))
        #expect(!LinkRequestReader.isStaticFile(line(method: "POST", uri: "/api", contentType: "application/javascript")))
        #expect(!LinkRequestReader.isStaticFile(line(uri: "/missing.png", status: 404, contentType: "image/png")))
        #expect(!LinkRequestReader.isStaticFile(line(uri: "/.env", status: 404)))
    }

    @Test func theHeaderHasTheLocalHostThePublicURLAndTheLink() throws {
        let header = try #require(LinkRequestReader.header(of: line(method: "POST", uri: "/webhooks/stripe?x=1", contentType: "application/json"), link: record))

        #expect(header.id == "4f2c0d9e8b7a6f5e4d3c2b1a09f8e7d6")
        #expect(header.kind == .http)
        #expect(header.method == "POST")
        #expect(header.target == "/webhooks/stripe?x=1")
        #expect(header.url == "https://calm-river.trycloudflare.com/webhooks/stripe?x=1")
        #expect(header.host == "shop.test")
        #expect(header.started == Date(timeIntervalSince1970: 1_800_000_010))
        #expect(header.status == 200)
        #expect(header.duration == 0.5)
        #expect(header.publicLink == PublicLinkRequest(host: "shop.test", visitor: "3.18.12.63", size: 34, contentType: "application/json"))
        #expect(LinkRequestReader.header(of: line(visitor: ""), link: record)?.publicLink?.visitor == nil)
        #expect(LinkRequestReader.header(of: ShareLogLine(time: 1, request: "r", status: 200, visitor: ""), link: record) == nil)
    }

    @Test func aLongURIEndsWithTheMarker() throws {
        let header = try #require(LinkRequestReader.header(of: line(uri: "/" + String(repeating: "é", count: 2_500)), link: record))

        #expect(header.target.hasSuffix(" [...]"))
        #expect(header.target.utf8.count <= 4096 + 6)
        #expect(header.url?.hasSuffix(" [...]") == true)
    }

    @Test func theDetailHasTheHeadersAndAJSONBody() {
        let body = Data(#"{"id":"evt_1Q"}"#.utf8)

        let detail = LinkRequestReader.detail(of: line(method: "POST", body: body))

        #expect(detail.requestHeaders == [ShareHeader(name: "Host", value: "calm-river.trycloudflare.com"), ShareHeader(name: "Cookie", value: "Hidden by Nexus")])
        #expect(detail.responseHeaders == [ShareHeader(name: "Content-Type", value: "application/json")])
        #expect(detail.requestBody == #"{"id":"evt_1Q"}"#)
        #expect(detail.requestBodyBytes == body.count)
        #expect(!detail.requestBodyCut)
        #expect(detail.status == 200)
        #expect(detail.size == 34)
    }

    @Test func aCutBodyThatEndsInTheMiddleOfACharacterKeepsItsText() {
        var body = Data(String(repeating: "a", count: LinkRequestText.keptBodyLimit - 1).utf8)
        body.append(Data("é".utf8).prefix(1))

        let detail = LinkRequestReader.detail(of: line(method: "POST", body: body, bodyBytes: 200_000))

        #expect(detail.requestBody == String(repeating: "a", count: LinkRequestText.keptBodyLimit - 1))
        #expect(detail.requestBodyCut)
        #expect(detail.requestBodyBytes == 200_000)
    }

    @Test func aBodyThatIsNotTextOrThatNginxDidNotKeepHasOnlyItsSize() {
        let image = LinkRequestReader.detail(of: line(method: "POST", body: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0x00, 0xC3])))
        let large = LinkRequestReader.detail(of: line(method: "POST", bodyBytes: 3_200_000))

        #expect(image.requestBody == nil)
        #expect(image.requestBodyBytes == 8)
        #expect(large.requestBody == nil)
        #expect(large.requestBodyBytes == 3_200_000)
        #expect(large.requestBodyCut)
    }
}
