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

    // The modules load in the order of the settings.
    public static func render(sites: [WebSite], settings: NginxSettings) throws -> String {
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
            "        return 404 \"Nexus has no site with this name.\\n\";",
            "    }",
        ]

        for (index, site) in sites.enumerated() {
            lines.append("")
            lines += appUpstream(for: site, index: index, settings: settings).map { "    \($0)" }
            lines += try server(for: site, index: index, settings: settings).map { "    \($0)" }
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // A Node.js app can listen on 127.0.0.1 or on [::1] only, so nginx tries the other address when
    // the first one refuses. The Vite server listens on [::1], so that address comes first for it.
    // Next.js gets the origin of its own address for the origins of the site, and only for these.
    // So an origin of another website stays blocked.
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

    static func origins(of hosts: [String], settings: NginxSettings) -> [String] {
        hosts.flatMap { host in
            [
                settings.httpsPort == 443 ? "https://\(host)" : "https://\(host):\(settings.httpsPort)",
                settings.httpPort == 80 ? "http://\(host)" : "http://\(host):\(settings.httpPort)",
            ]
        }
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
            "    access_log \(try ConfigText.quoted(site.accessLog));",
            "",
        ]

        switch site.backend {
        case .php(.nginx, let documentRoot, let socket):
            lines += [
                "    root \(try ConfigText.quoted(documentRoot));",
                "    index index.php index.html index.htm;",
                "    charset utf-8;",
                "",
                "    location / {",
                "        try_files $uri $uri/ /index.php?$query_string;",
                "    }",
                "",
                "    location ~ \\.php(/|$) {",
                "        fastcgi_split_path_info ^(.+?\\.php)(/.*)$;",
                "        try_files $fastcgi_script_name =404;",
                "        include \(try ConfigText.quoted(settings.runtime.appending(path: "conf/fastcgi.conf")));",
                "        fastcgi_param PATH_INFO $fastcgi_path_info;",
                "        fastcgi_param HTTP_PROXY \"\";",
                "        fastcgi_pass \(try ConfigText.socket(socket, prefix: "unix:"));",
                "        fastcgi_read_timeout 300;",
                "    }",
                "",
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
            ]
        case .php(.apache, _, _):
            lines += [
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
                "",
            ]
            lines += proxyLocation(to: "http://127.0.0.1:\(settings.apachePort)")
        // A dev server serves files in folders with a dot, for example node_modules/.vite. So
        // these sites get no rule for such folders.
        case .app(_, let framework):
            lines += proxyLocation(to: "http://nexus_app_\(index)", origin: framework?.checksOrigin == true ? "$nexus_origin_\(index)" : nil)
            lines += appWaitPage
        case .proxy(let address):
            lines += proxyLocation(to: address)
        }

        lines.append("}")
        return lines
    }

    // A Node.js app does not answer while it starts or after a crash, and Nexus starts it again.
    // The client of a dev server reloads the page as soon as nginx answers, also with a 502. So
    // nginx gives a page that tries again each second, and the page of the app comes back without
    // a reload by hand.
    private static let appWaitPage = [
        "",
        "    error_page 502 504 = @nexus_app_waits;",
        "",
        "    location @nexus_app_waits {",
        "        default_type text/html;",
        "        add_header Cache-Control no-store always;",
        "        add_header Retry-After 1 always;",
        "        return 503 \"<!doctype html><meta http-equiv='refresh' content='1'><title>The app starts</title><p style='font-family: -apple-system, sans-serif'>The app does not answer yet. Nexus starts it, and this page tries again each second. The Site screen of Nexus shows the state and the log of the app.</p>\";",
        "    }",
    ]

    private static func proxyLocation(to address: String, origin: String? = nil) -> [String] {
        let originLine = origin.map { ["        proxy_set_header Origin \($0);"] } ?? []

        return [
            "    location / {",
            "        proxy_pass \(address);",
            "        proxy_http_version 1.1;",
            "        proxy_set_header Host $http_host;",
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "        proxy_set_header X-Forwarded-Proto $scheme;",
            "        proxy_set_header X-Forwarded-Port $server_port;",
            "        proxy_set_header Upgrade $http_upgrade;",
            "        proxy_set_header Connection $connection_upgrade;",
        ] + originLine + [
            "        proxy_read_timeout 300;",
            "    }",
        ]
    }
}
