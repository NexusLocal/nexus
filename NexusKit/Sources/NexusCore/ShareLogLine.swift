import Foundation

// One line of the visitor log of a link (4b). nginx writes it with the format nexus_share. time is
// the end of the request in seconds since 1970. request is the id of nginx, also in the header
// X-Nexus-Share-Request. visitor is the value of CF-Connecting-IP, empty without it. 4f adds the
// fields of the request log.
public struct ShareLogLine: Codable, Sendable, Equatable {
    public let time: Double
    public let request: String
    public let status: Int
    public let visitor: String
    // 4f: the fields of the request log. requestHeaders and responseHeaders hold pairs of a name and a
    // value. njs writes "Hidden by Nexus" for the values of the hidden headers. So these values
    // never reach the disk. body is base64 of the first 64 KB of the body. bodyBytes is the size of
    // the whole body, nil when nginx does not know it.
    public let method: String?
    public let uri: String?
    public let host: String?
    public let duration: Double?
    public let size: Int?
    public let contentType: String?
    public let requestHeaders: [[String]]?
    public let responseHeaders: [[String]]?
    public let body: String?
    public let bodyBytes: Int?

    public init(
        time: Double,
        request: String,
        status: Int,
        visitor: String,
        method: String? = nil,
        uri: String? = nil,
        host: String? = nil,
        duration: Double? = nil,
        size: Int? = nil,
        contentType: String? = nil,
        requestHeaders: [[String]]? = nil,
        responseHeaders: [[String]]? = nil,
        body: String? = nil,
        bodyBytes: Int? = nil
    ) {
        self.time = time
        self.request = request
        self.status = status
        self.visitor = visitor
        self.method = method
        self.uri = uri
        self.host = host
        self.duration = duration
        self.size = size
        self.contentType = contentType
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.body = body
        self.bodyBytes = bodyBytes
    }
}
