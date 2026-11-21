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

    @Test func anApacheSiteGoesToApacheOverTLSWithTheNameOfTheSite() throws {
        let config = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())

        #expect(config.contains("proxy_pass https://127.0.0.1:8081;"))
        #expect(config.contains("proxy_ssl_server_name on;"))
        #expect(config.contains("proxy_ssl_name $host;"))
        #expect(config.contains("proxy_set_header X-Forwarded-Proto $scheme;"))
        #expect(config.contains("proxy_set_header Host $http_host;"))
        #expect(config.contains("location ~ /\\.(?!well-known) {\n            deny all;"))
        #expect(!config.contains("proxy_redirect"))
        #expect(!config.contains("fastcgi_pass"))
    }

    @Test func aRequestOnTheHTTPPortOfAnApacheSiteGoesToHTTPSFirst() throws {
        let development = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())
        let standard = try NginxConfig.render(sites: [site(.apache)], settings: NginxSettings(httpPort: 80, httpsPort: 443, apachePort: 8081, lanAccess: false, runtime: runtime, runFolder: run, modules: []))

        #expect(development.contains("if ($scheme = http) {\n            return 301 https://$host:8443$request_uri;\n        }"))
        #expect(standard.contains("return 301 https://$host$request_uri;"))
    }

    @Test func aRequestOnTheHTTPPortOfAnNginxSiteStaysOnHTTP() throws {
        let config = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(!config.contains("if ($scheme = http)"))
    }

    @Test func onlyAnApacheSiteGoesOverTLSToItsServer() throws {
        let config = try NginxConfig.render(sites: [site(.proxy(address: "http://127.0.0.1:3000"))], settings: nginxSettings())

        #expect(!config.contains("proxy_ssl_server_name"))
        #expect(!config.contains("if ($scheme = http)"))
    }

    @Test func aProxySiteGoesToItsAddressAndKeepsFoldersWithADot() throws {
        let config = try NginxConfig.render(sites: [site(.proxy(address: "http://127.0.0.1:3000"))], settings: nginxSettings())

        #expect(config.contains("proxy_pass http://127.0.0.1:3000;"))
        #expect(config.contains("proxy_set_header Upgrade $http_upgrade;"))
        #expect(config.contains("proxy_set_header Host $http_host;"))
        #expect(!config.contains("location ~ /\\."))
        #expect(!config.contains("fastcgi_pass"))
        #expect(!config.contains("error_page 502"))
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

    private func location(_ path: String, in config: String) throws -> Substring {
        let site = try #require(config.range(of: "server_name shop.test www.shop.test;"))
        let start = try #require(config.range(of: "        location \(path) {\n", range: site.upperBound..<config.endIndex))
        let end = try #require(config.range(of: "\n        }\n", range: start.upperBound..<config.endIndex))
        return config[start.lowerBound..<end.upperBound]
    }

    @Test func thePagesOfNextKeepTheOriginOfTheBrowserSoAServerActionMatchesTheHost() throws {
        let config = try NginxConfig.render(sites: [site(.app(port: 20019, framework: .next))], settings: nginxSettings())
        let pages = try location("/", in: config)
        let devPaths = try location(NginxConfig.nextDevPaths, in: config)

        #expect(!pages.contains("Origin"))
        #expect(pages.contains("proxy_pass http://nexus_app_0;"))
        #expect(devPaths.contains("proxy_set_header Origin $nexus_origin_0;"))
        #expect(devPaths.contains("proxy_pass http://nexus_app_0;"))
        #expect(devPaths.contains("proxy_set_header Host $http_host;"))
        #expect(devPaths.contains("proxy_set_header Upgrade $http_upgrade;"))
        #expect(devPaths.contains("proxy_set_header Connection $connection_upgrade;"))
        #expect(devPaths.contains("proxy_set_header X-Forwarded-Port $server_port;"))
        #expect(devPaths.contains("proxy_read_timeout 300;"))
        #expect(config.components(separatedBy: "error_page 502 504 = @nexus_app_waits;").count == 2)
    }

    @Test func theDevPathsOfNextAreItsFilesItsSocketAndItsEndpointsAlsoBelowABasePath() throws {
        let pattern = try NSRegularExpression(pattern: String(NginxConfig.nextDevPaths.dropFirst(2)))
        let matches = { (path: String) in pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }

        #expect(NginxConfig.nextDevPaths.hasPrefix("~ /"))
        #expect(matches("/_next/static/chunks/main.js"))
        #expect(matches("/_next/webpack-hmr"))
        #expect(matches("/__nextjs_original-stack-frames"))
        #expect(matches("/__nextjs_devtools_config"))
        #expect(matches("/docs/_next/webpack-hmr"))
        #expect(!matches("/"))
        #expect(!matches("/checkout"))
        #expect(!matches("/api/next"))
        #expect(!matches("/next/page"))
    }

    @Test func onlyNextGetsALocationForItsDevPaths() throws {
        let config = try NginxConfig.render(sites: [site(.app(port: 20017, framework: .express)), site(.app(port: 20018, framework: .vite)), site(.proxy(address: "http://127.0.0.1:3000"))], settings: nginxSettings())

        #expect(!config.contains("location \(NginxConfig.nextDevPaths)"))
        #expect(!config.contains("proxy_set_header Origin"))
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

    @Test func anUnknownNameGetsThePageWithTheSitesAndANotFoundStatus() throws {
        let config = try NginxConfig.render(sites: [], settings: nginxSettings())

        #expect(config.contains("ssl_reject_handshake on;\n        root \"/Nexus/run/nginx/pages/\";\n        error_page 404 /unknown-site.html;"))
        #expect(config.contains("location / {\n            return 404;\n        }"))
        #expect(config.contains("location = /unknown-site.html {\n            internal;"))
        #expect(!config.contains("Nexus has no site with this name.\\n"))
    }

    @Test func thePageForAnUnknownNameLinksEachSiteOnce() {
        let page = ErrorPages.unknownSite(hosts: ["shop.test", "blog.test", "*.network.test", "shop.test", "<b>.test"], httpsPort: 8443)

        #expect(page.contains("<li><a href='https://blog.test:8443/'>blog.test</a></li>\n<li><a href='https://shop.test:8443/'>shop.test</a></li>"))
        #expect(page.components(separatedBy: "https://shop.test").count == 2)
        #expect(!page.contains("network.test"))
        #expect(page.contains("&lt;b&gt;.test"))
        #expect(!page.contains("<b>.test"))
        #expect(page.contains("textContent = location.hostname"))
    }

    @Test func thePageForAnUnknownNameLinksWithoutThePort443() {
        let page = ErrorPages.unknownSite(hosts: ["shop.test"], httpsPort: 443)

        #expect(page.contains("<a href='https://shop.test/'>shop.test</a>"))
    }

    @Test func thePageForAnUnknownNameWithoutSitesSaysHowToAddOne() {
        let page = ErrorPages.unknownSite(hosts: [], httpsPort: 443)

        #expect(page.contains("Nexus has no sites yet."))
        #expect(!page.contains("<ul>"))
    }

    @Test func anNginxSiteGetsAWaitPageWhilePHPDoesNotAnswer() throws {
        let config = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(config.contains("error_page 502 = @nexus_php_waits;"))
        #expect(config.contains("location @nexus_php_waits {"))
        #expect(config.contains("return 503 \"<!doctype html><meta charset='utf-8'><meta http-equiv='refresh' content='1'><title>PHP starts</title>"))
        #expect(!config.contains("error_page 502 504 = @nexus_php_waits;"))
    }

    @Test func anApacheSiteGetsAWaitPageWhileApacheOrPHPDoesNotAnswer() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])

        let nginx = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())
        let apache = try ApacheConfig.render(sites: [site(.apache)], settings: settings)

        #expect(nginx.contains("error_page 502 = @nexus_apache_waits;"))
        #expect(nginx.contains("<title>Apache starts</title>"))
        #expect(apache.contains("fcgi://php-8.5\"\n        ErrorDocument 503 \"<!doctype html><meta charset='utf-8'><meta http-equiv='refresh' content='1'><title>PHP starts</title>"))
    }

    @Test func theWaitPagesHaveNoCharacterThatTheServersReadInASpecialWay() {
        for page in [ErrorPages.phpWaits, ErrorPages.apacheWaits, ErrorPages.appWaits] {
            #expect(!page.contains("\""))
            #expect(!page.contains("$"))
            #expect(!page.contains("%"))
            #expect(!page.contains("\\"))
            #expect(page.unicodeScalars.allSatisfy { $0.isASCII })
        }
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

        #expect(throws: SocketError.pathTooLong("/" + String(repeating: "a", count: 110) + ".sock")) {
            try NginxConfig.render(sites: [long], settings: nginxSettings())
        }
    }

    @Test func apacheGetsTLSWithTheCertificateOfEachSiteAndSendsPHPToTheSocket() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: ["rewrite", "proxy"])

        let config = try ApacheConfig.render(sites: [site(.apache, php: "8.4"), site(.nginx)], settings: settings)

        #expect(config.contains("Listen 127.0.0.1:8081 https"))
        #expect(config.contains("LoadModule ssl_module modules/mod_ssl.so"))
        #expect(config.contains("    SSLEngine on\n    SSLCertificateFile \"/Nexus/certs/shop.test.crt\"\n    SSLCertificateKeyFile \"/Nexus/certs/shop.test.key\""))
        #expect(!config.contains("X-Forwarded-Proto"))
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

    @Test func confDNeverLoadsXdebugAndHoldsItsSettings() throws {
        let extensions = PHPConfig.confDExtensions(enabled: ["apcu", "xdebug"], available: ["apcu", "xdebug"])
        let ini = try PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext", directoryHint: .isDirectory), extensions: extensions, xdebugSettings: true)
        let withoutSettings = try PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext", directoryHint: .isDirectory), extensions: extensions)

        #expect(extensions == ["apcu"])
        #expect(ini.contains("extension = apcu\n"))
        #expect(!ini.contains("zend_extension = xdebug"))
        #expect(ini.contains("xdebug.mode = debug,develop\nxdebug.start_with_request = trigger\nxdebug.client_port = 9003\n"))
        #expect(!withoutSettings.contains("xdebug."))
        #expect(!withoutSettings.contains("zend_extension = xdebug"))
    }

    private func debugSite(_ server: WebServer, php: String) -> WebSite {
        site(.php(
            server: server,
            documentRoot: URL(filePath: "/Sites/My Shop/public", directoryHint: .isDirectory),
            socket: URL(filePath: "/Nexus/run/php-\(php).sock"),
            xdebugSocket: URL(filePath: "/Nexus/run/xdebug-\(php).sock")
        ))
    }

    @Test func thePoolWithXdebugStartsAProcessOnlyForARequest() throws {
        let debug = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/xdebug-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/xdebug-8.5.pid"), xdebug: true)
        let normal = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/php-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/php-8.5.pid"), xdebug: false)

        #expect(debug.contains("[nexus-xdebug]\n"))
        #expect(debug.contains("listen = \"/Nexus/run/xdebug-8.5.sock\"\n"))
        #expect(debug.contains("listen.mode = 0600\n"))
        #expect(debug.contains("\npm = ondemand\n"))
        #expect(debug.contains("\npm.process_idle_timeout = 60s\n"))
        #expect(!debug.contains("pm.start_servers"))
        #expect(normal.contains("[nexus]\n"))
        #expect(normal.contains("\npm = dynamic\n"))
    }

    @Test func aDebugRequestOfAnNginxSiteGoesToTheSocketWithXdebug() throws {
        let config = try NginxConfig.render(sites: [debugSite(.nginx, php: "8.5")], settings: nginxSettings())

        #expect(config.contains(#"""
                map $http_cookie $nexus_xdebug_cookie {
                    default 0;
                    "~(^|;)\s*XDEBUG_(SESSION|TRIGGER)=" 1;
                }

                map $args $nexus_xdebug {
                    default $nexus_xdebug_cookie;
                    "~(^|&)XDEBUG_(SESSION|SESSION_START|TRIGGER)(=|&|$)" 1;
                }

            """#))
        #expect(config.contains("    map $nexus_xdebug $nexus_php_0 {\n"))
        #expect(config.contains("        default \"unix:/Nexus/run/php-8.5.sock\";\n"))
        #expect(config.contains("        1 \"unix:/Nexus/run/xdebug-8.5.sock\";\n"))
        #expect(config.contains("fastcgi_pass $nexus_php_0;"))
        #expect(!config.contains("fastcgi_pass \"unix:"))
    }

    @Test func aSiteWithoutXdebugKeepsOneSocketAndNoMap() throws {
        let config = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(!config.contains("$nexus_xdebug"))
        #expect(!config.contains("$nexus_php_"))
        #expect(config.contains("fastcgi_pass \"unix:/Nexus/run/php-8.5.sock\";"))
    }

    @Test func anApacheSiteSendsADebugRequestToTheSocketWithXdebug() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])

        let apache = try ApacheConfig.render(sites: [debugSite(.apache, php: "8.4")], settings: settings)
        let nginx = try NginxConfig.render(sites: [debugSite(.apache, php: "8.4")], settings: nginxSettings())
        let plain = try ApacheConfig.render(sites: [site(.apache, php: "8.4")], settings: settings)

        #expect(apache.contains("""
                <FilesMatch "\\.php$">
                    <If "\(ApacheConfig.xdebugCondition)">
                        SetHandler "proxy:unix:/Nexus/run/xdebug-8.4.sock|fcgi://xdebug-8.4"
                    </If>
                    <Else>
                        SetHandler "proxy:unix:/Nexus/run/php-8.4.sock|fcgi://php-8.4"
                    </Else>
                    ErrorDocument 503
            """))
        #expect(!nginx.contains("$nexus_xdebug"))
        #expect(!plain.contains("<If"))
        #expect(plain.contains("    <FilesMatch \"\\.php$\">\n        SetHandler \"proxy:unix:/Nexus/run/php-8.4.sock|fcgi://php-8.4\"\n        ErrorDocument 503"))
    }

    private func linkedSite(_ server: WebServer = .nginx, xdebug: Bool, shareSocket: Bool = true) -> WebSite {
        let base = xdebug ? debugSite(server, php: "8.5") : site(server)
        let share = SiteShare(id: "0123456789abcdef0123456789abcdef", fastcgiValues: ["APP_DEBUG": "false"], shareSocket: shareSocket ? URL(filePath: "/Nexus/run/php-share-8.5.sock") : nil)

        return WebSite(hosts: base.hosts, backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog, share: share)
    }

    @Test func aRequestOfALinkWithHiddenErrorsGoesToThePoolOfTheLinks() throws {
        let config = try NginxConfig.render(sites: [linkedSite(xdebug: false)], settings: nginxSettings())

        #expect(config.contains("""
                map $nexus_share $nexus_php_0 {
                    default "unix:/Nexus/run/php-8.5.sock";
                    "0123456789abcdef0123456789abcdef" "unix:/Nexus/run/php-share-8.5.sock";
                }
            """))
        #expect(config.contains("fastcgi_pass $nexus_php_0;"))
        #expect(!config.contains("fastcgi_pass \"unix:"))
    }

    @Test func aRequestOfALinkNeverReachesXdebugAndADebugRequestOfThisMacStillDoes() throws {
        let config = try NginxConfig.render(sites: [linkedSite(xdebug: true)], settings: nginxSettings())

        #expect(config.contains("""
                map "$nexus_share|$nexus_xdebug" $nexus_php_0 {
                    default "unix:/Nexus/run/php-8.5.sock";
                    "|1" "unix:/Nexus/run/xdebug-8.5.sock";
                    "0123456789abcdef0123456789abcdef|0" "unix:/Nexus/run/php-share-8.5.sock";
                    "0123456789abcdef0123456789abcdef|1" "unix:/Nexus/run/php-share-8.5.sock";
                }
            """))
        #expect(config.contains("fastcgi_pass $nexus_php_0;"))
    }

    @Test func aLinkWithoutThePoolKeepsTheMapOfToday() throws {
        let linked = try NginxConfig.render(sites: [linkedSite(xdebug: true, shareSocket: false)], settings: nginxSettings())
        let plain = try NginxConfig.render(sites: [debugSite(.nginx, php: "8.5")], settings: nginxSettings())
        let withoutXdebug = try NginxConfig.render(sites: [linkedSite(xdebug: false, shareSocket: false)], settings: nginxSettings())
        let today = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(phpSocketLines(of: linked) == phpSocketLines(of: plain))
        #expect(phpSocketLines(of: withoutXdebug) == phpSocketLines(of: today))
        #expect(phpSocketLines(of: linked).contains { $0.contains("xdebug-8.5.sock") })
    }

    private func phpSocketLines(of config: String) -> [String] {
        config.split(separator: "\n").map(String.init).filter { $0.contains("nexus_php_") || $0.contains("fastcgi_pass") || $0.contains(".sock") }
    }

    @Test func anApacheSiteSendsARequestOfALinkWithHiddenErrorsToThePoolOfTheLinksFirst() throws {
        let settings = ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])

        let linked = try ApacheConfig.render(sites: [linkedSite(.apache, xdebug: true)], settings: settings)
        let withoutPool = try ApacheConfig.render(sites: [linkedSite(.apache, xdebug: true, shareSocket: false)], settings: settings)
        let plain = try ApacheConfig.render(sites: [debugSite(.apache, php: "8.5")], settings: settings)

        #expect(linked.contains("""
                <FilesMatch "\\.php$">
                    <If "%{HTTP:X-Nexus-Share-Hide} == '1'">
                        SetHandler "proxy:unix:/Nexus/run/php-share-8.5.sock|fcgi://php-share-8.5"
                    </If>
                    <ElseIf "\(ApacheConfig.xdebugCondition)">
                        SetHandler "proxy:unix:/Nexus/run/xdebug-8.5.sock|fcgi://xdebug-8.5"
                    </ElseIf>
                    <Else>
                        SetHandler "proxy:unix:/Nexus/run/php-8.5.sock|fcgi://php-8.5"
                    </Else>
            """))
        #expect(withoutPool == plain)
        #expect(plain.contains("SetEnvIf X-Nexus-Share-Hide \"^1$\" APP_CONFIG_CACHE=/dev/null/nexus-share-config.php APP_DEBUG=false CLOCKWORK_ENABLE=false DEBUGBAR_ENABLED=false NEXUS_SHARE_HIDE_DUMPS=1\n"))
    }

    @Test func nginxMarksOnlyARequestOfALinkWithHiddenErrorsForApache() throws {
        let linked = try NginxConfig.render(sites: [linkedSite(.apache, xdebug: false)], settings: nginxSettings())
        let withoutPool = try NginxConfig.render(sites: [linkedSite(.apache, xdebug: false, shareSocket: false)], settings: nginxSettings())
        let plain = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())

        #expect(linked.contains("    map $nexus_share $nexus_share_0_hide {\n        default \"\";\n        \"0123456789abcdef0123456789abcdef\" \"1\";\n    }"))
        #expect(linked.contains("proxy_set_header X-Nexus-Share-Hide $nexus_share_0_hide;"))
        #expect(withoutPool.contains("proxy_set_header X-Nexus-Share-Hide \"\";"))
        #expect(!withoutPool.contains("$nexus_share_0_hide"))
        #expect(plain.contains("proxy_set_header X-Nexus-Share-Hide \"\";"))
    }

    @Test func thePoolOfTheLinksHidesErrorsStartsAProcessOnlyForARequestAndKeepsTheStub() throws {
        let stub = URL(filePath: "/Nexus/config/php/8.5/nexus-prepend.php")
        let prepend = "php_value[auto_prepend_file] = \"/Nexus/config/php/8.5/nexus-prepend.php\"\n"
        let config = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/php-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/php-8.5.pid"), prepend: stub, shareSocket: URL(filePath: "/Nexus/run/php-share-8.5.sock"))
        let withXdebug = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/php-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/php-8.5.pid"), prepend: stub, shareSocket: URL(filePath: "/Nexus/run/php-share-8.5.sock"), phpIniLoadsXdebug: true)
        let debugPool = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/xdebug-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/xdebug-8.5.pid"), prepend: stub, xdebug: true, shareSocket: URL(filePath: "/Nexus/run/php-share-8.5.sock"))
        let share = try #require(config.range(of: "[nexus-share]\n")).upperBound

        #expect(config[share...].hasPrefix("""
            listen = "/Nexus/run/php-share-8.5.sock"
            listen.mode = 0600
            pm = ondemand
            pm.max_children = 10
            pm.process_idle_timeout = 60s
            catch_workers_output = yes
            decorate_workers_output = no
            clear_env = no
            php_admin_value[display_errors] = Off
            php_admin_value[display_startup_errors] = Off

            """))
        #expect(config.components(separatedBy: prepend).count == 3)
        #expect(config.hasSuffix(prepend))
        #expect(!config.contains("xdebug.start_with_request"))
        #expect(withXdebug.contains("php_admin_value[display_startup_errors] = Off\nphp_admin_value[xdebug.start_with_request] = \"no\"\n\(prepend)"))
        #expect(withXdebug.hasSuffix(prepend))
        #expect(!debugPool.contains("[nexus-share]"))
    }

    @Test func aLineThatLoadsXdebugIsFound() {
        #expect(PHPConfig.userLoadsXdebug(phpIni: "memory_limit = 1G\nzend_extension = xdebug\n", customLines: []))
        #expect(PHPConfig.userLoadsXdebug(phpIni: "zend_extension=\"/opt/lib/xdebug.so\"", customLines: []))
        #expect(PHPConfig.userLoadsXdebug(phpIni: "", customLines: ["zend_extension=xdebug"]))
        #expect(!PHPConfig.userLoadsXdebug(phpIni: "; zend_extension = xdebug", customLines: []))
        #expect(!PHPConfig.userLoadsXdebug(phpIni: "extension = xdebug", customLines: []))
        #expect(!PHPConfig.userLoadsXdebug(phpIni: "zend_extension = opcache", customLines: []))
        #expect(PHPConfig.xdebugIni(loadsExtension: true).contains("\nzend_extension = xdebug\n"))
        #expect(!PHPConfig.xdebugIni(loadsExtension: false).contains("zend_extension"))
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

    @Test func pcovLoadsWithoutCoverageAndItsFolderTurnsItOn() throws {
        let ini = try PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext"), extensions: ["opcache", "pcov"])

        #expect(ini.contains("extension = pcov\npcov.enabled = 0\n"))
        #expect(try !PHPConfig.nexusIni(extensionDirectory: URL(filePath: "/ext"), extensions: ["opcache"]).contains("pcov"))
        #expect(PHPConfig.coverageIni.contains("\npcov.enabled = 1\n"))
        #expect(PHPConfig.defaultExtensions.contains("pcov"))
    }

    @Test func theFPMPoolListensOnASocketThatOnlyTheUserCanUse() throws {
        let config = try PHPConfig.fpmConfig(socket: URL(filePath: "/Nexus/run/php-8.5.sock"), pidFile: URL(filePath: "/Nexus/run/php-8.5.pid"))

        #expect(config.contains("listen = \"/Nexus/run/php-8.5.sock\""))
        #expect(config.contains("listen.mode = 0600"))
        #expect(config.contains("daemonize = no"))
    }

    @Test func thePoolNamesTheStubOfTheDumpViewerOnlyWhenNexusGivesOne() throws {
        let socket = URL(filePath: "/Nexus/run/php-8.5.sock")
        let pidFile = URL(filePath: "/Nexus/run/php-8.5.pid")
        let stub = URL(filePath: "/Nexus/config/php/8.5/nexus-prepend.php")

        let without = try PHPConfig.fpmConfig(socket: socket, pidFile: pidFile)
        let with = try PHPConfig.fpmConfig(socket: socket, pidFile: pidFile, prepend: stub)

        #expect(!without.contains("auto_prepend_file"))
        #expect(with == without + "php_value[auto_prepend_file] = \"/Nexus/config/php/8.5/nexus-prepend.php\"\n")
        #expect(throws: ConfigError.self) {
            try PHPConfig.fpmConfig(socket: socket, pidFile: pidFile, prepend: URL(filePath: "/Users/$me/nexus-prepend.php"))
        }
    }

    @Test func theStubHoldsTheSettingsAndRequiresTheLibrary() throws {
        let support = URL(filePath: "/Users/tim/Library/Application Support/Nexus", directoryHint: .isDirectory)

        let stub = try PHPConfig.dumpStub(
            settings: Self.dumpSettings(page: .automatic),
            socket: support.appending(path: "run/dumps.sock"),
            folder: support.appending(path: "run/dumps", directoryHint: .isDirectory),
            library: support.appending(path: "php/dumps/4f1c9a0e", directoryHint: .isDirectory),
            userPrepend: "/Users/tim/Sites/blog/wordfence-waf.php"
        )

        #expect(stub == #"""
            <?php

            // Nexus writes this file. Nexus writes it again when the settings of the dump viewer change.

            namespace Nexus\Dumps;

            const SETTINGS = [
                'version' => 1,
                'socket' => '/Users/tim/Library/Application Support/Nexus/run/dumps.sock',
                'folder' => '/Users/tim/Library/Application Support/Nexus/run/dumps',
                'page' => 'automatic',
                'dumps' => true,
                'queries' => false,
                'logs' => true,
                'jobs' => false,
                'userPrepend' => '/Users/tim/Sites/blog/wordfence-waf.php',
            ];

            require '/Users/tim/Library/Application Support/Nexus/php/dumps/4f1c9a0e/prepend.php';

            """#)
    }

    @Test func theStubHoldsEachSwitchOfTheSettings() throws {
        let socket = URL(filePath: "/Nexus/run/dumps.sock")
        let folder = URL(filePath: "/Nexus/run/dumps", directoryHint: .isDirectory)
        let library = URL(filePath: "/Nexus/php/dumps/1", directoryHint: .isDirectory)
        let onlyQueries = DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true)
        let allButDumps = DumpSettings(catchDumps: false, catchQueries: true, catchLogs: true, catchJobs: true, pageMode: .automatic, commands: true)

        let queriesStub = try PHPConfig.dumpStub(settings: onlyQueries, socket: socket, folder: folder, library: library, userPrepend: nil)
        let othersStub = try PHPConfig.dumpStub(settings: allButDumps, socket: socket, folder: folder, library: library, userPrepend: nil)

        #expect(queriesStub.contains("    'dumps' => false,\n    'queries' => true,\n    'logs' => false,\n    'jobs' => false,\n"))
        #expect(othersStub.contains("    'dumps' => false,\n    'queries' => true,\n    'logs' => true,\n    'jobs' => true,\n"))
    }

    @Test func theStubEscapesABackslashAndAQuoteAndRefusesALineBreak() throws {
        let socket = URL(filePath: "/Nexus/run/dumps.sock")
        let folder = URL(filePath: "/Nexus/run/dumps", directoryHint: .isDirectory)

        let quoted = try PHPConfig.dumpStub(settings: Self.dumpSettings(page: .never), socket: socket, folder: folder, library: URL(filePath: "/Users/o'brien/php/dumps/1", directoryHint: .isDirectory), userPrepend: #"/Sites/a\b.php"#)
        let withoutPrepend = try PHPConfig.dumpStub(settings: Self.dumpSettings(page: .always), socket: socket, folder: folder, library: URL(filePath: "/Nexus/php/dumps/1", directoryHint: .isDirectory), userPrepend: nil)

        #expect(quoted.contains(#"require '/Users/o\'brien/php/dumps/1/prepend.php';"#))
        #expect(quoted.contains(#"'userPrepend' => '/Sites/a\\b.php',"#))
        #expect(quoted.contains("'page' => 'never',"))
        #expect(withoutPrepend.contains("'userPrepend' => null,"))
        #expect(withoutPrepend.contains("'page' => 'always',"))
        #expect(throws: ConfigError.self) {
            try PHPConfig.dumpStub(settings: DumpSettings(), socket: socket, folder: folder, library: URL(filePath: "/Nexus/php/dumps/1"), userPrepend: "/Sites/waf.php\nexit;")
        }
        #expect(throws: ConfigError.self) {
            try PHPConfig.dumpStub(settings: DumpSettings(), socket: URL(filePath: "/Nexus/run\t/dumps.sock"), folder: folder, library: URL(filePath: "/Nexus/php/dumps/1"), userPrepend: nil)
        }
    }

    private static func dumpSettings(page: DumpPageMode) -> DumpSettings {
        DumpSettings(catchDumps: true, catchLogs: true, pageMode: page)
    }

    @Test func theIniOfACommandNamesTheStub() throws {
        let ini = try PHPConfig.dumpsIni(stub: URL(filePath: "/Users/tim/Library/Application Support/Nexus/config/php/8.5/nexus-prepend.php"))

        #expect(ini.hasPrefix(";"))
        #expect(ini.contains("\nauto_prepend_file = \"/Users/tim/Library/Application Support/Nexus/config/php/8.5/nexus-prepend.php\"\n"))
        #expect(throws: ConfigError.self) {
            try PHPConfig.dumpsIni(stub: URL(filePath: "/Users/\"tim\"/nexus-prepend.php"))
        }
    }

    @Test func theLastPrependFileOfPHPIniAndTheCustomLinesWins() {
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file =\n", customLines: []) == nil)
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = \"/Sites/waf.php\"\n", customLines: []) == "/Sites/waf.php")
        #expect(PHPConfig.userPrepend(phpIni: ";auto_prepend_file = /old.php\nauto_prepend_file = /Sites/waf.php ; the firewall\n", customLines: []) == "/Sites/waf.php")
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = /first.php\r\nauto_prepend_file = '/second.php'\r\n", customLines: []) == "/second.php")
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = /Sites/waf.php\n", customLines: ["memory_limit = 1G", "auto_prepend_file = /custom.php"]) == "/custom.php")
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = /Sites/waf.php\n", customLines: ["auto_prepend_file = None"]) == nil)
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = /Sites/waf.php\n", customLines: ["auto_prepend_file="]) == nil)
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file = /Sites/waf.php\n", customLines: ["auto_prepend_file ="]) == nil)
        #expect(PHPConfig.userPrepend(phpIni: "auto_prepend_file=/first.php\n", customLines: []) == "/first.php")
        #expect(PHPConfig.userPrepend(phpIni: "auto_append_file = /end.php\nauto_prepend_file_x = /x.php\n", customLines: []) == nil)
    }

    @Test func aUserIniWithAnyPrependFileReplacesTheStub() {
        #expect(PHPConfig.setsPrependFile(userIni: "auto_prepend_file = '/Sites/blog/wordfence-waf.php'\n"))
        #expect(PHPConfig.setsPrependFile(userIni: "memory_limit = 1G\r\nauto_prepend_file =\r\n"))
        #expect(PHPConfig.setsPrependFile(userIni: "auto_prepend_file = none\n"))
        #expect(!PHPConfig.setsPrependFile(userIni: "; auto_prepend_file = /Sites/blog/wordfence-waf.php\nmemory_limit = 1G\n"))
        #expect(!PHPConfig.setsPrependFile(userIni: "auto_append_file = /end.php\n"))
        #expect(!PHPConfig.setsPrependFile(userIni: ""))
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

    private func siteWithLines(_ server: WebServer) -> WebSite {
        let base = site(server)
        let lines = URL(filePath: "/Nexus/config/\(server == .apache ? "apache" : "nginx")/sites/shop.test.conf")
        return WebSite(hosts: base.hosts, backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog, customLines: lines)
    }

    private var apacheSettings: ApacheSettings {
        ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: [])
    }

    @Test func anNginxSiteIncludesItsLinesBeforeTheLocationsOfNexus() throws {
        let config = try NginxConfig.render(sites: [siteWithLines(.nginx)], settings: nginxSettings())
        let block = "        charset utf-8;\n    \n        include \"/Nexus/config/nginx/sites/shop.test.conf\";\n    \n        location / {\n            try_files"

        #expect(config.contains(block))
        #expect(config.components(separatedBy: "sites/shop.test.conf").count == 2)
    }

    @Test func aSiteWithoutLinesIncludesNoFileOfLines() throws {
        let nginx = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())
        let apache = try ApacheConfig.render(sites: [site(.apache)], settings: apacheSettings)

        #expect(!nginx.contains("sites/shop.test.conf"))
        #expect(!apache.contains("sites/shop.test.conf"))
    }

    @Test func anApacheSiteIncludesItsLinesAtTheEndOfItsVirtualHost() throws {
        let config = try ApacheConfig.render(sites: [siteWithLines(.apache)], settings: apacheSettings)

        #expect(config.contains("    </FilesMatch>\n    Include \"/Nexus/config/apache/sites/shop.test.conf\"\n</VirtualHost>"))
    }

    @Test func theNginxBlockOfAnApacheSiteGetsNoLines() throws {
        let config = try NginxConfig.render(sites: [siteWithLines(.apache)], settings: nginxSettings())

        #expect(!config.contains("sites/shop.test.conf"))
    }

    @Test func theFileOfLinesStartsWithOneCommentLine() {
        let file = SiteLinesFile.contents(["a", "b"], server: .nginx)

        #expect(file.split(separator: "\n").count == SiteLinesFile.headerLines + 2)
        #expect(file.hasPrefix("# Nexus writes this file from the custom nginx lines of a site."))
        #expect(file.hasSuffix("b\n"))
    }

    private func devServerFiles(root: String = "/Sites/My Shop") -> DevServerFiles {
        DevServerFiles(
            page: URL(filePath: "/Nexus/run/nginx/pages/dev-server-shop.test.html"),
            nodeModules: URL(filePath: "\(root)/node_modules", directoryHint: .isDirectory),
            hotFile: URL(filePath: "\(root)/public/hot"),
            manifest: URL(filePath: "\(root)/public/build/manifest.json")
        )
    }

    private func siteWithDevServer(_ server: WebServer, files: DevServerFiles? = nil) -> WebSite {
        let base = site(server)
        return WebSite(hosts: base.hosts, backend: base.backend, certificate: base.certificate, key: base.key, accessLog: base.accessLog, project: .laravel, devServer: files ?? devServerFiles())
    }

    @Test func aLaravelSiteOnNginxWaitsForItsDevServerWithThePageOfNexus() throws {
        let config = try NginxConfig.render(sites: [siteWithDevServer(.nginx)], settings: nginxSettings())
        let order = [
            "if (-f \"/Nexus/run/nginx/pages/dev-server-shop.test.html\") {",
            "if ($http_accept !~* \"text/html\") {",
            "if ($http_x_inertia != \"\") {",
            "if ($http_x_requested_with != \"\") {",
            "if (!-d \"/Sites/My Shop/node_modules/\") {",
            "if (-f \"/Sites/My Shop/public/hot\") {",
            "if (-f \"/Sites/My Shop/public/build/manifest.json\") {",
            "return 418;",
            "try_files $uri $uri/ /index.php?$query_string;",
        ]
        let positions = try order.map { try #require(config.range(of: $0)).lowerBound }

        #expect(positions == positions.sorted())
        #expect(config.contains("error_page 418 =503 @nexus_dev_server;"))
        #expect(config.contains("location @nexus_dev_server {\n            root \"/Nexus/run/nginx/pages/\";"))
        #expect(config.contains("rewrite ^ /dev-server-shop.test.html break;"))
    }

    @Test func anApacheSiteWaitsForItsDevServerAfterTheRedirectToHTTPS() throws {
        let config = try NginxConfig.render(sites: [siteWithDevServer(.apache)], settings: nginxSettings())
        let redirect = try #require(config.range(of: "return 301 https://"))
        let page = try #require(config.range(of: "if (-f \"/Nexus/run/nginx/pages/dev-server-shop.test.html\") {"))

        #expect(redirect.lowerBound < page.lowerBound)
        #expect(config.contains("error_page 418 =503 @nexus_dev_server;"))
        #expect(config.contains("rewrite ^ /dev-server-shop.test.html break;"))
    }

    @Test func aSiteWithoutADevServerGetsNoWaitPage() throws {
        let config = try NginxConfig.render(sites: [site(.nginx), site(.apache)], settings: nginxSettings())

        #expect(!config.contains("nexus_dev_server"))
    }

    @Test func aPathOfADevServerWithAQuoteIsRefused() {
        #expect(throws: ConfigError.unsafePath("/Sites/My \"Shop/node_modules/")) {
            try NginxConfig.render(sites: [siteWithDevServer(.nginx, files: devServerFiles(root: "/Sites/My \"Shop"))], settings: nginxSettings())
        }
    }

    @Test func theWaitPageOfADevServerLoadsAgainAndThePageOfAFailureHasTheTextsOfTheDesign() {
        let waits = ErrorPages.devServerWaits(host: "<b>.test", command: "npm run dev")
        let fails = ErrorPages.devServerFails(host: "shop.test", command: "npm run dev", buildCommand: "npm run build")

        #expect(waits.contains("<meta http-equiv='refresh' content='1'>"))
        #expect(waits.contains("<title>The dev server starts</title>"))
        #expect(waits.contains("The dev server of &lt;b&gt;.test does not run yet. Nexus starts npm run dev."))
        #expect(!fails.contains("refresh"))
        #expect(fails.contains("<h1>The dev server of shop.test does not start</h1>"))
        #expect(fails.contains("<p>Nexus started npm run dev for your request, but it stopped with an error.</p>"))
        #expect(fails.contains("<p>The Site screen of Nexus shows the log of the dev server under Background processes.</p>"))
        #expect(fails.contains("<p>After npm run build the site works without the dev server.</p>"))
    }
}

extension WebConfigTests {
    private static let shareID = "0123456789abcdef0123456789abcdef"
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    private func linked(_ backend: WebBackend, values: [String: String] = [:]) -> WebSite {
        WebSite(
            hosts: ["shop.test", "www.shop.test"],
            backend: backend,
            certificate: URL(filePath: "/Nexus/certs/shop.test.crt"),
            key: URL(filePath: "/Nexus/certs/shop.test.key"),
            accessLog: URL(filePath: "/Nexus/logs/sites/shop.test.log"),
            share: SiteShare(id: Self.shareID, fastcgiValues: values)
        )
    }

    private var publicValues: [String: String] {
        [
            "NEXUS_SHARE_HOST": "$http_x_nexus_share_host",
            "HTTP_HOST": "$http_x_nexus_share_host",
            "SERVER_NAME": "$http_x_nexus_share_host",
            "SERVER_PORT": "443",
            "APP_URL": "https://$http_x_nexus_share_host",
            "SESSION_DOMAIN": "null",
        ]
    }

    @Test func aPHPSiteWithAPublicLinkGetsAMapForEachValueAndItsFastCGILinesAfterHTTPProxy() throws {
        let other = site(.proxy(address: "http://127.0.0.1:3000"))
        let config = try NginxConfig.render(sites: [other, linked(.php(server: .nginx, documentRoot: URL(filePath: "/Sites/shop/public"), socket: URL(filePath: "/Nexus/run/php-8.5.sock")), values: publicValues)], settings: nginxSettings())
        let maps = try #require(config.range(of: "    map $nexus_share $nexus_share_1_0 {"))
        let server = try #require(config.range(of: "server_name shop.test www.shop.test;", range: maps.upperBound..<config.endIndex))

        #expect(maps.lowerBound < server.lowerBound)
        #expect(config.contains("    map $nexus_share $nexus_share_1_0 {\n        default \"\";\n        \"\(Self.shareID)\" \"https://$http_x_nexus_share_host\";\n    }"))
        #expect(config.contains("    map $nexus_share $nexus_share_1_1 {\n        default $http_host;\n        \"\(Self.shareID)\" \"$http_x_nexus_share_host\";\n    }"))
        #expect(config.contains("    map $nexus_share $nexus_share_1_3 {\n        default $server_name;\n"))
        #expect(config.contains("    map $nexus_share $nexus_share_1_4 {\n        default $server_port;\n        \"\(Self.shareID)\" \"443\";\n    }"))
        #expect(config.contains("    map $nexus_share $nexus_share_1_5 {\n        default \"\";\n        \"\(Self.shareID)\" \"null\";\n    }"))
        #expect(config.contains("""
                        fastcgi_param HTTP_PROXY "";
                        fastcgi_param APP_URL $nexus_share_1_0 if_not_empty;
                        fastcgi_param HTTP_HOST $nexus_share_1_1 if_not_empty;
                        fastcgi_param NEXUS_SHARE_HOST $nexus_share_1_2 if_not_empty;
                        fastcgi_param SERVER_NAME $nexus_share_1_3 if_not_empty;
                        fastcgi_param SERVER_PORT $nexus_share_1_4 if_not_empty;
                        fastcgi_param SESSION_DOMAIN $nexus_share_1_5 if_not_empty;
                        fastcgi_param HTTP_X_NEXUS_SHARE_REQUEST $nexus_share_request;
                        fastcgi_pass
            """))
    }

    @Test func aValueWithAQuoteOrABackslashOrAnUnsafeKeyGetsNoMap() throws {
        let values = ["NEXUS_SHARE_HOST": "$http_x_nexus_share_host", "BAD": "a\"b", "SLASH": "a\\b", "BAD.KEY": "x"]
        let config = try NginxConfig.render(sites: [linked(.php(server: .nginx, documentRoot: URL(filePath: "/Sites/shop/public"), socket: URL(filePath: "/Nexus/run/php-8.5.sock")), values: values)], settings: nginxSettings())

        #expect(config.contains("fastcgi_param NEXUS_SHARE_HOST $nexus_share_0_0 if_not_empty;"))
        #expect(!config.contains("$nexus_share_0_1"))
    }

    @Test func aPHPSiteWithoutALinkGetsNoLineOfTheLinkAndAnEmptyRequestID() throws {
        let config = try NginxConfig.render(sites: [site(.nginx)], settings: nginxSettings())

        #expect(!config.contains("$nexus_share_0"))
        #expect(config.contains("            fastcgi_param HTTP_PROXY \"\";\n            fastcgi_param HTTP_X_NEXUS_SHARE_REQUEST $nexus_share_request;\n            fastcgi_pass"))
    }

    @Test func anApacheSiteWithALinkSendsPort443AndThePublicHostOnlyForTheLink() throws {
        let withLink = try NginxConfig.render(sites: [linked(.php(server: .apache, documentRoot: URL(filePath: "/Sites/shop"), socket: URL(filePath: "/Nexus/run/php-8.4.sock")))], settings: nginxSettings())
        let without = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())

        #expect(withLink.contains("    map $nexus_share $nexus_share_0_port {\n        default $server_port;\n        \"\(Self.shareID)\" \"443\";\n    }"))
        #expect(withLink.contains("    map $nexus_share $nexus_share_0_host {\n        default \"\";\n        \"\(Self.shareID)\" \"$http_x_nexus_share_host\";\n    }"))
        #expect(withLink.contains("proxy_set_header X-Forwarded-Port $nexus_share_0_port;"))
        #expect(withLink.contains("proxy_set_header X-Nexus-Share-Host $nexus_share_0_host;"))
        #expect(!withLink.contains("fastcgi_param"))
        #expect(without.contains("proxy_set_header X-Forwarded-Port $server_port;"))
        #expect(without.contains("proxy_set_header X-Nexus-Share-Host \"\";"))
    }

    @Test func anAppAndAProxySiteWithALinkSendPort443ForTheLink() throws {
        let app = try NginxConfig.render(sites: [linked(.app(port: 20017, framework: .express))], settings: nginxSettings())
        let proxy = try NginxConfig.render(sites: [linked(.proxy(address: "http://127.0.0.1:3000"))], settings: nginxSettings())

        #expect(app.contains("proxy_set_header X-Forwarded-Port $nexus_share_0_port;"))
        #expect(proxy.contains("proxy_set_header X-Forwarded-Port $nexus_share_0_port;"))
        #expect(!app.contains("X-Nexus-Share-Host"))
        #expect(!proxy.contains("$nexus_share_0_host"))
    }

    @Test func apacheGivesPHPThePublicHostOfTheHeaderOfNginx() throws {
        let config = try ApacheConfig.render(sites: [site(.apache)], settings: ApacheSettings(port: 8081, runtime: URL(filePath: "/Nexus/runtimes/httpd/2.4"), runFolder: run, modules: []))

        #expect(config.contains("RemoteIPInternalProxy 127.0.0.1 ::1\nSetEnvIf X-Nexus-Share-Host \"^([A-Za-z0-9.-]+)$\" NEXUS_SHARE_HOST=$1\n"))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(1)))
    func realNginxAcceptsTwoLinksWithNjsAPublicSiteAndALocalApacheSite() throws {
        let root = URL(filePath: "/tmp/nexus-share-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = URL(filePath: Self.realRuntimes!, directoryHint: .isDirectory).appending(path: "nginx/1.30", directoryHint: .isDirectory)
        let run = root.appending(path: "run", directoryHint: .isDirectory)
        let shares = root.appending(path: "data share", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shares, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run.appending(path: "nginx/pages"), withIntermediateDirectories: true)

        let certificate = root.appending(path: "site").path(percentEncoded: false)
        let openssl = Process()
        openssl.executableURL = URL(filePath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=shop.test", "-days", "1", "-keyout", "\(certificate).key", "-out", "\(certificate).crt"]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()

        let settings = NginxSettings(httpPort: 30080, httpsPort: 30443, apachePort: 30081, lanAccess: false, runtime: runtime, runFolder: run, modules: ["ngx_http_js_module"])
        let publicSite = WebSite(hosts: ["shop.test"], backend: .php(server: .nginx, documentRoot: root, socket: URL(filePath: "/tmp/php-8.5.sock")), certificate: URL(filePath: "\(certificate).crt"), key: URL(filePath: "\(certificate).key"), accessLog: root.appending(path: "shop.log"), project: .laravel, share: SiteShare(id: Self.shareID, fastcgiValues: publicValues))
        let apacheSite = WebSite(hosts: ["blog.test"], backend: .php(server: .apache, documentRoot: root, socket: URL(filePath: "/tmp/php-8.4.sock")), certificate: URL(filePath: "\(certificate).crt"), key: URL(filePath: "\(certificate).key"), accessLog: root.appending(path: "blog.log"), project: .wordpress, share: SiteShare(id: "fedcba9876543210fedcba9876543210"))
        let blocks = [
            ShareBlock(id: Self.shareID, host: "shop.test", port: 40_000, mode: .publicHost, options: .standard, extraHosts: ["api.shop.test"], reverb: ShareReverb(port: 8080, key: "app-key", appID: "123456"), visitorLog: root.appending(path: "share-1.jsonl"), rewriteScript: shares.appending(path: "\(Self.shareID).js")),
            ShareBlock(id: "fedcba9876543210fedcba9876543210", host: "blog.test", port: 40_002, mode: .localHost, options: .standard, redirectHost: "www.blog.test", extraHosts: ["cms.test"], visitorLog: root.appending(path: "share-2.jsonl"), rewriteScript: shares.appending(path: "fedcba9876543210fedcba9876543210.js")),
        ]

        for block in blocks {
            try Data(try ShareRewrite.script(for: block, settings: settings).utf8).write(to: try #require(block.rewriteScript))
        }

        let config = root.appending(path: "nginx.conf")
        try Data(try NginxConfig.render(sites: [publicSite, apacheSite], shares: blocks, settings: settings).utf8).write(to: config)

        let nginx = Process()
        let errors = Pipe()
        nginx.executableURL = runtime.appending(path: "sbin/nginx")
        nginx.arguments = ["-t", "-p", root.path(percentEncoded: false), "-c", config.path(percentEncoded: false), "-e", "stderr"]
        nginx.standardOutput = FileHandle.nullDevice
        nginx.standardError = errors
        try nginx.run()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nginx.waitUntilExit()

        #expect(nginx.terminationStatus == 0, "\(output)")
    }
}
