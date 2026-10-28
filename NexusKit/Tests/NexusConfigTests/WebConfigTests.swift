import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct WebConfigTests {
    private let runtime = URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory)
    private let run = URL(filePath: "/Nexus/run", directoryHint: .isDirectory)

    private func site(_ server: WebServer, folder: String = "/Sites/My Shop/public", php: String = "8.5") -> WebSite {
        WebSite(
            hosts: ["shop.test", "www.shop.test"],
            documentRoot: URL(filePath: folder, directoryHint: .isDirectory),
            server: server,
            phpSocket: URL(filePath: "/Nexus/run/php-\(php).sock"),
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

    @Test func anApacheSiteGoesToApacheWithTheForwardedHeaders() throws {
        let config = try NginxConfig.render(sites: [site(.apache)], settings: nginxSettings())

        #expect(config.contains("proxy_pass http://127.0.0.1:8081;"))
        #expect(config.contains("proxy_set_header X-Forwarded-Proto $scheme;"))
        #expect(config.contains("proxy_set_header Host $http_host;"))
        #expect(config.contains("location ~ /\\.(?!well-known) {\n            deny all;"))
        #expect(!config.contains("fastcgi_pass"))
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
        let long = WebSite(
            hosts: ["shop.test"],
            documentRoot: URL(filePath: "/Sites/shop"),
            server: .nginx,
            phpSocket: URL(filePath: "/" + String(repeating: "a", count: 110) + ".sock"),
            certificate: URL(filePath: "/c.crt"),
            key: URL(filePath: "/c.key"),
            accessLog: URL(filePath: "/a.log")
        )

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
