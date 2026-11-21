import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct ShareRequestsTests {
    private let settings = NginxSettings(httpPort: 8080, httpsPort: 8443, apachePort: 8081, lanAccess: false, runtime: URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory), runFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory), modules: [])
    private let script = URL(filePath: "/Users/me/Library/Application Support/Nexus/data/share/requests.js")
    private let id = "0123456789abcdef0123456789abcdef"

    private func share(keepsRequests: Bool) -> ShareBlock {
        var options = ShareOptions.standard
        options.keepsRequests = keepsRequests

        return ShareBlock(
            id: id,
            host: "shop.test",
            port: 18_000,
            mode: .localHost,
            options: options,
            visitorLog: URL(filePath: "/Nexus/logs/share-\(id).jsonl"),
            requestLog: keepsRequests ? URL(filePath: "/Nexus/logs/share-\(id)-requests.jsonl") : nil
        )
    }

    private func site(_ host: String, backend: WebBackend? = nil, linked: Bool) -> WebSite {
        WebSite(
            hosts: [host],
            backend: backend ?? .php(server: .nginx, documentRoot: URL(filePath: "/Sites/\(host)/public", directoryHint: .isDirectory), socket: URL(filePath: "/Nexus/run/php-8.5.sock")),
            certificate: URL(filePath: "/Nexus/certs/\(host).crt"),
            key: URL(filePath: "/Nexus/certs/\(host).key"),
            accessLog: URL(filePath: "/Nexus/logs/sites/\(host).log"),
            share: linked ? SiteShare(id: id) : nil
        )
    }

    private let trustedMap = [
        "",
        "map $nexus_share $nexus_share_request {",
        "    default $http_x_nexus_share_request;",
        "    \"\" \"\";",
        "}",
    ]

    @Test func withoutAListOfRequestsTheHTTPBlockHasOnlyTheMapOfTheTrustedID() throws {
        #expect(try ShareRequests.httpLines(for: [], script: nil) == trustedMap)
        #expect(try ShareRequests.httpLines(for: [share(keepsRequests: false)], script: script) == trustedMap)
    }

    @Test func aBlockWithAListOfRequestsAddsTheScriptTheVariableAndTheFormat() throws {
        let lines = try ShareRequests.httpLines(for: [share(keepsRequests: false), share(keepsRequests: true)], script: script)

        #expect(lines == trustedMap + [
            "",
            "js_import nexus_requests from \"/Users/me/Library/Application Support/Nexus/data/share/requests.js\";",
            "js_set $nexus_share_request_line nexus_requests.line;",
            "log_format nexus_share_requests escape=none '$nexus_share_request_line';",
            "",
        ] + ShareRequests.loggedMap)
        #expect(ShareRequests.loggedMap[2].hasPrefix(#"    "~*^(?:GET|HEAD):[123][0-9][0-9]:[^?#]*/[^/?#]+\.(?:css|js|mjs|map|"#))
        #expect(throws: ShareRequestsError.noScript) {
            try ShareRequests.httpLines(for: [share(keepsRequests: true)], script: nil)
        }
    }

    @Test func aBlockWithAListOfRequestsKeepsTheBodyInOneBuffer() throws {
        #expect(ShareRequests.lines(for: share(keepsRequests: true)) == ["client_body_buffer_size 1m;", "client_body_in_single_buffer on;"])
        #expect(ShareRequests.lines(for: share(keepsRequests: false)).isEmpty)

        let block = try ShareConfig.render(share(keepsRequests: true), settings: settings)

        #expect(block.contains("    client_body_buffer_size 1m;"))
        #expect(block.contains("    access_log \"/Nexus/logs/share-\(id)-requests.jsonl\" nexus_share_requests if=$nexus_share_request_logged;"))
    }

    @Test func theScriptHidesEachSecretHeaderAndExportsTheLine() {
        for name in ["cookie", "authorization", "set-cookie", "proxy-authorization"] {
            #expect(ShareRequests.script.contains("'\(name)'"))
        }

        #expect(ShareRequests.script.contains("export default { line };"))
        #expect(ShareRequests.script.hasPrefix("// Nexus writes this file (group 4, 4f)."))
    }

    @Test func eachSiteWithOrWithoutALinkPassesOnlyTheTrustedIDOfTheRequest() throws {
        let config = try NginxConfig.render(sites: [
            site("shop.test", linked: true),
            site("blog.test", backend: .php(server: .apache, documentRoot: URL(filePath: "/Sites/blog", directoryHint: .isDirectory), socket: URL(filePath: "/Nexus/run/php-8.5.sock")), linked: true),
            site("crm.test", linked: false),
            site("app.test", backend: .app(port: 3000, framework: nil), linked: true),
            site("api.test", backend: .proxy(address: "http://127.0.0.1:9000"), linked: false),
        ], shares: [share(keepsRequests: true)], requestScript: script, settings: settings)
        let afterApache = config[try #require(config.range(of: "server_name blog.test")).upperBound...]
        let apacheBlock = afterApache.range(of: "server_name").map { afterApache[..<$0.lowerBound] } ?? afterApache

        #expect(config.components(separatedBy: "fastcgi_param HTTP_X_NEXUS_SHARE_REQUEST $nexus_share_request;").count == 3)
        #expect(config.contains("        fastcgi_param HTTP_PROXY \"\";\n" + "    " + ShareRequests.fastcgiLine + "\n"))
        #expect(config.components(separatedBy: "proxy_set_header X-Nexus-Share-Request $nexus_share_request;").count == 4)
        #expect(apacheBlock.contains("proxy_pass https://127.0.0.1:"))
        #expect(apacheBlock.contains(ShareRequests.proxyLine.trimmingCharacters(in: .whitespaces)))
        #expect(config.contains("    js_import nexus_requests from \"/Users/me/Library/Application Support/Nexus/data/share/requests.js\";"))
        #expect(config.contains("    log_format nexus_share_requests escape=none '$nexus_share_request_line';"))
    }

    @Test func theConfigWithoutAnyLinkStillHasTheMapOfTheTrustedID() throws {
        let config = try NginxConfig.render(sites: [site("crm.test", linked: false)], shares: [], requestScript: nil, settings: settings)

        #expect(config.contains(trustedMap.dropFirst().map { "    \($0)" }.joined(separator: "\n")))
    }
}
