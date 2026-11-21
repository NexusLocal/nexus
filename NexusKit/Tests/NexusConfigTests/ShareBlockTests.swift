import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct ShareBlockTests {
    private let settings = NginxSettings(httpPort: 8080, httpsPort: 8443, apachePort: 8081, lanAccess: false, runtime: URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory), runFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory), modules: [])

    private func share(_ id: String = "0123456789abcdef0123456789abcdef", host: String = "shop.test", port: Int = 18_000, keepsRequests: Bool = false, logs: String = "/Nexus/logs") -> ShareBlock {
        var options = ShareOptions.standard
        options.keepsRequests = keepsRequests

        return ShareBlock(
            id: id,
            host: host,
            port: port,
            mode: .localHost,
            options: options,
            visitorLog: URL(filePath: "\(logs)/share-\(id).jsonl"),
            requestLog: keepsRequests ? URL(filePath: "\(logs)/share-\(id)-requests.jsonl") : nil
        )
    }

    private func site(_ host: String) -> WebSite {
        WebSite(
            hosts: [host],
            backend: .php(server: .nginx, documentRoot: URL(filePath: "/Sites/\(host)/public", directoryHint: .isDirectory), socket: URL(filePath: "/Nexus/run/php-8.5.sock")),
            certificate: URL(filePath: "/Nexus/certs/\(host).crt"),
            key: URL(filePath: "/Nexus/certs/\(host).key"),
            accessLog: URL(filePath: "/Nexus/logs/sites/\(host).log")
        )
    }

    @Test func theBlockListensOnlyOnTheLoopbackAddressAsTheDefaultServer() throws {
        let lines = try ShareConfig.render(share(), settings: settings)

        #expect(lines.filter { $0.contains("listen ") } == ["    listen 127.0.0.1:18000 default_server;"])
        #expect(lines.contains("    server_name _;"))
    }

    @Test func theBlockSendsEachRequestToTheSiteOverTLSWithItsHost() throws {
        let lines = try ShareConfig.render(share(), settings: settings)

        #expect(lines.contains("        proxy_pass https://127.0.0.1:8443;"))
        #expect(lines.contains("        proxy_ssl_server_name on;"))
        #expect(lines.contains("        proxy_ssl_name shop.test;"))
        #expect(lines.contains("        proxy_set_header Host shop.test:8443;"))
    }

    @Test func theBlockSetsTheFourHeadersOfTheLink() throws {
        let lines = try ShareConfig.render(share(), settings: settings)

        #expect(lines.contains("        proxy_set_header X-Nexus-Share 0123456789abcdef0123456789abcdef;"))
        #expect(lines.contains("        proxy_set_header X-Nexus-Share-Host $host;"))
        #expect(lines.contains("        proxy_set_header X-Nexus-Share-Request $request_id;"))
        #expect(lines.contains("        proxy_set_header X-Nexus-Share-Visitor $http_cf_connecting_ip;"))
    }

    @Test func theBlockWritesTheVisitorLogWithItsFormat() throws {
        let lines = try ShareConfig.render(share(), settings: settings)
        let withRequests = try ShareConfig.render(share(keepsRequests: true), settings: settings)

        #expect(lines.contains("    access_log \"/Nexus/logs/share-0123456789abcdef0123456789abcdef.jsonl\" nexus_share;"))
        #expect(lines.filter { $0.contains("access_log") }.count == 1)
        #expect(withRequests.filter { $0.contains("access_log") }.count == 2)
        #expect(withRequests.contains("    access_log \"/Nexus/logs/share-0123456789abcdef0123456789abcdef-requests.jsonl\" nexus_share_requests if=$nexus_share_request_logged;"))
    }

    @Test func aVisitorLogInAFolderWithASpaceIsQuoted() throws {
        let lines = try ShareConfig.render(share(logs: "/Users/me/Library/Application Support/Nexus/logs"), settings: settings)

        #expect(lines.contains("    access_log \"/Users/me/Library/Application Support/Nexus/logs/share-0123456789abcdef0123456789abcdef.jsonl\" nexus_share;"))
    }

    @Test func theHTTPBlockHasTheFormatAndTheMapsOfTwoLinksAndTheShareBlocksComeAfterTheSites() throws {
        let first = share()
        let second = share("fedcba9876543210fedcba9876543210", host: "blog.test", port: 18_002)
        let config = try NginxConfig.render(sites: [site("shop.test"), site("blog.test")], shares: [first, second], settings: settings)
        let lastSite = try #require(config.range(of: "server_name blog.test;"))
        let firstShare = try #require(config.range(of: "listen 127.0.0.1:18000 default_server;"))

        #expect(config.contains(#"    log_format nexus_share escape=json '{"time":$msec,"request":"$request_id","status":$status,"visitor":"$http_cf_connecting_ip"}';"#))
        #expect(config.contains("    map $http_x_nexus_share $nexus_share {\n        default \"\";\n        \"0123456789abcdef0123456789abcdef\" \"0123456789abcdef0123456789abcdef\";\n        \"fedcba9876543210fedcba9876543210\" \"fedcba9876543210fedcba9876543210\";\n    }"))
        #expect(config.contains("    map $nexus_share $nexus_site_log {\n        default 0;\n        \"\" 1;\n    }"))
        #expect(lastSite.upperBound < firstShare.lowerBound)
        #expect(config.contains("        listen 127.0.0.1:18002 default_server;"))
        #expect(config.contains("            proxy_ssl_name blog.test;"))
    }

    @Test func withoutALinkTheMapsHaveOnlyTheirDefault() throws {
        let config = try NginxConfig.render(sites: [site("shop.test")], settings: settings)

        #expect(config.contains("    map $http_x_nexus_share $nexus_share {\n        default \"\";\n    }"))
        #expect(config.contains("    map $nexus_share $nexus_site_log {\n        default 0;\n        \"\" 1;\n    }"))
        #expect(!config.contains("default_server;\n        server_name _;"))
    }

    @Test func eachSiteBlockWritesItsAccessLogOnlyForARequestWithoutALink() throws {
        let config = try NginxConfig.render(sites: [site("shop.test"), site("blog.test")], settings: settings)

        #expect(config.contains("        access_log \"/Nexus/logs/sites/shop.test.log\" combined if=$nexus_site_log;"))
        #expect(config.contains("        access_log \"/Nexus/logs/sites/blog.test.log\" combined if=$nexus_site_log;"))
    }
}
