import Foundation
import NexusCore
import NexusIPC

// One request of a public link with its detail, as one JSON line of nexus dumps --public-link
// --json (group 4, 4f). detail is null when Nexus has no detail anymore. The numbers of the store
// are values for the app. So the line leaves them out.
public struct LinkRequestLine: Encodable, Sendable {
    public let request: DumpedRequest
    public let detail: ShareRequestDetail?

    public init(request: DumpedRequest, detail: ShareRequestDetail?) {
        var plainRequest = request
        plainRequest.lastNumber = 0
        plainRequest.firstNumber = 0

        self.request = plainRequest
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case request
        case detail
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encode(detail, forKey: .detail)
    }
}

// The text of the requests of a public link for nexus dumps --public-link and read_link_requests
// (group 4, 4f). The texts of a body come from LinkRequestText.
public enum LinkRequestLines {
    // The newest limit requests of the links, the oldest first. requests has the newest first, as
    // DumpList has them. host keeps only the requests of the link of that local host.
    public static func newest(_ requests: [DumpedRequest], host: String?, limit: Int) -> [DumpedRequest] {
        let linked = requests.filter { request in
            guard let link = request.publicLink else {
                return false
            }

            return host == nil || link.host == host
        }

        return Array(linked.prefix(limit).reversed())
    }

    // The line of the request with the visitor, the line of the id and the counts, then the request
    // and the answer. Without a detail the text says why.
    public static func lines(of request: DumpedRequest, detail: ShareRequestDetail?, now: Date, times: DumpTimeText, locale: Locale = .current) -> [String] {
        var head = DumpText.header(of: request, now: now, times: times)

        if let visitor = request.publicLink?.visitor {
            head += "  visitor \(visitor)"
        }

        var lines = [head] + DumpText.details(of: request, id: true, locale: locale)

        guard let detail else {
            return lines + ["  [\(LinkRequestText.detailGone)]"]
        }

        lines.append("  Request headers")
        lines += detail.requestHeaders.map { header in "    \(header.name): \(header.value)" }
        lines.append("  Body")

        if let body = detail.requestBody, !body.isEmpty {
            lines += LinkRequestText.shownBody(body).split(separator: "\n", omittingEmptySubsequences: false).map { line in "    \(line)" }
        }

        if let note = LinkRequestText.bodyNote(body: detail.requestBody, bytes: detail.requestBodyBytes, cut: detail.requestBodyCut, locale: locale) {
            lines.append("    [\(note)]")
        }

        let answer = [detail.status.map(String.init), detail.size.map { size in LinkRequestText.size(size, locale: locale) }, request.publicLink?.contentType].compactMap { $0 }
        lines.append(answer.isEmpty ? "  Answer" : "  Answer  \(answer.joined(separator: " · "))")
        lines.append("  Answer headers")
        lines += detail.responseHeaders.map { header in "    \(header.name): \(header.value)" }
        return lines
    }

    // One JSON line: {"request": <the header>, "detail": <the detail or null>}.
    public static func json(request: DumpedRequest, detail: ShareRequestDetail?) throws -> String {
        String(decoding: try JSONEncoder.mcp.encode(LinkRequestLine(request: request, detail: detail)), as: UTF8.self)
    }
}
