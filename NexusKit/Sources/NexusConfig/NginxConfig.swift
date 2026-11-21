import Foundation
import NexusCore

public struct NginxSettings: Sendable, Equatable {
    public let httpPort: Int
    public let httpsPort: Int
    public let apachePort: Int
    public let lanAccess: Bool
    public let runtime: URL
    public let runFolder: URL
    public let modules: [String]

    public init(httpPort: Int, httpsPort: Int, apachePort: Int, lanAccess: Bool, runtime: URL, runFolder: URL, modules: [String]) {
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.apachePort = apachePort
        self.lanAccess = lanAccess
        self.runtime = runtime
        self.runFolder = runFolder
        self.modules = modules
    }

    // The pages that nginx serves itself. nginx reads a page at each request. So a new page needs
    // no reload.
    public var pages: URL {
        NexusPaths.nginxPages(inRun: runFolder)
    }

    // A port after a host, as a browser writes it: nothing for the standard port of the scheme.
    public static func portSuffix(_ port: Int, standard: Int) -> String {
        port == standard ? "" : ":\(port)"
    }

    public var httpsSuffix: String {
        Self.portSuffix(httpsPort, standard: 443)
    }

    public var httpSuffix: String {
        Self.portSuffix(httpPort, standard: 80)
    }

    // The host with the HTTPS port of Nexus, as a browser sends it in Host.
    public func authority(of host: String) -> String {
        host + httpsSuffix
    }

    // The origin of a host on the HTTPS port of Nexus, for example https://shop.test:8443.
    public func origin(of host: String) -> String {
        "https://\(authority(of: host))"
    }
}

// The front server. It listens on all addresses for HTTP and HTTPS, does TLS for every site,
// serves the nginx sites through php-fpm and sends the Apache sites to Apache (D23, D24). A Node.js
// app or a proxy site gets its requests at its address (D67).
public enum NginxConfig {
    // These are part of the nginx program. So they are always on. Every site needs them.
    public static let builtInModules = ["ssl", "http2", "proxy"]

    public static let dependencies = ToggleDependencies([
        "ngx_stream_geoip2_module": ["ngx_stream_module"],
        "ngx_stream_js_module": ["ngx_stream_module"],
    ])

    // The modules load in the order of the settings. The share blocks of the public links come after
    // the sites (group 4, 4b). requestScript is the njs file of the list of the requests (4f).
    public static func render(sites: [WebSite], shares: [ShareBlock] = [], requestScript: URL? = nil, settings: NginxSettings) throws -> String {
        let temp = settings.runFolder.appending(path: "nginx", directoryHint: .isDirectory)
        var lines: [String] = [
            "# Nexus writes this file. Changes are lost at the next change of a site.",
        ]

        for module in settings.modules {
            lines.append("load_module \(try ConfigText.quoted(settings.runtime.appending(path: "modules/\(module).so")));")
        }

        lines += [
            "daemon off;",
            "worker_processes auto;",
            "pid \(try ConfigText.quoted(settings.runFolder.appending(path: "nginx.pid")));",
            "error_log stderr warn;",
            "",
            "events {",
            "    worker_connections 1024;",
            "}",
            "",
            "http {",
            "    include \(try ConfigText.quoted(settings.runtime.appending(path: "conf/mime.types")));",
            "    default_type application/octet-stream;",
            "    sendfile on;",
            "    keepalive_timeout 65;",
            "    client_max_body_size 1024M;",
            "    server_names_hash_bucket_size 128;",
            "    client_body_temp_path \(try ConfigText.quoted(temp.appending(path: "client_body")));",
            "    proxy_temp_path \(try ConfigText.quoted(temp.appending(path: "proxy")));",
            "    fastcgi_temp_path \(try ConfigText.quoted(temp.appending(path: "fastcgi")));",
            "    uwsgi_temp_path \(try ConfigText.quoted(temp.appending(path: "uwsgi")));",
            "    scgi_temp_path \(try ConfigText.quoted(temp.appending(path: "scgi")));",
            "    access_log off;",
            "",
            "    map $http_upgrade $connection_upgrade {",
            "        default upgrade;",
            "        '' close;",
            "    }",
            "",
        ]

        lines += try ShareConfig.httpLines(for: shares, settings: settings, requestScript: requestScript).map { $0.isEmpty ? "" : "    \($0)" }
        lines.append("")

        let phpMaps = try sites.enumerated().map { index, site in try phpMap(for: site, index: index) }

        if phpMaps.contains(where: { !$0.isEmpty }) {
            lines += xdebugMaps
        }

        if !settings.lanAccess {
            lines += [
                "    # Only this Mac. The LAN setting removes these lines.",
                "    allow 127.0.0.1;",
                "    allow ::1;",
                "    deny all;",
                "",
            ]
        }

        lines += [
            "    server {",
            "        listen \(settings.httpPort) default_server;",
            "        listen [::]:\(settings.httpPort) default_server;",
            "        listen \(settings.httpsPort) ssl default_server;",
            "        listen [::]:\(settings.httpsPort) ssl default_server;",
            "        ssl_reject_handshake on;",
            "        root \(try ConfigText.quoted(settings.pages));",
            "        error_page 404 /\(ErrorPages.unknownSiteFile);",
            "",
            "        location / {",
            "            return 404;",
            "        }",
            "",
            "        location = /\(ErrorPages.unknownSiteFile) {",
            "            internal;",
            "            default_type text/html;",
            "            add_header Cache-Control no-store always;",
            "        }",
            "    }",
        ]

        for (index, site) in sites.enumerated() {
            lines.append("")
            lines += appUpstream(for: site, index: index, settings: settings).map { "    \($0)" }
            lines += phpMaps[index].map { "    \($0)" }
            // A request of a public link gets the values of its link (group 4, 4c). The map compares
            // the id of the link. So a request without that id keeps each value.
            lines += ShareRewrite.siteMaps(for: site, index: index).map { $0.isEmpty ? "" : "    \($0)" }
            lines += try server(for: site, index: index, settings: settings).map { "    \($0)" }
        }

        for share in shares {
            lines.append("")
            lines += try ShareConfig.render(share, settings: settings).map { $0.isEmpty ? "" : "    \($0)" }
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // A Node.js app can listen on 127.0.0.1 or on [::1] only, so nginx tries the other address when
    // the first one refuses. The Vite server listens on [::1], so that address comes first for it.
    // Next.js gets the origin of its own address for the origins of the site, and only for these.
    // So an origin of another website stays blocked. Only the dev paths of Next.js use this map.
    private static func appUpstream(for site: WebSite, index: Int, settings: NginxSettings) -> [String] {
        guard case .app(let port, let framework) = site.backend else {
            return []
        }

        let addresses = ["127.0.0.1:\(port)", "[::1]:\(port)"]
        let ordered = framework?.usesViteServer == true ? Array(addresses.reversed()) : addresses
        var lines = [
            "upstream nexus_app_\(index) {",
            "    server \(ordered[0]);",
            "    server \(ordered[1]) backup;",
            "}",
            "",
        ]

        guard framework?.checksOrigin == true else {
            return lines
        }

        lines += ["map $http_origin $nexus_origin_\(index) {", "    default $http_origin;"]
        lines += origins(of: site.hosts, settings: settings).map { "    \"\($0)\" \"http://localhost:\(port)\";" }
        lines += ["}", ""]
        return lines
    }

    // A name with *. becomes a regular expression of the map. It covers one label below its host,
    // as the certificate does (Phase 4, 3g).
    static func origins(of hosts: [String], settings: NginxSettings) -> [String] {
        hosts.flatMap { host in
            guard host.hasPrefix("*.") else {
                return [settings.origin(of: host), "http://\(host)\(settings.httpSuffix)"]
            }

            let below = ConfigText.regexEscaped(String(host.dropFirst(2)))

            return ["~^https://[^./]+\\.\(below)\(settings.httpsSuffix)$", "~^http://[^./]+\\.\(below)\(settings.httpSuffix)$"]
        }
    }

    // A request that starts an Xdebug session goes to the PHP-FPM with Xdebug (owner, 2026-11-14).
    // Xdebug 3 reads the trigger from a cookie or from the query string, not from a header. A
    // trigger without a value also counts. The regular expressions are case sensitive, as PHP is.
    // The share block removes the same triggers (group 4, 4d).
    static let xdebugCookiePattern = #"(^|;)\s*XDEBUG_(SESSION|TRIGGER)="#
    static let xdebugQueryPattern = #"(^|&)XDEBUG_(SESSION|SESSION_START|TRIGGER)(=|&|$)"#

    static let xdebugMaps = [
        "    map $http_cookie $nexus_xdebug_cookie {",
        "        default 0;",
        "        \"~\(xdebugCookiePattern)\" 1;",
        "    }",
        "",
        "    map $args $nexus_xdebug {",
        "        default $nexus_xdebug_cookie;",
        "        \"~\(xdebugQueryPattern)\" 1;",
        "    }",
        "",
    ]

    // nginx passes the PHP requests of a site to target. With the Xdebug switch on, the map before
    // the server block chooses the socket of each request. A request of a link with hidden errors
    // goes to the pool nexus-share. So it never reaches Xdebug (group 4, 4d).
    private static func phpPass(socket: URL, xdebugSocket: URL?, index: Int, share: SiteShare?) throws -> (map: [String], target: String) {
        let standard = try ConfigText.socket(socket, prefix: "unix:")
        let debug = try xdebugSocket.map { try ConfigText.socket($0, prefix: "unix:") }
        let link = try share.flatMap { share in try share.shareSocket.map { (id: share.id, target: try ConfigText.socket($0, prefix: "unix:")) } }

        switch (debug, link) {
        case (nil, nil):
            return ([], standard)
        case (let debug?, nil):
            return ([
                "map $nexus_xdebug $nexus_php_\(index) {",
                "    default \(standard);",
                "    1 \(debug);",
                "}",
                "",
            ], "$nexus_php_\(index)")
        case (nil, let link?):
            return ([
                "map $nexus_share $nexus_php_\(index) {",
                "    default \(standard);",
                "    \"\(link.id)\" \(link.target);",
                "}",
                "",
            ], "$nexus_php_\(index)")
        case (let debug?, let link?):
            return ([
                "map \"$nexus_share|$nexus_xdebug\" $nexus_php_\(index) {",
                "    default \(standard);",
                "    \"|1\" \(debug);",
                "    \"\(link.id)|0\" \(link.target);",
                "    \"\(link.id)|1\" \(link.target);",
                "}",
                "",
            ], "$nexus_php_\(index)")
        }
    }

    // Apache chooses the socket of an Apache site itself.
    private static func phpMap(for site: WebSite, index: Int) throws -> [String] {
        guard case .php(.nginx, _, let socket, let xdebugSocket) = site.backend else {
            return []
        }

        return try phpPass(socket: socket, xdebugSocket: xdebugSocket, index: index, share: site.share).map
    }

    private static func server(for site: WebSite, index: Int, settings: NginxSettings) throws -> [String] {
        var lines = [
            "server {",
            "    listen \(settings.httpPort);",
            "    listen [::]:\(settings.httpPort);",
            "    listen \(settings.httpsPort) ssl;",
            "    listen [::]:\(settings.httpsPort) ssl;",
            "    http2 on;",
            "    server_name \(site.hosts.joined(separator: " "));",
            "    ssl_certificate \(try ConfigText.quoted(site.certificate));",
            "    ssl_certificate_key \(try ConfigText.quoted(site.key));",
            // A request through a link writes no line in the access log of the site. So it does not
            // start the dev server by itself (group 4, 4b). nginx reads the third word as the format.
            "    access_log \(try ConfigText.quoted(site.accessLog)) combined if=$nexus_site_log;",
            "",
        ]

        switch site.backend {
        case .php(.nginx, let documentRoot, let socket, let xdebugSocket):
            lines += [
                "    root \(try ConfigText.quoted(documentRoot));",
                "    index index.php index.html index.htm;",
                "    charset utf-8;",
                "",
            ]
            lines += try site.devServer.map(devServerLines) ?? []
            lines += try site.customLines.map { file in ["    include \(try ConfigText.quoted(file));", ""] } ?? []
            lines += [
                "    location / {",
                "        try_files $uri $uri/ /index.php?$query_string;",
                "    }",
                "",
            ]
            lines += site.project == .bedrock ? bedrockRules + [""] : []
            lines += site.isWordPress ? wordPressRules + [""] : []
            lines += site.network == .subfolders ? subfolderNetworkRules(bedrock: site.project == .bedrock) + [""] : []
            let pass = try phpPass(socket: socket, xdebugSocket: xdebugSocket, index: index, share: site.share).target
            lines += [
                "    location ~ \\.php(/|$) {",
                "        fastcgi_split_path_info ^(.+?\\.php)(/.*)$;",
                "        try_files $fastcgi_script_name =404;",
                "        include \(try ConfigText.quoted(settings.runtime.appending(path: "conf/fastcgi.conf")));",
                "        fastcgi_param PATH_INFO $fastcgi_path_info;",
                "        fastcgi_param HTTP_PROXY \"\";",
            ]
            lines += ShareRewrite.fastcgiLines(for: site, index: index).map { "        \($0)" }
            // A request of a public link gives PHP the id of the share block. PHP then uses it as the
            // id of its request (group 4, 4f).
            lines += [
                ShareRequests.fastcgiLine,
                "        fastcgi_pass \(pass);",
                "        fastcgi_read_timeout 300;",
                "    }",
                "",
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
            ]
            lines += waitLocation(on: [502], name: "nexus_php_waits", page: ErrorPages.phpWaits)
        case .php(.apache, _, _, _):
            lines += [
                "    if ($scheme = http) {",
                "        return 301 https://$host\(settings.httpsSuffix)$request_uri;",
                "    }",
                "",
            ]
            lines += try site.devServer.map(devServerLines) ?? []
            lines += [
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
                "",
            ]
            lines += site.isWordPress ? uploadsRule + [""] : []
            let shareHeaders = [
                "        proxy_set_header \(ShareConfig.Header.host.rawValue) \(ShareRewrite.apacheShareHost(for: site, index: index));",
                "        proxy_set_header \(ShareConfig.Header.hide.rawValue) \(ShareRewrite.apacheShareHide(for: site, index: index));",
            ]
            lines += proxyLocation(to: "https://127.0.0.1:\(settings.apachePort)", forwardedPort: ShareRewrite.forwardedPort(for: site, index: index), extra: apacheTLS + shareHeaders)
            lines += waitLocation(on: [502], name: "nexus_apache_waits", page: ErrorPages.apacheWaits)
        case .notice(let title, let text):
            lines += noticePage(title: title, text: text)
        // A dev server serves files in folders with a dot, for example node_modules/.vite. So
        // these sites get no rule for such folders. The client of a dev server reloads the page as
        // soon as nginx answers, also with a 502. So the wait page also covers a 504.
        case .app(_, let framework):
            let forwardedPort = ShareRewrite.forwardedPort(for: site, index: index)
            lines += proxyLocation(to: "http://nexus_app_\(index)", forwardedPort: forwardedPort)

            if framework?.checksOrigin == true {
                lines += [""] + proxyLocation(nextDevPaths, to: "http://nexus_app_\(index)", origin: "$nexus_origin_\(index)", forwardedPort: forwardedPort)
            }

            lines += waitLocation(on: [502, 504], name: "nexus_app_waits", page: ErrorPages.appWaits)
        case .proxy(let address):
            lines += proxyLocation(to: address, forwardedPort: ShareRewrite.forwardedPort(for: site, index: index))
        }

        lines.append("}")
        return lines
    }

    // A PHP file in the uploads must not run. A plugin with a bug can let a visitor upload one
    // (A.0). PHP also runs the file of a path such as /uploads/shell.php/x. So the rule uses the
    // pattern of the PHP location. nginx sits in front of Apache. So an Apache site gets this rule
    // too. The uploads are in /wp-content/uploads, in /app/uploads of Bedrock and in /files of a
    // multisite. A plugin can have a folder files with PHP of its own.
    static let uploadsPattern = "^/(?:wp-content/uploads|app/uploads|(?:[^/]+/)?files)/.+\\.php(/|$)"

    static let uploadsRule = [
        "    location ~* \(uploadsPattern) {",
        "        deny all;",
        "    }",
    ]

    // WordPress links to /wp-admin/. Its pages break without the slash.
    static let wordPressRules = [
        "    location = /wp-admin {",
        "        return 301 /wp-admin/;",
        "    }",
        "",
    ] + uploadsRule

    // Bedrock and Radicle keep WordPress in /wp. Apache gives a request for /wp-login.php to
    // WordPress, which sends it on to /wp. nginx gives a missing PHP file a 404. So nginx sends
    // these files to /wp itself.
    static let bedrockRules = [
        "    rewrite ^/(wp-[^/]+\\.php)$ /wp/$1 last;",
    ]

    // A site of a network in subfolders, such as /blog/, uses the files of WordPress itself. So
    // /blog/wp-login.php and /blog/wp-admin/ go to the files in the root, as the rules of WordPress
    // for nginx do it. Bedrock keeps these files in /wp. A subsite of Bedrock can also name /wp in
    // its URLs, as in /blog/wp/wp-admin/. Only a path that is no file gets a rewrite.
    static func subfolderNetworkRules(bedrock: Bool) -> [String] {
        let core = bedrock ? "/wp" : ""

        return ["    if (!-e $request_filename) {", "        rewrite ^/[^/]+/wp-admin$ $scheme://$http_host$uri/ permanent;"]
            + (bedrock ? ["        rewrite ^/[^/]+/wp(/.*)$ /wp$1 last;"] : [])
            + ["        rewrite ^/[^/]+(/wp-.*)$ \(core)$1 last;", "        rewrite ^/[^/]+(/.*\\.php)$ \(core)$1 last;", "    }"]
    }

    // A page of a Laravel site waits for its dev server (owner, 2026-11-15). Only a request that
    // accepts HTML gets the page, so a fetch or an API client gets the answer of PHP. An Inertia visit
    // and an XHR request also accept HTML, but they are no page loads. Inertia would show the page in
    // its error dialog. So they get the answer of PHP too. nginx checks the files at each request,
    // and nexusd writes the page. So a start or a failure needs no reload. A named location starts
    // after the if lines. So the redirect does not meet them again.
    static func devServerLines(_ files: DevServerFiles) throws -> [String] {
        [
            "    set $nexus_dev_server \"\";",
            "",
            "    if (-f \(try ConfigText.quoted(files.page))) {",
            "        set $nexus_dev_server \"waits\";",
            "    }",
            "",
            "    if ($http_accept !~* \"text/html\") {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if ($http_x_inertia != \"\") {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if ($http_x_requested_with != \"\") {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if (!-d \(try ConfigText.quoted(files.nodeModules))) {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if (-f \(try ConfigText.quoted(files.hotFile))) {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if (-f \(try ConfigText.quoted(files.manifest))) {",
            "        set $nexus_dev_server \"\";",
            "    }",
            "",
            "    if ($nexus_dev_server = \"waits\") {",
            "        return 418;",
            "    }",
            "",
            "    error_page 418 =503 @nexus_dev_server;",
            "",
            "    location @nexus_dev_server {",
            "        root \(try ConfigText.quoted(files.page.deletingLastPathComponent()));",
            "        default_type text/html;",
            "        add_header Cache-Control no-store always;",
            "        add_header Retry-After 1 always;",
            "        rewrite ^ /\(files.page.lastPathComponent) break;",
            "    }",
            "",
        ]
    }

    // nginx reads a $ in the text as a variable. So the text has none.
    static func noticePage(title: String, text: String) -> [String] {
        let escaped = { (value: String) in
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "")
        }

        return [
            "    location / {",
            "        default_type text/html;",
            "        add_header Cache-Control no-store always;",
            "        return 503 \"<!doctype html><meta charset='utf-8'><title>\(escaped(title))</title><h1 style='font-family: -apple-system, sans-serif; font-size: 20px'>\(escaped(title))</h1><p style='font-family: -apple-system, sans-serif'>\(escaped(text))</p>\";",
            "    }",
        ]
    }

    // A backend that does not answer gives a page that tries again each second. So the page of the
    // site comes back without a reload by hand. Only an error of nginx itself gets this page. An
    // error page of the site goes to the browser as it is, because nginx intercepts no errors.
    private static func waitLocation(on codes: [Int], name: String, page: String) -> [String] {
        [
            "",
            "    error_page \(codes.map(String.init).joined(separator: " ")) = @\(name);",
            "",
            "    location @\(name) {",
            "        default_type text/html;",
            "        add_header Cache-Control no-store always;",
            "        add_header Retry-After 1 always;",
            "        return 503 \"\(page)\";",
            "    }",
        ]
    }

    // nginx sends a request to Apache over TLS, with the name of the site for the certificate. So
    // a .htaccess rule that checks %{HTTPS} or %{SERVER_PORT} sees HTTPS, as in production, and
    // does not send each request to https again (D23). Apache cannot tell a request on the HTTP
    // port from one on the HTTPS port. So nginx sends a request on the HTTP port to https first.
    // Otherwise such a rule sends http to https, and the request comes back on http without end.
    private static let apacheTLS = [
        "        proxy_ssl_server_name on;",
        "        proxy_ssl_name $host;",
    ]

    // Next.js refuses another origin on its dev files, its HMR socket and its dev endpoints, also
    // below a base path. A Server Action compares Origin with Host, so the pages of the app keep
    // the origin of the browser. Next.js 16.4 checks the same two names anywhere in the path.
    static let nextDevPaths = "~ /(?:_next|__nextjs)"

    // A request of a public link comes through port 443 of its public host (group 4, 4c). So
    // forwardedPort is a map of the link for a site with a link.
    private static func proxyLocation(_ path: String = "/", to address: String, origin: String? = nil, forwardedPort: String, extra: [String] = []) -> [String] {
        let originLine = origin.map { ["        proxy_set_header Origin \($0);"] } ?? []

        return [
            "    location \(path) {",
            "        proxy_pass \(address);",
            "        proxy_http_version 1.1;",
            "        proxy_set_header Host $http_host;",
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "        proxy_set_header X-Forwarded-Proto $scheme;",
            "        proxy_set_header X-Forwarded-Port \(forwardedPort);",
            "        proxy_set_header Upgrade $http_upgrade;",
            "        proxy_set_header Connection $connection_upgrade;",
            ShareRequests.proxyLine,
        ] + originLine + extra + [
            "        proxy_read_timeout 300;",
            "    }",
        ]
    }
}
