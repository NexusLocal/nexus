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
// serves the nginx sites through php-fpm and sends the Apache sites to Apache (D23, D24).
public enum NginxConfig {
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

        for site in sites {
            lines.append("")
            lines += try server(for: site, settings: settings).map { "    \($0)" }
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func server(for site: WebSite, settings: NginxSettings) throws -> [String] {
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

        switch site.server {
        case .nginx:
            lines += [
                "    root \(try ConfigText.quoted(site.documentRoot));",
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
                "        fastcgi_pass \(try ConfigText.socket(site.phpSocket, prefix: "unix:"));",
                "        fastcgi_read_timeout 300;",
                "    }",
                "",
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
            ]
        case .apache:
            lines += [
                "    location ~ /\\.(?!well-known) {",
                "        deny all;",
                "    }",
                "",
                "    location / {",
                "        proxy_pass http://127.0.0.1:\(settings.apachePort);",
                "        proxy_http_version 1.1;",
                "        proxy_set_header Host $http_host;",
                "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
                "        proxy_set_header X-Forwarded-Proto $scheme;",
                "        proxy_set_header X-Forwarded-Port $server_port;",
                "        proxy_set_header Upgrade $http_upgrade;",
                "        proxy_set_header Connection $connection_upgrade;",
                "        proxy_read_timeout 300;",
                "    }",
            ]
        }

        lines.append("}")
        return lines
    }
}
