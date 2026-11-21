import Foundation
import NexusCore

// The lines of the host and the rewrite of answers (group 4, 4c). The site sees the public host
// (public mode) or its local host (local mode). The share block changes the local host into the
// public host in each answer and back in the body of a browser request (decision 2, owner
// 2026-11-17). Each function gives its lines without the indent of their place.
public enum ShareRewrite {
    // A FastCGI value whose value must stay for a request that is not of the link. nginx sends the
    // other names only for a request of the link.
    static let fastcgiDefaults = [
        "HTTP_HOST": "$http_host",
        "SERVER_NAME": "$server_name",
        "SERVER_PORT": "$server_port",
        "REMOTE_ADDR": "$remote_addr",
    ]

    // The headers that the njs module changes (F11). proxy_redirect changes Location and Refresh.
    static let headers = [
        "Link", "Content-Security-Policy", "Content-Security-Policy-Report-Only",
        "Access-Control-Allow-Origin", "Content-Location", "X-Inertia-Location",
        "HX-Location", "HX-Redirect", "HX-Push-Url", "HX-Replace-Url",
    ]

    // The content types of sub_filter (F11). nginx always adds text/html.
    static let types = [
        "text/css", "text/javascript", "application/javascript", "application/x-javascript",
        "application/json", "application/xml", "text/xml", "image/svg+xml",
        "application/manifest+json", "application/ld+json", "application/vnd.api+json",
        "application/rss+xml", "application/atom+xml", "text/x-component", "text/plain",
    ]

    // No site sends this code. 4e uses 418 for @nexus_vite. proxy_intercept_errors of 4d would
    // send a 418 of a site to the location of that code.
    static let bodyCode = 597

    static let publicHostVariable = "$host"
    static let publicPlaceholder = "{public}"
    static let hostPrefix = "/_nexus/host/"

    // The lines of the http block: for each link its njs module, its body variable and its maps of
    // Origin and Referer. For a list with links also the maps that choose the bodies for the
    // reverse rewrite. An empty list gives no lines. The maps need the ports of Nexus for the local
    // origin.
    public static func httpLines(for shares: [ShareBlock], settings: NginxSettings) -> [String] {
        guard !shares.isEmpty else {
            return []
        }

        var lines: [String] = []

        for share in shares {
            lines.append("")

            if let script = share.rewriteScript, let path = try? ConfigText.quoted(script) {
                lines += [
                    "js_import \(module(of: share)) from \(path);",
                    "js_set \(bodyVariable(of: share)) \(module(of: share)).body;",
                    "",
                ]
            }

            lines += [
                "map \"$http_origin|$host\" $nexus_share_\(share.id)_origin {",
                "    default $http_origin;",
                "    \"~^https://([^/|]+)\\|\\1$\" \"\(settings.origin(of: share.upstreamHost))\";",
                "}",
                "",
                "map \"$http_referer|$host\" $nexus_share_\(share.id)_referer {",
                "    default $http_referer;",
            ]

            for host in share.extraHosts {
                lines.append("    \"~^https://(?<nexus_public>[^/|]+)\(ConfigText.regexEscaped(hostPrefix + host))(?<nexus_path>/[^|]*)?\\|\\k<nexus_public>$\" \"\(settings.origin(of: host))$nexus_path\";")
            }

            lines += [
                "    \"~^https://(?<nexus_public>[^/|]+)(?<nexus_path>/[^|]*)?\\|\\k<nexus_public>$\" \"\(settings.origin(of: share.upstreamHost))$nexus_path\";",
                "}",
            ]
        }

        // A webhook has no cookie. A form with a file is multipart. Both keep their body (owner,
        // 2026-11-20: question 3).
        lines += [
            "",
            "map $http_cookie $nexus_share_cookie {",
            "    default 1;",
            "    \"\" 0;",
            "}",
            "",
            "map $content_type $nexus_share_text {",
            "    default 0;",
            "    \"~*^application/x-www-form-urlencoded\" 1;",
            "    \"~*^application/([a-z0-9.+-]*\\+)?json\" 1;",
            "}",
            "",
            "map $content_length $nexus_share_small {",
            "    default 0;",
            "    \"~^[0-9]{1,6}$\" 1;",
            "}",
            "",
            "map \"$nexus_share_cookie$nexus_share_text$nexus_share_small\" $nexus_share_reverse {",
            "    default 0;",
            "    \"111\" 1;",
            "}",
        ]

        return lines
    }

    // The lines in location / of the share block, after ShareConfig.proxyLines. Public mode sends no
    // Origin and no Referer of the site, because the site knows the public host.
    public static func lines(for share: ShareBlock, settings: NginxSettings) -> [String] {
        reverseLines(for: share, location: "@nexus_share_body") + rewriteLines(for: share, settings: settings, keepsOrigin: share.mode == .localHost)
    }

    // The locations before location /: Reverb, the second local hosts and the named locations of
    // the reverse rewrite. A second local host gets no X-Nexus-Share id. So its site block sees a
    // normal request (owner, review-4ab question 3).
    public static func locations(for share: ShareBlock, settings: NginxSettings) -> [String] {
        var lines = reverbLocations(for: share)

        for (offset, host) in share.extraHosts.enumerated() {
            let named = "@nexus_share_body_\(offset + 1)"
            let rewrite = "rewrite ^\(ConfigText.regexEscaped(hostPrefix + host))(/.*)$ $1 break;"
            let shared = ShareConfig.proxyLines(share, host: host, marksLink: false, settings: settings)
                + rewriteLines(for: share, settings: settings, keepsOrigin: true)
                + ["proxy_redirect / \(hostPrefix)\(host)/;"]
                + ShareProtection.answerLines(for: share)

            lines += [""] + block("location \(hostPrefix)\(host)/", reverseLines(for: share, location: named) + [rewrite] + shared)

            if share.rewriteScript != nil {
                lines += [""] + block("location \(named)", [rewrite] + bodyLines(for: share) + shared)
            }
        }

        if share.rewriteScript != nil {
            lines += [""] + block("location @nexus_share_body", siteLocation(for: share, settings: settings, readsBody: true))
        }

        return lines
    }

    // The lines that send a request of the link to its site. location / adds the choice of the
    // reverse rewrite. @nexus_share_body adds the body of njs.
    public static func siteLocation(for share: ShareBlock, settings: NginxSettings, readsBody: Bool) -> [String] {
        let rewrite = readsBody
            ? rewriteLines(for: share, settings: settings, keepsOrigin: share.mode == .localHost)
            : lines(for: share, settings: settings)

        return (readsBody ? bodyLines(for: share) : [])
            + ShareConfig.proxyLines(share, host: share.upstreamHost, marksLink: true, settings: settings)
            + rewrite
            + ShareViteRoutes.siteLines(for: share)
            + ShareProtection.answerLines(for: share)
    }

    // The lines that 4e puts into its named location @nexus_vite: the three Reverb values in
    // import.meta.env of the modules of Vite.
    public static func viteLines(for share: ShareBlock) -> [String] {
        guard share.reverb != nil, share.rewriteScript != nil else {
            return []
        }

        return [
            "js_header_filter \(module(of: share)).viteHeaders;",
            "js_body_filter \(module(of: share)).viteBody buffer_type=string;",
        ]
    }

    // The njs module of one link. Only the constant LINK changes from link to link.
    public static func script(for share: ShareBlock, settings: NginxSettings) throws -> String {
        let hosts = share.extraHosts.map { (host: $0, prefix: hostPrefix + $0) } + siteHosts(of: share).map { (host: $0, prefix: "") }
        let answer = hosts.flatMap { answerForms(of: $0.host, prefix: $0.prefix, settings: settings) }
            .filter { !$0.from.contains("%3A") }
            .map { [$0.from, $0.to.replacingOccurrences(of: publicHostVariable, with: publicPlaceholder)] }
        let request = share.extraHosts.flatMap { requestForms(prefix: hostPrefix + $0, localOrigin: settings.origin(of: $0)) }
            + requestForms(prefix: "", localOrigin: settings.origin(of: share.upstreamHost))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let link = String(decoding: try encoder.encode(ScriptLink(publicMode: share.mode == .publicHost, answer: answer, request: request.map { [$0.from, $0.to] })), as: UTF8.self)
        let names = String(decoding: try encoder.encode(headers), as: UTF8.self)

        return """
            // Nexus writes this file for one public link (group 4, 4c). nginx runs it with njs.
            const LINK = \(link);

            \(scriptBody.replacingOccurrences(of: "%headers%", with: names))
            """
    }

    // The maps of a site block with an open link, before its server block. The map compares the id
    // of the link. So a request without that id keeps each value.
    static func siteMaps(for site: WebSite, index: Int) -> [String] {
        guard let share = site.share else {
            return []
        }

        if case .php(.nginx, _, _, _) = site.backend {
            return fastcgiValues(of: share).enumerated().flatMap { offset, pair in
                map(of: share, named: "$nexus_share_\(index)_\(offset)", default: fastcgiDefaults[pair.key] ?? "\"\"", value: pair.value)
            }
        }

        if case .notice = site.backend {
            return []
        }

        let port = map(of: share, named: "$nexus_share_\(index)_port", default: "$server_port", value: "443")

        guard site.usesApache else {
            return port
        }

        let hides = share.shareSocket == nil ? [] : map(of: share, named: "$nexus_share_\(index)_hide", default: "\"\"", value: "1")
        return port + map(of: share, named: "$nexus_share_\(index)_host", default: "\"\"", value: ShareConfig.Header.host.variable) + hides
    }

    // The FastCGI lines of a PHP site in nginx with an open link. nginx sends no empty value with
    // if_not_empty. PHP-FPM keeps the last value of a name. So a value here wins over fastcgi.conf.
    static func fastcgiLines(for site: WebSite, index: Int) -> [String] {
        guard let share = site.share, case .php(.nginx, _, _, _) = site.backend else {
            return []
        }

        return fastcgiValues(of: share).enumerated().map { offset, pair in
            "fastcgi_param \(pair.key) $nexus_share_\(index)_\(offset) if_not_empty;"
        }
    }

    // A request of the link to Apache, an app or a proxy site comes through port 443 of the public
    // host.
    static func forwardedPort(for site: WebSite, index: Int) -> String {
        site.share == nil ? "$server_port" : "$nexus_share_\(index)_port"
    }

    // An Apache site gets the public host only for a request of its own link. So a local request
    // cannot give Apache a public host.
    static func apacheShareHost(for site: WebSite, index: Int) -> String {
        site.share == nil ? "\"\"" : "$nexus_share_\(index)_host"
    }

    // An Apache site gets the protection of hidden errors through this header (4d). Apache then sets
    // the values of ShareProtection.hiddenErrorValues and sends PHP to the pool nexus-share.
    static func apacheShareHide(for site: WebSite, index: Int) -> String {
        site.share?.shareSocket == nil ? "\"\"" : "$nexus_share_\(index)_hide"
    }

    // The forms of one local host in an answer and the public form that replaces it. A form with a
    // port comes before the same form without it, because sub_filter takes the first line for one
    // place in the text.
    static func answerForms(of host: String, prefix: String, settings: NginxSettings) -> [(from: String, to: String)] {
        let https = settings.httpsSuffix.isEmpty ? nil : settings.httpsSuffix
        let http = settings.httpSuffix.isEmpty ? nil : settings.httpSuffix
        let secure = "https://\(publicHostVariable)\(prefix)"
        let relative = "//\(publicHostVariable)\(prefix)"
        let origins: [(from: String, to: String, hasQueryForm: Bool)?] = [
            https.map { ("https://\(host)\($0)", secure, true) },
            ("https://\(host)", secure, true),
            http.map { ("http://\(host)\($0)", secure, true) },
            ("http://\(host)", secure, true),
            https.map { ("//\(host)\($0)", relative, false) },
            ("//\(host)", relative, false),
        ]

        return origins.compactMap { $0 }.flatMap { origin in
            [(origin.from, origin.to), (jsonForm(origin.from), jsonForm(origin.to))]
                + (origin.hasQueryForm ? [(queryForm(origin.from), queryForm(origin.to))] : [])
        }
    }

    // The forms of the public host in a request body and the local form that replaces it. "{public}"
    // stands for the public host. The njs module puts in the host of the request.
    static func requestForms(prefix: String, localOrigin: String) -> [(from: String, to: String)] {
        let from = "https://\(publicPlaceholder)\(prefix)"

        return [
            (from, localOrigin),
            (jsonForm(from), jsonForm(localOrigin)),
            (jsonInJSONForm(from), jsonInJSONForm(localOrigin)),
            (queryForm(from), queryForm(localOrigin)),
            (queryForm(jsonForm(from)), queryForm(jsonForm(localOrigin))),
        ]
    }

    // The domain of each cookie that becomes the public host: each host and each parent domain with
    // at least two labels, with and without a dot at the start.
    static func cookieDomains(of hosts: [String]) -> [String] {
        var domains: [String] = []

        for host in hosts {
            let labels = host.split(separator: ".").map(String.init)

            for start in labels.indices where labels.count - start >= 2 {
                let domain = labels[start...].joined(separator: ".")

                for form in [domain, ".\(domain)"] where !domains.contains(form) {
                    domains.append(form)
                }
            }
        }

        return domains
    }

    // The upstream host first, then the host of the link when the site redirects to another host
    // (F1).
    static func siteHosts(of share: ShareBlock) -> [String] {
        share.upstreamHost == share.host ? [share.host] : [share.upstreamHost, share.host]
    }

    // The values with a safe key and a safe value, sorted by key. A value goes between double
    // quotes in a map. So it has no quote, no backslash and no line break.
    static func fastcgiValues(of share: SiteShare) -> [(key: String, value: String)] {
        share.fastcgiValues
            .filter { ConfigText.isSafeKey($0.key) && isSafeValue($0.value) }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    private static func isSafeValue(_ value: String) -> Bool {
        !value.contains { $0 == "\"" || $0 == "\\" || $0.isNewline || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    }

    private static func map(of share: SiteShare, named name: String, default fallback: String, value: String) -> [String] {
        [
            "map $nexus_share \(name) {",
            "    default \(fallback);",
            "    \"\(share.id)\" \"\(value)\";",
            "}",
            "",
        ]
    }

    private static func reverbLocations(for share: ShareBlock) -> [String] {
        guard let reverb = share.reverb else {
            return []
        }

        let port = reverb.port
        let answer = ShareProtection.answerLines(for: share)

        return [""] + block("location = /app/\(reverb.key)", [
            "proxy_pass http://127.0.0.1:\(port);",
            "proxy_http_version 1.1;",
            "proxy_set_header Host 127.0.0.1:\(port);",
            "proxy_set_header Origin $nexus_share_\(share.id)_origin;",
            "proxy_set_header Upgrade $http_upgrade;",
            "proxy_set_header Connection $connection_upgrade;",
            "proxy_read_timeout 300;",
        ] + answer) + [""] + block("location /apps/\(reverb.appID)/", [
            "access_log off;",
            "proxy_pass http://127.0.0.1:\(port);",
            "proxy_http_version 1.1;",
            "proxy_set_header Host 127.0.0.1:\(port);",
            "proxy_read_timeout 300;",
        ] + answer)
    }

    // A browser request with a cookie and a small form or JSON body goes to a named location. There
    // the njs module changes the public host back into the local host (owner, 2026-11-17). The if
    // holds only return. That use of if is safe in nginx.
    private static func reverseLines(for share: ShareBlock, location: String) -> [String] {
        guard share.rewriteScript != nil else {
            return []
        }

        return [
            "error_page \(bodyCode) = \(location);",
            "",
            "if ($nexus_share_reverse) {",
            "    return \(bodyCode);",
            "}",
            "",
        ]
    }

    // The whole body is in one buffer in memory. So njs can read it before the proxy sends it.
    private static func bodyLines(for share: ShareBlock) -> [String] {
        ShareConfig.bodyBufferLines + ["proxy_set_body \(bodyVariable(of: share));"]
    }

    private static func rewriteLines(for share: ShareBlock, settings: NginxSettings, keepsOrigin: Bool) -> [String] {
        var lines = [
            "proxy_set_header Accept-Encoding \"\";",
            "proxy_set_header X-Forwarded-Host $host;",
            "proxy_set_header X-Forwarded-Proto https;",
            "proxy_set_header X-Forwarded-Port 443;",
            "proxy_set_header X-Forwarded-Prefix \"\";",
            "proxy_set_header Forwarded \"\";",
        ]

        if keepsOrigin {
            lines += [
                "proxy_set_header Origin $nexus_share_\(share.id)_origin;",
                "proxy_set_header Referer $nexus_share_\(share.id)_referer;",
            ]
        }

        let ports = "(?::\(settings.httpsPort)|:\(settings.httpPort))?"
        let sites = siteHosts(of: share)

        // The first proxy_redirect that matches wins. So the second local hosts come first.
        for host in share.extraHosts {
            lines.append("proxy_redirect \"~*^https?://\(ConfigText.regexEscaped(host))\(ports)(/.*)?$\" \"https://$host\(hostPrefix)\(host)$1\";")
        }

        lines.append("proxy_redirect \"~*^https?://(?:\(sites.map(ConfigText.regexEscaped).joined(separator: "|")))\(ports)(/.*)?$\" \"https://$host$1\";")
        lines += cookieDomains(of: share.extraHosts + sites).map { "proxy_cookie_domain \($0) $host;" }
        lines += [
            "sub_filter_once off;",
            "sub_filter_types \(types.joined(separator: " "));",
        ]

        for host in share.extraHosts {
            lines += answerForms(of: host, prefix: hostPrefix + host, settings: settings).map(subFilter)
        }

        for host in sites {
            lines += answerForms(of: host, prefix: "", settings: settings).map(subFilter)
        }

        if share.rewriteScript != nil {
            lines.append("js_header_filter \(module(of: share)).headers;")
        }

        return lines
    }

    private static func subFilter(_ form: (from: String, to: String)) -> String {
        "sub_filter \"\(ConfigText.nginxQuoted(form.from))\" \"\(ConfigText.nginxQuoted(form.to))\";"
    }

    private static func block(_ head: String, _ body: [String]) -> [String] {
        ["\(head) {"] + body.map { $0.isEmpty ? "" : "    \($0)" } + ["}"]
    }

    private static func module(of share: ShareBlock) -> String {
        "nexus_share_\(share.id)"
    }

    private static func bodyVariable(of share: ShareBlock) -> String {
        "$nexus_share_\(share.id)_body"
    }

    private static func jsonForm(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "\\/")
    }

    // The JSON form inside a JSON string, for example the snapshot of Livewire in its update.
    private static func jsonInJSONForm(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "\\\\/")
    }

    private static func queryForm(_ text: String) -> String {
        let codes: [Character: String] = [":": "%3A", "/": "%2F", "\\": "%5C"]
        return text.map { codes[$0] ?? String($0) }.joined()
    }

    private struct ScriptLink: Encodable {
        let publicMode: Bool
        let answer: [[String]]
        let request: [[String]]
    }

    // The same text for each link. It uses only split, join, RegExp, JSON and TextDecoder, as the
    // njs of nginx 1.30 has them. At one place in a text the first form of a list wins, as with
    // sub_filter. body() changes a match only at the end of a host, as EnvRewrite.isBoundary(after:)
    // does. In public mode Laravel itself writes the public host into each snapshot of Livewire. So
    // such a body stays as it is (owner, 2026-11-20: question 2). A body that is not valid UTF-8 goes
    // to the site as its original bytes. js_set gives the bytes of a Buffer without a change. No
    // body and an empty body give an empty text. The RegExp of the answers comes once from the load
    // of the module. The RegExp of a request body names the public host. Each request gets its own
    // copy of the module. So each request body builds its own RegExp. viteBody changes only a module
    // of JavaScript, because only such a module holds import.meta.env.
    private static let scriptBody = #"""
        const HEADERS = %headers%;
        const BOUNDARY = '(?![A-Za-z0-9-]|\\.[A-Za-z0-9])';
        const SPECIAL = ['\\', '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|'];
        const PARTS = {};

        function escaped(text) {
            let result = text;

            for (let i = 0; i < SPECIAL.length; i++) {
                result = result.split(SPECIAL[i]).join('\\' + SPECIAL[i]);
            }

            return result;
        }

        // The forms of pairs with host in place of {public}. One RegExp finds all of them.
        function compile(pairs, host, tail) {
            const forms = [];
            const sources = [];

            for (let i = 0; i < pairs.length; i++) {
                const from = pairs[i][0].split('{public}').join(host);
                forms.push([from.toLowerCase(), pairs[i][1]]);
                sources.push(escaped(from));
            }

            return { forms: forms, pattern: pairs.length === 0 ? null : new RegExp('(?:' + sources.join('|') + ')' + tail, 'gi') };
        }

        // The forms of an answer name no public host. So their RegExp is built once.
        const ANSWER = compile(LINK.answer, '', '');

        function swap(text, compiled, host) {
            const pattern = compiled.pattern;

            if (typeof text !== 'string' || text === '' || pattern === null) {
                return text;
            }

            const forms = compiled.forms;
            let result = '';
            let last = 0;
            pattern.lastIndex = 0;
            let match = pattern.exec(text);

            while (match !== null) {
                const found = match[0].toLowerCase();
                let replacement = match[0];

                for (let i = 0; i < forms.length; i++) {
                    if (forms[i][0] === found) {
                        replacement = forms[i][1].split('{public}').join(host);
                        break;
                    }
                }

                result += text.slice(last, match.index) + replacement;
                last = match.index + match[0].length;
                match = pattern.exec(text);
            }

            return result + text.slice(last);
        }

        function headers(r) {
            const host = r.variables.host;

            for (let i = 0; i < HEADERS.length; i++) {
                const value = r.headersOut[HEADERS[i]];

                if (typeof value !== 'string' || value === '') {
                    continue;
                }

                const changed = swap(value, ANSWER, host);

                if (changed !== value) {
                    r.headersOut[HEADERS[i]] = changed;
                }
            }
        }

        function body(r) {
            const bytes = r.requestBuffer;

            if (bytes === undefined || bytes === null || bytes.length === 0) {
                return '';
            }

            let text;

            try {
                text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
            } catch (e) {
                return bytes;
            }

            if (LINK.publicMode && text.indexOf('"snapshot"') !== -1 && text.indexOf('checksum') !== -1) {
                return bytes;
            }

            const host = r.variables.host;
            return swap(text, compile(LINK.request, host, BOUNDARY), host);
        }

        function viteHeaders(r) {
            headers(r);
            delete r.headersOut['Content-Length'];
        }

        function reverbValues(text, host) {
            const values = [['VITE_REVERB_HOST', host], ['VITE_REVERB_PORT', '443'], ['VITE_REVERB_SCHEME', 'https']];
            let result = text;

            for (let i = 0; i < values.length; i++) {
                const pattern = new RegExp('"' + values[i][0] + '":\\s*"[^"]*"');
                result = result.split(pattern).join('"' + values[i][0] + '": "' + values[i][1] + '"');
            }

            return result;
        }

        function viteBody(r, data, flags) {
            const type = r.headersOut['Content-Type'];

            if (typeof type !== 'string' || type.indexOf('javascript') === -1) {
                r.sendBuffer(data, flags);
                return;
            }

            const id = r.variables.request_id;
            const parts = PARTS[id] || [];
            parts.push(data);
            PARTS[id] = parts;

            if (!flags.last) {
                return;
            }

            delete PARTS[id];
            r.sendBuffer(reverbValues(parts.join(''), r.variables.host), flags);
        }

        export default { headers, body, viteHeaders, viteBody };

        """#
}
