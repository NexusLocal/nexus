import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct WebConfigTests {
    private let runtime = URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory)
    private let run = URL(filePath: "/Nexus/run", directoryHint: .isDirectory)

    private func site(_ server: WebServer, folder: String = "/Sites/My Shop/public", php: String = "8.5") -> WebSite {
        site(.php(server: server, documentRoot: URL(filePath: folder, directoryHint: .isDirectory), socket: URL(filePath: "/Nexus/run/php-\(php).sock")))
    }

    private func site(_ backend: WebBackend) -> WebSite {
        WebSite(
            hosts: ["shop.test", "www.shop.test"],
            backend: backend,
            certificate: URL(filePath: "/Nexus/certs/shop.test.crt"),
            key: URL(filePath: "/Nexus/certs/shop.test.key"),
            accessLog: URL(filePath: "/Nexus/logs/sites/shop.test.log")
        )
    }

    private func nginxSettings(lan: Bool = false, modules: [String] = []) -> NginxSettings {
        NginxSettings(httpPort: 8080, httpsPort: 8443, apachePort: 8081, lanAccess: lan, runtime: runtime, runFolder: run, modules: modules)
    }

    @Test func anNginxSiteGoesToItsPHPSocket() throws {
        let config = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(config.contains("server_name shop.test www.shop.test;"))
        #expect(config.contains("listen 8443 ssl;"))
        #expect(config.contains("listen [::]:8080;"))
        #expect(config.contains("root \"/Sites/My Shop/public/\";"))
        #expect(config.contains("fastcgi_pass \"unix:/Nexus/run/php-8.5.sock\";"))
        #expect(config.contains("ssl_certificate \"/Nexus/certs/shop.test.crt\";"))
    }

    private func wordPressSite(_ server: WebServer, project: PHPProjectType = .wordpress) -> WebSite {
        let base = site(server)
        return WebSite(hosts: base.hosts, backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog, project: project)
    }

    @Test func bedrockSendsTheFilesOfWordPressToWp() throws {
        let bedrock = try NginxConfig.render(sites: [wordPressSite(.nginx, project: .bedrock)], settings: nginxSettings())
        let classic = try NginxConfig.render(sites: [wordPressSite(.nginx)], settings: nginxSettings())

        #expect(bedrock.contains("rewrite ^/(wp-[^/]+\\.php)$ /wp/$1 last;"))
        #expect(bedrock.contains("location = /wp-admin {"))
        #expect(!classic.contains("rewrite"))
    }

    @Test func aWordPressSiteGetsTheSlashOfWpAdminAndRunsNoPHPInTheUploads() throws {
        let nginx = try NginxConfig.render(sites: [wordPressSite(.nginx)], settings: nginxSettings())
        let apache = try NginxConfig.render(sites: [wordPressSite(.apache)], settings: nginxSettings())
        let other = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())
        let uploads = try #require(nginx.range(of: "location ~* \(NginxConfig.uploadsPattern) {\n            deny all;"))
        let php = try #require(nginx.range(of: "location ~ \\.php(/|$) {"))
        let pattern = try NSRegularExpression(pattern: NginxConfig.uploadsPattern, options: .caseInsensitive)
        let denies = { (path: String) in pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }

        #expect(nginx.contains("location = /wp-admin {\n            return 301 /wp-admin/;"))
        #expect(uploads.lowerBound < php.lowerBound)
        #expect(apache.contains("location ~* \(NginxConfig.uploadsPattern) {"))
        #expect(denies("/wp-content/uploads/shell.php"))
        #expect(denies("/wp-content/uploads/2026/shell.PHP/x"))
        #expect(denies("/app/uploads/shell.php"))
        #expect(denies("/files/shell.php"))
        #expect(denies("/shop/files/2026/shell.php"))
        #expect(!denies("/wp-content/uploads/photo.php.jpg"))
        #expect(!denies("/wp-content/plugins/shop/index.php"))
        #expect(!denies("/wp-content/plugins/shop/files/ajax.php"))
        #expect(!denies("/wp-content/themes/shop/uploads/form.php"))
        #expect(!apache.contains("wp-admin"))
        #expect(!other.contains("uploads"))
    }

    @Test func aNoticeIsAPageWithoutPHP() throws {
        let config = try NginxConfig.render(sites: [site(.notice(title: "This workspace runs no PHP", text: "Nexus cannot isolate \"it\" for $5."))], settings: nginxSettings())

        #expect(config.contains("return 503 \"<!doctype html>"))
        #expect(config.contains("<title>This workspace runs no PHP</title>"))
        #expect(config.contains("Nexus cannot isolate \\\"it\\\" for 5."))
        #expect(!config.contains("fastcgi_pass"))
        #expect(!config.contains("proxy_pass"))
    }

    @Test func anApacheSiteGoesToApacheWithTheForwardedHeaders() throws {
        let config = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())

        #expect(config.contains("proxy_pass http://127.0.0.1:8081;"))
        #expect(config.contains("proxy_set_header X-Forwarded-Proto $scheme;"))
        #expect(config.contains("proxy_set_header Host $http_host;"))
        #expect(config.contains("location ~ /\\.(?!well-known) {\n            deny all;"))
        #expect(config.contains("proxy_redirect http://$http_host/ $scheme://$http_host/;"))
        #expect(!config.contains("fastcgi_pass"))
    }

    @Test func aProxySiteGoesToItsAddressAndKeepsFoldersWithADot() throws {
        let config = try NginxConfig.render(sites: [site(.proxy(address: "http://127.0.0.1:3000"))], settings: nginxSettings())

        #expect(config.contains("proxy_pass http://127.0.0.1:3000;"))
        #expect(config.contains("proxy_set_header Upgrade $http_upgrade;"))
        #expect(config.contains("proxy_set_header Host $http_host;"))
        #expect(!config.contains("location ~ /\\."))
        #expect(!config.contains("fastcgi_pass"))
        #expect(!config.contains("error_page"))
    }

    @Test func aNodeAppGoesToItsUpstreamWithTheOtherAddressAsBackup() throws {
        let config = try NginxConfig.render(sites: [site(.app(port: 20017, framework: .express)), site(.app(port: 20018, framework: .vite))], settings: nginxSettings())

        #expect(config.contains("upstream nexus_app_0 {\n        server 127.0.0.1:20017;\n        server [::1]:20017 backup;\n    }"))
        #expect(config.contains("upstream nexus_app_1 {\n        server [::1]:20018;\n        server 127.0.0.1:20018 backup;\n    }"))
        #expect(config.contains("proxy_pass http://nexus_app_0;"))
        #expect(config.contains("proxy_set_header Connection $connection_upgrade;"))
        #expect(config.contains("error_page 502 504 = @nexus_app_waits;"))
        #expect(config.contains("<meta http-equiv='refresh' content='1'>"))
        #expect(!config.contains("map $http_origin"))
        #expect(!config.contains("location ~ /\\."))
    }

    @Test func nextGetsTheOriginOfItsOwnAddressOnlyForTheOriginsOfTheSite() throws {
        let config = try NginxConfig.render(sites: [site(.app(port: 20019, framework: .next))], settings: nginxSettings())

        #expect(config.contains("map $http_origin $nexus_origin_0 {\n        default $http_origin;\n        \"https://shop.test:8443\" \"http://localhost:20019\";\n        \"http://shop.test:8080\" \"http://localhost:20019\";\n        \"https://www.shop.test:8443\" \"http://localhost:20019\";"))
        #expect(config.contains("proxy_set_header Origin $nexus_origin_0;"))
    }

    @Test func standardPortsGiveOriginsWithoutAPort() {
        let settings = NginxSettings(httpPort: 80, httpsPort: 443, apachePort: 8081, lanAccess: false, runtime: runtime, runFolder: run, modules: [])

        #expect(NginxConfig.origins(of: ["shop.test"], settings: settings) == ["https://shop.test", "http://shop.test"])
    }

    @Test func aSiteOfANetworkInSubfoldersUsesTheFilesOfWordPress() throws {
        let base = site(.nginx)
        let network = { (project: PHPProjectType) in
            WebSite(hosts: base.hosts, backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog, project: project, network: .subfolders)
        }
        let classic = try NginxConfig.render(sites: [network(.wordpress)], settings: nginxSettings())
        let bedrock = try NginxConfig.render(sites: [network(.bedrock)], settings: nginxSettings())

        #expect(classic.contains("if (!-e $request_filename) {\n            rewrite ^/[^/]+/wp-admin$ $scheme://$http_host$uri/ permanent;\n            rewrite ^/[^/]+(/wp-.*)$ $1 last;\n            rewrite ^/[^/]+(/.*\\.php)$ $1 last;\n        }"))
        #expect(bedrock.contains("rewrite ^/[^/]+/wp(/.*)$ /wp$1 last;\n            rewrite ^/[^/]+(/wp-.*)$ /wp$1 last;"))
    }

    @Test func aNameWithAStarGivesAnOriginForEachNameBelowIt() {
        #expect(NginxConfig.origins(of: ["*.shop.test"], settings: nginxSettings()) == ["~^https://[^./]+\\.shop\\.test:8443$", "~^http://[^./]+\\.shop\\.test:8080$"])
    }

    @Test func apacheTakesASiteWithAStarNameLast() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])
        let base = site(.apache)
        let network = WebSite(hosts: ["shop.test", "*.shop.test"], backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog)
        let below = WebSite(hosts: ["zz.shop.test"], backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog)

        let config = try ApacheConfig.render(sites: [network, below], settings: settings)

        let first = try #require(config.range(of: "ServerName zz.shop.test"))
        let second = try #require(config.range(of: "ServerName shop.test"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(config.contains("ServerAlias *.shop.test"))
    }

    @Test func apacheGetsNoProxySite() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])

        let config = try ApacheConfig.render(sites: [site(.proxy(address: "http://127.0.0.1:3000"))], settings: settings)

        #expect(!config.contains("<VirtualHost"))
    }

    @Test func onlyThisMacHasAccessUntilTheLANSettingIsOn() throws {
        let closed = try NginxConfig.render(sites: [], settings: nginxSettings())
        let open = try NginxConfig.render(sites: [], settings: nginxSettings(lan: true))

        #expect(closed.contains("allow 127.0.0.1;\n    allow ::1;\n    deny all;"))
        #expect(!open.contains("deny all;"))
    }

    @Test func aTurnedOnModuleIsLoaded() throws {
        let config = try NginxConfig.render(sites: [], settings: nginxSettings(modules: ["ngx_http_brotli_filter_module"]))

        #expect(config.hasPrefix("# Nexus writes this file. Changes are lost at the next change of a site.\nload_module \"/Nexus/runtimes/nginx/1.30/modules/ngx_http_brotli_filter_module.so\";"))
    }

    @Test func aFolderThatCanBreakTheConfigurationIsRefused() {
        for folder in ["/Sites/$host/public", "/Sites/a\"b", "/Sites/a;b", "/Sites/a\nb", "/Sites/shop [old]", "/Sites/a*b"] {
            #expect(throws: ConfigError.self) {
                try NginxConfig.render(sites: [site(.nginx, folder: folder)], settings: nginxSettings())
            }
        }
    }

    @Test func aSocketPathLongerThanMacOSPermitsIsRefused() {
        let long = site(.php(server: .nginx, documentRoot: URL(filePath: "/Sites/shop"), socket: URL(filePath: "/" + String(repeating: "a", count: 110) + ".sock")))

        #expect(throws: ConfigError.self) {
            try NginxConfig.render(sites: [long], settings: nginxSettings())
        }
    }

    @Test func apacheSetsHTTPSFromTheProxyAndSendsPHPToTheSocket() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: ["rewrite", "proxy"])

        let config = try ApacheConfig.render(sites: [site(.apache, php: "8.4"), site(.nginx)], settings: settings)

        #expect(config.contains("Listen 127.0.0.1:8081"))
        #expect(config.contains("SetEnvIf X-Forwarded-Proto \"^https$\" HTTPS=on"))
        #expect(config.contains("RemoteIPInternalProxy 127.0.0.1 ::1"))
        #expect(config.contains("SetHandler \"proxy:unix:/Nexus/run/php-8.4.sock|fcgi://php-8.4\""))
        #expect(config.contains("ServerAlias www.shop.test"))
        #expect(config.components(separatedBy: "<VirtualHost").count == 2)
        #expect(config.components(separatedBy: "LoadModule proxy_module").count == 2)
    }

    @Test func redisLoadsAfterIgbinary() {
        let loaded = PHPConfig.extensionsToLoad(enabled: ["redis", "xdebug", "apcu"], available: ["redis", "igbinary", "xdebug", "apcu", "pcov"])

        #expect(loaded == ["igbinary", "apcu", "redis", "xdebug"])
    }

    @Test func redisDoesNotLoadWithoutIgbinary() {
        let loaded = PHPConfig.extensionsToLoad(enabled: ["redis", "apcu"], available: ["redis", "apcu"])

        #expect(loaded == ["apcu"])
    }

    @Test func xdebugIsAZendExtensionThatStartsOnATrigger() throws {
        let ini = try PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext", directoryHint: .isDirectory), extensions: ["apcu", "xdebug"])

        #expect(ini.contains("extension = apcu\n"))
        #expect(ini.contains("zend_extension = xdebug\n"))
        #expect(ini.contains("xdebug.start_with_request = trigger"))
    }

    @Test func mailOfPHPGoesToNexusSendmailWithThePathInSingleQuotes() throws {
        let lines = try PHPConfig.mailLines(command: URL(filePath: "/Users/me/Library/Application Support/Nexus/bin/nexus"), smtpPort: 11025)
        let ini = try PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext", directoryHint: .isDirectory), extensions: [], mailLines: lines)

        #expect(lines == [
            "sendmail_path = \"'/Users/me/Library/Application Support/Nexus/bin/nexus' sendmail -S 127.0.0.1:11025 -t -i\"",
            "mail.add_x_header = On",
        ])
        #expect(ini.contains("\(lines[0])\n"))
        #expect(throws: ConfigError.self) {
            try PHPConfig.mailLines(command: URL(filePath: "/Users/o'brien/nexus"), smtpPort: 1025)
        }
    }

    @Test func theFPMPoolListensOnASocketThatOnlyTheUserCanUse() throws {
        let config = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/php-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/php-8.5.pid"))

        #expect(config.contains("listen = \"/Nexus/run/php-8.5.sock\""))
        #expect(config.contains("listen.mode = 0600"))
        #expect(config.contains("daemonize = no"))
    }

    @Test func aModuleThatAnotherModuleNeedsLoadsFirst() {
        let apache = ApacheConfig.dependencies.loadOrder(["heartbeat", "rewrite"], available: ["heartbeat", "watchdog", "rewrite"])
        let nginx = NginxConfig.dependencies.loadOrder(["ngx_stream_js_module", "ngx_http_js_module"], available: ["ngx_stream_js_module", "ngx_stream_module", "ngx_http_js_module"])

        #expect(apache == ["watchdog", "heartbeat", "rewrite"])
        #expect(nginx == ["ngx_stream_module", "ngx_http_js_module", "ngx_stream_js_module"])
    }

    @Test func onTurnsOnWhatANameNeedsAndOffTurnsOffWhatNeedsIt() {
        let on = ApacheConfig.dependencies.set("dav_fs", on: true, in: ["rewrite"])
        let off = ApacheConfig.dependencies.set("dav", on: false, in: ["rewrite", "dav", "dav_fs", "dav_lock"])

        #expect(on.enabled == ["rewrite", "dav", "dav_fs"])
        #expect(on.changed == ["dav_fs", "dav"])
        #expect(off.enabled == ["rewrite"])
        #expect(off.changed == ["dav", "dav_fs", "dav_lock"])
    }

    @Test func theModulesThatApacheChecksOnlyAtItsStartNeedTheirProviders() {
        let balancer = ApacheConfig.dependencies.set("proxy_balancer", on: true, in: [])
        let monitor = ApacheConfig.dependencies.loadOrder(["heartmonitor"], available: ["heartmonitor", "slotmem_shm", "watchdog"])

        #expect(balancer.enabled == ["proxy_balancer", "slotmem_shm"])
        #expect(monitor == ["slotmem_shm", "watchdog", "heartmonitor"])
        #expect(ApacheConfig.dependencies.missing(for: "auth_form", available: ["auth_form", "session"]) == ["request"])
        #expect(ApacheConfig.dependencies.missing(for: "rewrite", available: ["rewrite"]).isEmpty)
    }

    @Test func theCustomFileStartsWithOneCommentLine() {
        let ini = PHPConfig.customIni(lines: ["memory_limit = 512M", "max_execution_time = 120"])

        #expect(ini.split(separator: "\n").count == PHPConfig.customIniHeaderLines + 2)
        #expect(ini.hasPrefix(";"))
        #expect(ini.hasSuffix("max_execution_time = 120\n"))
    }

    @Test func aSyntaxErrorNamesItsFileAndLine() {
        let message = PHPStartupMessage("PHP:  syntax error, unexpected '=' in /Nexus/run/php-8.4-check/99-custom.ini on line 4")

        #expect(message == PHPStartupMessage(text: "syntax error, unexpected '='", file: "/Nexus/run/php-8.4-check/99-custom.ini", line: 4))
    }

    @Test func aWarningAtTheStartHasNoFileAndNoLine() {
        let quantity = PHPStartupMessage(#"Warning: Invalid "memory_limit" setting. Invalid quantity "abc": no valid leading digits in Unknown on line 0"#)
        let library = PHPStartupMessage("PHP Warning:  PHP Startup: Unable to load dynamic library 'nothere' (tried: /a/nothere (no such file)) in Unknown on line 0")

        #expect(quantity == PHPStartupMessage(text: #"Invalid "memory_limit" setting. Invalid quantity "abc": no valid leading digits"#, file: nil, line: nil))
        #expect(library == PHPStartupMessage(text: "Unable to load dynamic library 'nothere'", file: nil, line: nil))
    }

    @Test func onlyTheMessagesThatTheBaselineDoesNotHaveAreNew() {
        let baseline = "Warning: Module \"redis\" is already loaded in Unknown on line 0\n"
        let output = "\nWarning: Module \"redis\" is already loaded in Unknown on line 0\nWarning: Module \"redis\" is already loaded in Unknown on line 0\n"

        let messages = PHPConfig.newStartupMessages(in: output, baseline: baseline)

        #expect(messages.map(\.text) == [#"Module "redis" is already loaded"#])
    }
}
