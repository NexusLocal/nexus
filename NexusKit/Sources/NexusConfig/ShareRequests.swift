import Foundation
import NexusCore

// The lines of the list of the requests in nginx (group 4, 4f). The share block writes one JSON line
// for each request of a link with the option on. njs makes the line. So each header and the body
// fit into JSON without a loss. The site block passes the id of a request of a link to PHP. So the
// dumps of that PHP request join the request of the link.
public enum ShareRequests {
    public static let format = "nexus_share_requests"

    // A GET or a HEAD of a file with one of these extensions that did not fail stays out of the list
    // (4f question 1). nginx writes no line for it. nexusd also leaves out such a request by its
    // type (LinkRequestReader.isStaticFile).
    public static let staticExtensions = ["css", "js", "mjs", "map", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "webm", "wasm"]

    // The path before ? and # ends with a name that has one of the extensions, as in
    // LinkRequestReader.isStaticFile.
    static let loggedMap = [
        "map \"$request_method:$status:$request_uri\" $nexus_share_request_logged {",
        "    default 1;",
        "    \"~*^(?:GET|HEAD):[123][0-9][0-9]:[^?#]*/[^/?#]+\\.(?:\(staticExtensions.joined(separator: "|")))(?:[?#].*)?$\" 0;",
        "}",
    ]

    // The line of each site block, also of a site without a link. A fastcgi_param with the name of a
    // header replaces that header, and an empty proxy_set_header removes it. The map of httpLines
    // gives an empty value to each request that is not a request of an open link. So a forged header
    // reaches PHP, an app or a proxy only together with the id of an open link. Only nginx and
    // nexusd know that id.
    public static let fastcgiLine = "        fastcgi_param \(ShareConfig.Header.request.fastcgiName) $nexus_share_request;"
    public static let proxyLine = "        proxy_set_header \(ShareConfig.Header.request.rawValue) $nexus_share_request;"

    // The text of the njs file at NexusPaths.shareRequestScript. nginx calls line() at the log phase.
    // A hidden header keeps its name. Its value never reaches the disk. The owner chose to hide
    // Set-Cookie and Proxy-Authorization too (owner, 2026-11-20). The njs engine of nginx has no
    // for...of. So the script uses loops with an index and arrays for the names.
    public static let script = #"""
    // Nexus writes this file (group 4, 4f). nginx calls line() at the end of each request of a public
    // link with the list of the requests on. A hidden header keeps its name. Its value never reaches the
    // disk.
    var hidden = ['cookie', 'authorization', 'set-cookie', 'proxy-authorization'];
    var bodyLimit = \#(LinkRequestText.keptBodyLimit);

    function pairs(headers) {
        return headers.map(function (pair) {
            return [pair[0], hidden.indexOf(pair[0].toLowerCase()) === -1 ? pair[1] : '\#(LinkRequestText.hiddenValue)'];
        });
    }

    // nginx keeps Content-Type and Content-Length of the answer outside the list of its headers.
    function answerHeaders(r) {
        var headers = pairs(r.rawHeadersOut);
        var names = headers.map(function (pair) {
            return pair[0].toLowerCase();
        });
        var kept = ['Content-Length', 'Content-Type'];

        for (var index = 0; index < kept.length; index++) {
            var value = r.headersOut[kept[index]];

            if (value !== undefined && names.indexOf(kept[index].toLowerCase()) === -1) {
                headers.unshift([kept[index], String(value)]);
            }
        }

        return headers;
    }

    function line(r) {
        var body = r.rawVariables.request_body;
        var kept = body !== undefined && body.length > 0;
        var length = Number(r.headersIn['Content-Length'] || 0);

        return JSON.stringify({
            time: Number(r.variables.msec),
            request: r.variables.request_id,
            status: Number(r.variables.status),
            visitor: r.headersIn['CF-Connecting-IP'] || '',
            method: r.method,
            uri: r.variables.request_uri,
            host: r.variables.host,
            duration: Number(r.variables.request_time),
            size: Number(r.variables.body_bytes_sent),
            contentType: r.headersOut['Content-Type'] || null,
            requestHeaders: pairs(r.rawHeadersIn),
            responseHeaders: answerHeaders(r),
            body: kept ? body.subarray(0, bodyLimit).toString('base64') : null,
            bodyBytes: kept ? body.length : (length > 0 ? length : null),
        });
    }

    export default { line };

    """#

    // The map of the trusted id, also for an empty list. Only a request of an open link keeps the id
    // of the share block. With a block that has requestLog also the import of the script, the
    // variable of the line and the format. A block with requestLog needs the script.
    public static func httpLines(for shares: [ShareBlock], script: URL?) throws -> [String] {
        var lines = [
            "",
            "map $nexus_share $nexus_share_request {",
            "    default \(ShareConfig.Header.request.variable);",
            "    \"\" \"\";",
            "}",
        ]

        guard shares.contains(where: { $0.requestLog != nil }) else {
            return lines
        }

        guard let script else {
            throw ShareRequestsError.noScript
        }

        lines += [
            "",
            "js_import nexus_requests from \(try ConfigText.quoted(script));",
            "js_set $nexus_share_request_line nexus_requests.line;",
            "log_format \(format) escape=none '$nexus_share_request_line';",
            "",
        ]

        return lines + loggedMap
    }

    // The lines of one share block with requestLog: the buffer of the body. Only a body in memory
    // is in $request_body for njs.
    public static func lines(for share: ShareBlock) -> [String] {
        share.requestLog == nil ? [] : ShareConfig.bodyBufferLines
    }

    // The log line of one share block with requestLog.
    public static func logLines(for share: ShareBlock) throws -> [String] {
        guard let log = share.requestLog else {
            return []
        }

        return ["access_log \(try ConfigText.quoted(log)) \(format) if=$nexus_share_request_logged;"]
    }
}

public enum ShareRequestsError: Error, Equatable, CustomStringConvertible {
    case noScript

    public var description: String {
        "Nexus cannot write the list of the requests of a public link, because the configuration of nginx has no script for it."
    }
}
