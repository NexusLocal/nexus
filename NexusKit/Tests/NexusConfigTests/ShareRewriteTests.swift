import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct ShareRewriteTests {
    private static let id = "0123456789abcdef0123456789abcdef"

    private func settings(https: Int = 30443, http: Int = 30080) -> NginxSettings {
        NginxSettings(httpPort: http, httpsPort: https, apachePort: 30081, lanAccess: false, runtime: URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory), runFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory), modules: [])
    }

    private func share(
        _ id: String = Self.id,
        host: String = "wptest.internal",
        mode: ShareHostMode = .localHost,
        redirectHost: String? = nil,
        extraHosts: [String] = [],
        reverb: Bool = false,
        script: String? = "/Users/me/Library/Application Support/Nexus Dev/data/share"
    ) -> ShareBlock {
        ShareBlock(
            id: id,
            host: host,
            port: 40_000,
            mode: mode,
            options: .standard,
            redirectHost: redirectHost,
            extraHosts: extraHosts,
            reverb: reverb ? ShareReverb(port: 8080, key: "app-key", appID: "123456") : nil,
            visitorLog: URL(filePath: "/Nexus/logs/share-\(id).jsonl"),
            rewriteScript: script.map { URL(filePath: "\($0)/\(id).js") }
        )
    }

    private func index(of line: String, in lines: [String]) throws -> Int {
        try #require(lines.firstIndex(of: line))
    }

    private func block(_ head: String, in lines: [String]) throws -> [String] {
        let start = try index(of: "\(head) {", in: lines)
        let end = try #require(lines[start...].firstIndex(of: "}"))
        return Array(lines[start...end])
    }

    @Test func eachLocalOriginComesInItsFormsWithThePortBeforeTheFormWithoutIt() {
        let forms = ShareRewrite.answerForms(of: "shop.test", prefix: "", settings: settings())

        #expect(forms.map(\.from) == [
            "https://shop.test:30443", #"https:\/\/shop.test:30443"#, "https%3A%2F%2Fshop.test%3A30443",
            "https://shop.test", #"https:\/\/shop.test"#, "https%3A%2F%2Fshop.test",
            "http://shop.test:30080", #"http:\/\/shop.test:30080"#, "http%3A%2F%2Fshop.test%3A30080",
            "http://shop.test", #"http:\/\/shop.test"#, "http%3A%2F%2Fshop.test",
            "//shop.test:30443", #"\/\/shop.test:30443"#,
            "//shop.test", #"\/\/shop.test"#,
        ])
        #expect(forms.map(\.to) == [
            "https://$host", #"https:\/\/$host"#, "https%3A%2F%2F$host",
            "https://$host", #"https:\/\/$host"#, "https%3A%2F%2F$host",
            "https://$host", #"https:\/\/$host"#, "https%3A%2F%2F$host",
            "https://$host", #"https:\/\/$host"#, "https%3A%2F%2F$host",
            "//$host", #"\/\/$host"#,
            "//$host", #"\/\/$host"#,
        ])
    }

    @Test func thePortsOf443And80GiveNoFormWithAPort() {
        let forms = ShareRewrite.answerForms(of: "shop.test", prefix: "", settings: settings(https: 443, http: 80))

        #expect(forms.count == 8)
        #expect(!forms.contains { $0.from.contains(":443") || $0.from.contains(":80") || $0.from.contains("%3A443") })
    }

    @Test func theFormsOfASecondLocalHostEndWithItsPath() {
        let forms = ShareRewrite.answerForms(of: "cms.shop.test", prefix: "/_nexus/host/cms.shop.test", settings: settings())

        #expect(forms[0].to == "https://$host/_nexus/host/cms.shop.test")
        #expect(forms[1].to == #"https:\/\/$host\/_nexus\/host\/cms.shop.test"#)
        #expect(forms[2].to == "https%3A%2F%2F$host%2F_nexus%2Fhost%2Fcms.shop.test")
        #expect(forms[12].to == "//$host/_nexus/host/cms.shop.test")
    }

    @Test func theRequestFormsGiveTheLocalURLInTheSameForm() {
        let withPort = ShareRewrite.requestForms(prefix: "", localOrigin: "https://shop.test:30443")
        let withoutPort = ShareRewrite.requestForms(prefix: "/_nexus/host/cms.shop.test", localOrigin: "https://cms.shop.test")

        #expect(withPort.map(\.from) == ["https://{public}", #"https:\/\/{public}"#, #"https:\\/\\/{public}"#, "https%3A%2F%2F{public}", "https%3A%5C%2F%5C%2F{public}"])
        #expect(withPort.map(\.to) == ["https://shop.test:30443", #"https:\/\/shop.test:30443"#, #"https:\\/\\/shop.test:30443"#, "https%3A%2F%2Fshop.test%3A30443", "https%3A%5C%2F%5C%2Fshop.test%3A30443"])
        #expect(withoutPort.map(\.from)[0] == "https://{public}/_nexus/host/cms.shop.test")
        #expect(withoutPort.map(\.from)[2] == #"https:\\/\\/{public}\\/_nexus\\/host\\/cms.shop.test"#)
        #expect(withoutPort.map(\.to) == ["https://cms.shop.test", #"https:\/\/cms.shop.test"#, #"https:\\/\\/cms.shop.test"#, "https%3A%2F%2Fcms.shop.test", "https%3A%5C%2F%5C%2Fcms.shop.test"])
    }

    @Test func theCookieDomainsAreEachHostAndEachParentWithTwoLabels() {
        let domains = ShareRewrite.cookieDomains(of: ["blog.shop.test", "www.shop.test", "my.shop-ticket-123.test"])

        #expect(domains == [
            "blog.shop.test", ".blog.shop.test", "shop.test", ".shop.test",
            "www.shop.test", ".www.shop.test",
            "my.shop-ticket-123.test", ".my.shop-ticket-123.test", "shop-ticket-123.test", ".shop-ticket-123.test",
        ])
        #expect(!domains.contains("test"))
        #expect(!domains.contains(".test"))
    }

    @Test func locationSlashInLocalModeHasTheLinesOfTheRewriteInTheirOrder() throws {
        let lines = ShareRewrite.lines(for: share(redirectHost: "www.wptest.internal", extraHosts: ["cms.internal"]), settings: settings())
        let order = try [
            "error_page 597 = @nexus_share_body;",
            "if ($nexus_share_reverse) {",
            "proxy_set_header Accept-Encoding \"\";",
            "proxy_set_header X-Forwarded-Host $host;",
            "proxy_set_header X-Forwarded-Proto https;",
            "proxy_set_header X-Forwarded-Port 443;",
            "proxy_set_header X-Forwarded-Prefix \"\";",
            "proxy_set_header Forwarded \"\";",
            "proxy_set_header Origin $nexus_share_\(Self.id)_origin;",
            "proxy_set_header Referer $nexus_share_\(Self.id)_referer;",
            #"proxy_redirect "~*^https?://cms\.internal(?::30443|:30080)?(/.*)?$" "https://$host/_nexus/host/cms.internal$1";"#,
            #"proxy_redirect "~*^https?://(?:www\.wptest\.internal|wptest\.internal)(?::30443|:30080)?(/.*)?$" "https://$host$1";"#,
            "proxy_cookie_domain cms.internal $host;",
            "proxy_cookie_domain .cms.internal $host;",
            "proxy_cookie_domain www.wptest.internal $host;",
            "proxy_cookie_domain .www.wptest.internal $host;",
            "proxy_cookie_domain wptest.internal $host;",
            "proxy_cookie_domain .wptest.internal $host;",
            "sub_filter_once off;",
            "sub_filter_types \(ShareRewrite.types.joined(separator: " "));",
            #"sub_filter "https://cms.internal:30443" "https://$host/_nexus/host/cms.internal";"#,
            #"sub_filter "https:\\/\\/cms.internal:30443" "https:\\/\\/$host\\/_nexus\\/host\\/cms.internal";"#,
            #"sub_filter "https%3A%2F%2Fcms.internal%3A30443" "https%3A%2F%2F$host%2F_nexus%2Fhost%2Fcms.internal";"#,
            #"sub_filter "https://cms.internal" "https://$host/_nexus/host/cms.internal";"#,
            #"sub_filter "https://www.wptest.internal:30443" "https://$host";"#,
            #"sub_filter "https://www.wptest.internal" "https://$host";"#,
            #"sub_filter "https://wptest.internal:30443" "https://$host";"#,
            #"sub_filter "//wptest.internal" "//$host";"#,
            "js_header_filter nexus_share_\(Self.id).headers;",
        ].map { try index(of: $0, in: lines) }

        #expect(order == order.sorted())
        #expect(lines.last == "js_header_filter nexus_share_\(Self.id).headers;")
        #expect(lines.filter { $0.hasPrefix("sub_filter \"") }.count == 48)
        #expect(ShareRewrite.types.contains("application/manifest+json"))
        #expect(ShareRewrite.types.contains("text/x-component"))
    }

    @Test func publicModeSendsNoOriginAndNoRefererButKeepsTheRest() {
        let local = ShareRewrite.lines(for: share(), settings: settings())
        let lines = ShareRewrite.lines(for: share(mode: .publicHost), settings: settings())

        #expect(!lines.contains { $0.contains("Origin") || $0.contains("Referer") })
        #expect(lines.count == local.count - 2)
        #expect(lines.contains("proxy_set_header X-Forwarded-Host $host;"))
        #expect(lines.contains("js_header_filter nexus_share_\(Self.id).headers;"))
    }

    @Test func aBlockWithoutAScriptHasNoLineOfNjs() {
        let block = share(extraHosts: ["cms.internal"], reverb: true, script: nil)
        let lines = ShareRewrite.lines(for: block, settings: settings()) + ShareRewrite.locations(for: block, settings: settings())

        #expect(!lines.contains { $0.contains("js_") || $0.contains("error_page 597") || $0.contains("return 597") || $0.contains("proxy_set_body") })
        #expect(ShareRewrite.viteLines(for: block).isEmpty)
        #expect(ShareRewrite.httpLines(for: [block], settings: settings()).allSatisfy { !$0.contains("js_") })
    }

    @Test func reverbGetsItsTwoLocationsOnlyWithReverb() throws {
        let lines = ShareRewrite.locations(for: share(reverb: true), settings: settings())
        let socket = try block("location = /app/app-key", in: lines)
        let events = try block("location /apps/123456/", in: lines)

        #expect(socket.contains("    proxy_pass http://127.0.0.1:8080;"))
        #expect(socket.contains("    proxy_set_header Host 127.0.0.1:8080;"))
        #expect(socket.contains("    proxy_set_header Origin $nexus_share_\(Self.id)_origin;"))
        #expect(socket.contains("    proxy_set_header Upgrade $http_upgrade;"))
        #expect(events.contains("    access_log off;"))
        #expect(events.contains("    proxy_pass http://127.0.0.1:8080;"))
        #expect(!events.contains { $0.contains("proxy_set_header Origin ") })
        #expect(!ShareRewrite.locations(for: share(), settings: settings()).contains { $0.contains("/app") })
    }

    @Test func aSecondLocalHostHasItsPathAndItsSiteBlockSeesANormalRequest() throws {
        let lines = ShareRewrite.locations(for: share(extraHosts: ["api.shop.test", "cms.internal"]), settings: settings())
        let location = try block("location /_nexus/host/cms.internal/", in: lines)
        let named = try block("location @nexus_share_body_2", in: lines)
        let rewrite = #"    rewrite ^/_nexus/host/cms\.internal(/.*)$ $1 break;"#

        #expect(location.contains("    error_page 597 = @nexus_share_body_2;"))
        #expect(try index(of: "    if ($nexus_share_reverse) {", in: location) < index(of: rewrite, in: location))
        #expect(location.contains("    proxy_ssl_name cms.internal;"))
        #expect(location.contains("    proxy_set_header Host cms.internal:30443;"))
        #expect(location.contains("    proxy_set_header X-Nexus-Share \"\";"))
        #expect(location.contains("    proxy_set_header X-Nexus-Share-Host \"\";"))
        #expect(location.contains("    proxy_set_header Origin $nexus_share_\(Self.id)_origin;"))
        #expect(location.contains("    proxy_redirect / /_nexus/host/cms.internal/;"))
        #expect(named.contains(rewrite))
        #expect(named.contains("    proxy_set_body $nexus_share_\(Self.id)_body;"))
        #expect(named.contains("    client_body_buffer_size 1m;"))
        #expect(named.contains("    client_body_in_single_buffer on;"))
        #expect(!named.contains { $0.contains("if (") || $0.contains("error_page 597") })
        #expect(lines.contains("location @nexus_share_body_1 {"))
    }

    @Test func theNamedLocationOfTheSiteSendsTheChangedBodyWithTheLinesOfLocationSlash() throws {
        let block = share(mode: .publicHost)
        let named = try self.block("location @nexus_share_body", in: ShareRewrite.locations(for: block, settings: settings()))
        let rewrite = ShareRewrite.lines(for: block, settings: settings()).filter { !$0.isEmpty && !$0.contains("597") && !$0.contains("$nexus_share_reverse") && $0 != "}" }

        #expect(named.contains("    proxy_set_body $nexus_share_\(Self.id)_body;"))
        #expect(named.contains("    client_body_buffer_size 1m;"))
        #expect(named.contains("    proxy_set_header X-Nexus-Share \(Self.id);"))
        #expect(named.contains("    proxy_set_header Host wptest.internal:30443;"))
        #expect(!named.contains { $0.contains("if (") || $0.contains("error_page 597") })
        #expect(rewrite.allSatisfy { named.contains("    \($0)") })
        #expect(ShareViteRoutes.siteLines(for: block).allSatisfy { named.contains("    \($0)") })
    }

    @Test func theHTTPBlockHasTheNjsLinesAndTheMapsOfEachLinkAndTheMapsOfTheBodiesOneTime() throws {
        let second = "fedcba9876543210fedcba9876543210"
        let lines = ShareRewrite.httpLines(for: [share(redirectHost: "www.wptest.internal", extraHosts: ["cms.internal"]), share(second, host: "shop.test")], settings: settings())

        #expect(lines.filter { $0.hasPrefix("js_import ") } == [
            "js_import nexus_share_\(Self.id) from \"/Users/me/Library/Application Support/Nexus Dev/data/share/\(Self.id).js\";",
            "js_import nexus_share_\(second) from \"/Users/me/Library/Application Support/Nexus Dev/data/share/\(second).js\";",
        ])
        #expect(lines.filter { $0.hasPrefix("js_set ") } == [
            "js_set $nexus_share_\(Self.id)_body nexus_share_\(Self.id).body;",
            "js_set $nexus_share_\(second)_body nexus_share_\(second).body;",
        ])
        #expect(try block("map \"$http_origin|$host\" $nexus_share_\(Self.id)_origin", in: lines) == [
            "map \"$http_origin|$host\" $nexus_share_\(Self.id)_origin {",
            "    default $http_origin;",
            #"    "~^https://([^/|]+)\|\1$" "https://www.wptest.internal:30443";"#,
            "}",
        ])
        #expect(try block("map \"$http_referer|$host\" $nexus_share_\(Self.id)_referer", in: lines) == [
            "map \"$http_referer|$host\" $nexus_share_\(Self.id)_referer {",
            "    default $http_referer;",
            #"    "~^https://(?<nexus_public>[^/|]+)/_nexus/host/cms\.internal(?<nexus_path>/[^|]*)?\|\k<nexus_public>$" "https://cms.internal:30443$nexus_path";"#,
            #"    "~^https://(?<nexus_public>[^/|]+)(?<nexus_path>/[^|]*)?\|\k<nexus_public>$" "https://www.wptest.internal:30443$nexus_path";"#,
            "}",
        ])
        #expect(lines.contains(#"    "~^https://([^/|]+)\|\1$" "https://shop.test:30443";"#))
        #expect(lines.filter { $0 == "map $http_cookie $nexus_share_cookie {" }.count == 1)
        #expect(lines.filter { $0 == "map $content_type $nexus_share_text {" }.count == 1)
        #expect(lines.filter { $0 == "map $content_length $nexus_share_small {" }.count == 1)
        #expect(try block("map \"$nexus_share_cookie$nexus_share_text$nexus_share_small\" $nexus_share_reverse", in: lines).contains("    \"111\" 1;"))
        #expect(lines.contains(#"    "~^[0-9]{1,6}$" 1;"#))
        #expect(ShareRewrite.httpLines(for: [], settings: settings()).isEmpty)
    }

    @Test func theScriptHoldsTheFormsOfTheLinkAsJSONAndTheSameFunctionsForEachLink() throws {
        let block = share(mode: .publicHost, extraHosts: ["cms.internal"])
        let script = try ShareRewrite.script(for: block, settings: settings())
        let other = try ShareRewrite.script(for: share(host: "shop.test"), settings: settings())
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let constant = try #require(lines.first { $0.hasPrefix("const LINK = ") })
        let json = constant.dropFirst("const LINK = ".count).dropLast()
        let link = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let answer = try #require(link["answer"] as? [[String]])
        let request = try #require(link["request"] as? [[String]])

        #expect(lines.first == "// Nexus writes this file for one public link (group 4, 4c). nginx runs it with njs.")
        #expect(link["publicMode"] as? Bool == true)
        #expect(answer.first == ["https://cms.internal:30443", "https://{public}/_nexus/host/cms.internal"])
        #expect(answer.contains(["https://wptest.internal:30443", "https://{public}"]))
        #expect(answer.contains([#"https:\/\/wptest.internal"#, #"https:\/\/{public}"#]))
        #expect(!answer.contains { $0[0].contains("%3A") })
        #expect(request.count == 10)
        #expect(request.first == ["https://{public}/_nexus/host/cms.internal", "https://cms.internal:30443"])
        #expect(request[5] == ["https://{public}", "https://wptest.internal:30443"])

        for function in ["function headers(r)", "function body(r)", "function viteHeaders(r)", "function viteBody(r, data, flags)", "export default { headers, body, viteHeaders, viteBody };"] {
            #expect(script.contains(function))
        }

        #expect(script.contains("const HEADERS = [\"Link\",\"Content-Security-Policy\""))
        #expect(lines.filter { !$0.hasPrefix("const LINK = ") } == other.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.hasPrefix("const LINK = ") })
    }

    @Test func theLinesOfViteChangeTheValuesOfReverbOnlyWithReverb() {
        #expect(ShareRewrite.viteLines(for: share(reverb: true)) == [
            "js_header_filter nexus_share_\(Self.id).viteHeaders;",
            "js_body_filter nexus_share_\(Self.id).viteBody buffer_type=string;",
        ])
        #expect(ShareRewrite.viteLines(for: share()).isEmpty)
    }

    @Test func theProxyLinesSendTheHostWithThePortAsABrowserDoes() {
        let lines = ShareConfig.proxyLines(share(), host: "shop.test", marksLink: true, settings: settings())
        let standard = ShareConfig.proxyLines(share(), host: "shop.test", marksLink: true, settings: settings(https: 443, http: 80))
        let second = ShareConfig.proxyLines(share(), host: "cms.shop.test", marksLink: false, settings: settings())

        #expect(lines == [
            "proxy_pass https://127.0.0.1:30443;",
            "proxy_http_version 1.1;",
            "proxy_ssl_server_name on;",
            "proxy_ssl_name shop.test;",
            "proxy_set_header Host shop.test:30443;",
            "proxy_set_header X-Nexus-Share \(Self.id);",
            "proxy_set_header X-Nexus-Share-Host $host;",
            "proxy_set_header X-Nexus-Share-Request $request_id;",
            "proxy_set_header X-Nexus-Share-Visitor $http_cf_connecting_ip;",
            "proxy_set_header Upgrade $http_upgrade;",
            "proxy_set_header Connection $connection_upgrade;",
            "proxy_read_timeout 300;",
        ])
        #expect(standard.contains("proxy_set_header Host shop.test;"))
        #expect(second.contains("proxy_set_header X-Nexus-Share \"\";"))
        #expect(second.contains("proxy_set_header X-Nexus-Share-Host \"\";"))
        #expect(second.contains("proxy_ssl_name cms.shop.test;"))
    }

    @Test func theShareBlockSendsTheHostThatTheSiteRedirectsTo() throws {
        let lines = try ShareConfig.render(share(redirectHost: "www.wptest.internal"), settings: settings())
        let location = try block("    location /", in: lines)

        #expect(location.contains("        proxy_ssl_name www.wptest.internal;"))
        #expect(location.contains("        proxy_set_header Host www.wptest.internal:30443;"))
        #expect(try index(of: "    location @nexus_share_body {", in: lines) < index(of: "    location / {", in: lines))
    }

    @Test func nginxTakesTheFirstErrorPageSoTheBodyOfTheRewriteComesBeforeThePlainPage() throws {
        let lines = try ShareConfig.render(share(extraHosts: ["cms.internal"]), settings: settings())

        for head in ["    location / {", "    location /_nexus/host/cms.internal/ {"] {
            let start = try index(of: head, in: lines)
            let end = try #require(lines[start...].firstIndex(of: "    }"))
            let location = Array(lines[start...end])
            let body = try #require(location.firstIndex { $0.contains("error_page 597 = @nexus_share_body") })
            let plainPage = try #require(location.firstIndex { $0.hasSuffix(" @nexus_guard_error;") })

            #expect(body < plainPage)
        }
    }
}
