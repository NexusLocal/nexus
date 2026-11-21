import Foundation
import NexusCore

// One share block: the nginx server block of one link on its own port of 127.0.0.1 (group 4). 4b
// fills all fields. The lines of the other parts read them. The fields of 4c, 4d, 4e and 4f are nil
// or [] until their part fills them.
public struct ShareBlock: Sendable, Equatable {
    public let id: String
    public let host: String
    public let port: Int
    public let mode: ShareHostMode
    public let options: ShareOptions
    public let redirectHost: String?
    public let extraHosts: [String]
    public let reverb: ShareReverb?
    public let vite: ShareViteTarget?
    public let passwordFile: URL?
    public let visitorLog: URL
    public let requestLog: URL?
    // 4c: the njs module of the link.
    public let rewriteScript: URL?
    // 4d: the custom paths of the debug tools from the .env.
    public let debugPaths: [String]
    // 4d: the document root holds vendor/autoload.php. Only then the /vendor/ rule applies to the
    // paths of the site (owner, 2026-11-20).
    public let composerInDocumentRoot: Bool

    public init(
        id: String,
        host: String,
        port: Int,
        mode: ShareHostMode,
        options: ShareOptions,
        redirectHost: String? = nil,
        extraHosts: [String] = [],
        reverb: ShareReverb? = nil,
        vite: ShareViteTarget? = nil,
        passwordFile: URL? = nil,
        visitorLog: URL,
        requestLog: URL? = nil,
        rewriteScript: URL? = nil,
        debugPaths: [String] = [],
        composerInDocumentRoot: Bool = false
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.mode = mode
        self.options = options
        self.redirectHost = redirectHost
        self.extraHosts = extraHosts
        self.reverb = reverb
        self.vite = vite
        self.passwordFile = passwordFile
        self.visitorLog = visitorLog
        self.requestLog = requestLog
        self.rewriteScript = rewriteScript
        self.debugPaths = debugPaths
        self.composerInDocumentRoot = composerInDocumentRoot
    }

    // 4c: the host that the share block sends to the site (F1).
    public var upstreamHost: String {
        redirectHost ?? host
    }
}

// The Reverb server of the owner of a link (4c, F4): its port and the key and the app id of the
// .env.
public struct ShareReverb: Sendable, Equatable {
    public let port: Int
    public let key: String
    public let appID: String

    public init(port: Int, key: String, appID: String) {
        self.port = port
        self.key = key
        self.appID = appID
    }
}

// The values that the site block needs for one host with an open link. shareSocket is the pool
// nexus-share of PHP-FPM for a link with hidden error details (4d).
public struct SiteShare: Sendable, Equatable {
    public let id: String
    public let fastcgiValues: [String: String]
    public let shareSocket: URL?

    public init(id: String, fastcgiValues: [String: String] = [:], shareSocket: URL? = nil) {
        self.id = id
        self.fastcgiValues = fastcgiValues
        self.shareSocket = shareSocket
    }
}

// What Live needs for one share block (group 4, 4e). nil in ShareBlock means no Vite lines.
public struct ShareViteTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        // A Laravel site in Live. hotText is the text of public/hot without white space at its ends,
        // for example http://[::1]:20002. secure is true for an https address.
        case laravel(hotText: String, secure: Bool, documentRoot: URL)
        // A Node.js app on a Vite dev server. Each request goes to the app through the site block.
        case app
    }

    public let kind: Kind
    // The port of the dev server: the port of public/hot or the port of the app.
    public let port: Int
    // The Laravel root or the folder of the app.
    public let projectFolder: URL

    public init(kind: Kind, port: Int, projectFolder: URL) {
        self.kind = kind
        self.port = port
        self.projectFolder = projectFolder
    }
}

// The lines of the links in the configuration of nginx (group 4, 4b). A function of a part gives
// its lines without the indent of their place. ShareConfig and NginxConfig add that indent.
public enum ShareConfig {
    // The headers that nginx sets for a request of a link (4b, 4c, 4d and 4f). proxy_set_header
    // replaces a header of a visitor with the same name. So a visitor cannot send them.
    public enum Header: String, Sendable {
        case id = "X-Nexus-Share"
        case host = "X-Nexus-Share-Host"
        case request = "X-Nexus-Share-Request"
        case visitor = "X-Nexus-Share-Visitor"
        case hide = "X-Nexus-Share-Hide"

        // The variable of nginx with the value of the header, for example $http_x_nexus_share_host.
        public var variable: String {
            "$http_\(rawValue.lowercased().replacingOccurrences(of: "-", with: "_"))"
        }

        // The name that PHP reads in $_SERVER, for example HTTP_X_NEXUS_SHARE_REQUEST.
        public var fastcgiName: String {
            "HTTP_\(rawValue.uppercased().replacingOccurrences(of: "-", with: "_"))"
        }
    }

    // nginx keeps a body up to LinkRequestText.bufferedBodyLimit in one buffer in memory. So njs can
    // read it (4c and 4f).
    static let bodyBufferLines = [
        "client_body_buffer_size \(LinkRequestText.bufferedBodyLimit / 1_048_576)m;",
        "client_body_in_single_buffer on;",
    ]

    // The lines of the http block: the format of the visitor log and the maps of the site blocks.
    // nginx reads these only in the http block. So 4c, 4d, 4e and 4f add their lines here. Each site
    // block names $nexus_site_log. So the maps are there also without a link. requestScript is the
    // njs module of the request list. 4f adds its lines with it. The maps of 4c need the ports of
    // Nexus in settings.
    public static func httpLines(for shares: [ShareBlock], settings: NginxSettings, requestScript: URL? = nil) throws -> [String] {
        var lines = [
            #"log_format nexus_share escape=json '{"time":$msec,"request":"$request_id","status":$status,"visitor":"$http_cf_connecting_ip"}';"#,
            "",
            "map \(Header.id.variable) $nexus_share {",
            "    default \"\";",
        ]

        lines += shares.map { "    \"\($0.id)\" \"\($0.id)\";" }
        lines += [
            "}",
            "",
            "map $nexus_share $nexus_site_log {",
            "    default 0;",
            "    \"\" 1;",
            "}",
        ]

        lines += ShareRewrite.httpLines(for: shares, settings: settings)
        lines += ShareProtection.httpLines(for: shares)
        lines += try ShareViteRoutes.httpLines(for: shares)
        lines += try ShareRequests.httpLines(for: shares, script: requestScript)
        return lines
    }

    // One share block in the order of the overview. It listens only on 127.0.0.1, as the default
    // server of its port. So no other host reaches another site or the page that lists all sites.
    // proxyLines sets the headers of ShareConfig.Header. cloudflared sends the public host as Host.
    // So $host is the public host here.
    public static func render(_ share: ShareBlock, settings: NginxSettings) throws -> [String] {
        var lines = [
            "server {",
            "    listen 127.0.0.1:\(share.port) default_server;",
            "    server_name _;",
        ]

        lines += try ShareProtection.refusals(for: share).map { $0.isEmpty ? "" : "    \($0)" }
        lines += try ShareViteRoutes.lines(for: share).map { "    \($0)" }
        lines += ShareRewrite.locations(for: share, settings: settings).map { $0.isEmpty ? "" : "    \($0)" }
        lines += [
            "",
            "    location / {",
        ]

        lines += ShareRewrite.siteLocation(for: share, settings: settings, readsBody: false).map { $0.isEmpty ? "" : "        \($0)" }
        lines += ["    }", ""]
        lines += ShareRequests.lines(for: share).map { "    \($0)" }
        lines += ["    access_log \(try ConfigText.quoted(share.visitorLog)) nexus_share;"]
        lines += try ShareRequests.logLines(for: share).map { "    \($0)" }
        lines += ["}"]
        return lines
    }

    // The lines that send a request of a link to the site block of host (4b). marksLink is false for
    // a second local host (4c). Its site block then sees a normal request. Host has the port as a
    // browser sends it, because WordPress compares the port.
    public static func proxyLines(_ share: ShareBlock, host: String, marksLink: Bool, settings: NginxSettings) -> [String] {
        [
            "proxy_pass https://127.0.0.1:\(settings.httpsPort);",
            "proxy_http_version 1.1;",
            "proxy_ssl_server_name on;",
            "proxy_ssl_name \(host);",
            "proxy_set_header Host \(settings.authority(of: host));",
            "proxy_set_header \(Header.id.rawValue) \(marksLink ? share.id : "\"\"");",
            "proxy_set_header \(Header.host.rawValue) \(marksLink ? "$host" : "\"\"");",
            "proxy_set_header \(Header.request.rawValue) $request_id;",
            "proxy_set_header \(Header.visitor.rawValue) $http_cf_connecting_ip;",
            "proxy_set_header Upgrade $http_upgrade;",
            "proxy_set_header Connection $connection_upgrade;",
            "proxy_read_timeout 300;",
        ]
    }
}
