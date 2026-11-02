import Foundation
import NexusCore

public struct ApacheSettings: Sendable, Equatable {
    public let port: Int
    public let runtime: URL
    public let runFolder: URL
    public let modules: [String]

    public init(port: Int, runtime: URL, runFolder: URL, modules: [String]) {
        self.port = port
        self.runtime = runtime
        self.runFolder = runFolder
        self.modules = modules
    }
}

// Apache behind nginx. It listens on 127.0.0.1 only, so the access rules of nginx cover it. It
// sets HTTPS=on from X-Forwarded-Proto and takes the client IP from X-Forwarded-For, so PHP
// sees HTTPS and the real client without a change in the application (D23).
public enum ApacheConfig {
    // The modules that Apache needs to work behind nginx. The module toggles cannot remove them.
    public static let requiredModules = [
        "mpm_event", "unixd", "authn_core", "authz_core", "authz_host", "log_config", "mime", "dir",
        "setenvif", "remoteip", "proxy", "proxy_fcgi",
    ]

    public static let defaultModules: Set<String> = [
        "rewrite", "headers", "expires", "alias", "env", "filter", "access_compat", "auth_basic",
        "authn_file", "authz_user", "authz_groupfile", "brotli",
    ]

    // httpd -t accepts auth_form, heartmonitor, proxy_balancer and proxy_hcheck without the modules
    // that they need. Apache then stops at its start.
    public static let dependencies = ToggleDependencies([
        "auth_form": ["request", "session"],
        "cache_disk": ["cache"],
        "cache_socache": ["cache"],
        "dav_fs": ["dav"],
        "dav_lock": ["dav"],
        "heartbeat": ["watchdog"],
        "heartmonitor": ["slotmem_shm", "watchdog"],
        "proxy_balancer": ["slotmem_shm"],
        "proxy_hcheck": ["watchdog"],
        "session_cookie": ["session"],
        "session_crypto": ["session"],
        "session_dbd": ["session"],
    ])

    // Apache loads only one MPM. Nexus uses mpm_event. So the toggles leave out the others.
    public static let otherMPMs: Set<String> = ["mpm_prefork", "mpm_worker"]

    public static func render(sites: [WebSite], settings: ApacheSettings) throws -> String {
        let run = settings.runFolder.appending(path: "apache", directoryHint: .isDirectory)
        var lines = [
            "# Nexus writes this file. Changes are lost at the next change of a site.",
            "ServerRoot \(try ConfigText.quoted(settings.runtime))",
            "Listen 127.0.0.1:\(settings.port)",
            "",
        ]

        for module in requiredModules + settings.modules.filter({ !requiredModules.contains($0) }) {
            lines.append("LoadModule \(module)_module modules/mod_\(module).so")
        }

        lines += [
            "",
            "ServerName localhost",
            "PidFile \(try ConfigText.quoted(run.appending(path: "httpd.pid")))",
            "DefaultRuntimeDir \(try ConfigText.quoted(run))",
            "Mutex \(try ConfigText.quoted(run, prefix: "file:")) default",
            "ErrorLog /dev/stderr",
            "LogLevel warn",
            "TypesConfig \(try ConfigText.quoted(settings.runtime.appending(path: "conf/mime.types")))",
            "DirectoryIndex index.php index.html index.htm",
            "UseCanonicalName Off",
            "Timeout 300",
            "",
            "RemoteIPHeader X-Forwarded-For",
            "RemoteIPInternalProxy 127.0.0.1 ::1",
            "SetEnvIf X-Forwarded-Proto \"^https$\" HTTPS=on",
            "",
            "<Directory />",
            "    AllowOverride None",
            "    Require all denied",
            "</Directory>",
            "",
            "<Files \".ht*\">",
            "    Require all denied",
            "</Files>",
        ]

        for site in sites where site.server == .apache {
            lines += [
                "",
                "<VirtualHost 127.0.0.1:\(settings.port)>",
                "    ServerName \(site.hosts[0])",
            ]

            if site.hosts.count > 1 {
                lines.append("    ServerAlias \(site.hosts.dropFirst().joined(separator: " "))")
            }

            lines += [
                "    DocumentRoot \(try ConfigText.quoted(site.documentRoot))",
                "    <Directory \(try ConfigText.quoted(site.documentRoot))>",
                "        Options FollowSymLinks",
                "        AllowOverride All",
                "        Require all granted",
                "    </Directory>",
                "    <FilesMatch \"\\.php$\">",
                "        SetHandler \(try ConfigText.socket(site.phpSocket, prefix: "proxy:unix:").dropLast())|fcgi://\(site.phpSocket.deletingPathExtension().lastPathComponent)\"",
                "    </FilesMatch>",
                "</VirtualHost>",
            ]
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
