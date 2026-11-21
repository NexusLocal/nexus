import CryptoKit
import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct ShareProtectionTests {
    private let settings = NginxSettings(httpPort: 8080, httpsPort: 8443, apachePort: 8081, lanAccess: false, runtime: URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory), runFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory), modules: [])

    private func share(hidesErrors: Bool = true, password: String? = nil, vite: Bool = false, composer: Bool = false, debugPaths: [String] = []) -> ShareBlock {
        var options = ShareOptions.standard
        options.hidesErrors = hidesErrors
        options.password = password != nil

        return ShareBlock(
            id: "0123456789abcdef0123456789abcdef",
            host: "shop.test",
            port: 18_000,
            mode: .localHost,
            options: options,
            vite: vite ? ShareViteTarget(kind: .laravel(hotText: "http://[::1]:5173", secure: false, documentRoot: URL(filePath: "/Sites/shop/public", directoryHint: .isDirectory)), port: 5173, projectFolder: URL(filePath: "/Sites/shop", directoryHint: .isDirectory)) : nil,
            passwordFile: password.map { URL(filePath: "\($0)/0123456789abcdef0123456789abcdef.htpasswd") },
            visitorLog: URL(filePath: "/Nexus/logs/share-0123456789abcdef0123456789abcdef.jsonl"),
            debugPaths: debugPaths,
            composerInDocumentRoot: composer
        )
    }

    private func value(of text: String, in rules: [ShareProtection.Rule], default fallback: String = "0") throws -> String {
        for rule in rules where try matches(rule.pattern, text, ignoresCase: rule.ignoresCase) {
            return rule.value
        }

        return fallback
    }

    private func matches(_ pattern: String, _ text: String, ignoresCase: Bool = true) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: ignoresCase ? [.caseInsensitive] : [])
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func values(of paths: [String], in rules: [ShareProtection.Rule]) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: paths.map { ($0, try value(of: $0, in: rules)) })
    }

    // MARK: The maps

    @Test func theHiddenRulesRefuseDotFilesCaseVariantsOfPHPDuskAndTheEditor() throws {
        let refused = [
            "/.env", "/.ENV", "/.Env", "/a/.git/config", "/.GIT/config", "/.htaccess", "/.DS_Store", "/.idea/workspace.xml", "/.claude/settings.json",
            "/.well-known/x/.env", "/node_modules/.vite/x.js", "/node_modules/.vite/deps/.x", "/node_modules/.pnpm/a@1/node_modules/a/i.js",
            "/index.PHP", "/wp-config.Php", "/a.PHP/b", "/index.pHp", "/index.phP", "/_nexus/host/cms.shop.test/index.PHP",
            "/_dusk/login/1", "/_DUSK/login/1", "/_Dusk", "/__open-in-editor", "/__OPEN-IN-EDITOR",
            "/_nexus/host/cms.shop.test/.env", "/_nexus/host/cms.shop.test/_dusk/login/1",
        ]

        for path in refused {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "1", "\(path)")
        }
    }

    @Test func theHiddenRulesRefuseLogsDumpsBackupsAndAdminerInEachCase() throws {
        let refused = [
            "/storage/logs/laravel.log", "/storage/logs/LARAVEL.LOG", "/backup.SQL", "/backup.sql", "/database.sqlite", "/DB.SQLITE3", "/db.sqlite3",
            "/app.db", "/app.DB", "/wp-config.php.bak", "/wp-config.php.BAK", "/index.php.old", "/a.orig", "/a.swp", "/.a.swp", "/index.php~",
            "/adminer.php", "/ADMINER.PHP", "/tools/Adminer-4.8.1.php", "/adminer.php/x", "/_nexus/host/cms.shop.test/dump.sql",
        ]

        for path in refused {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "1", "\(path)")
        }
    }

    @Test func theHiddenRulesRefuseTheDevEndpointsOfNextAndNuxtAlsoBelowABasePath() throws {
        let refused = [
            "/__nextjs_launch-editor", "/docs/__nextjs_launch-editor", "/__NEXTJS_LAUNCH-EDITOR", "/__nextjs_original-stack-frames",
            "/__nextjs_original-stack-frame", "/__nextjs_source-map", "/__nextjs_attach-nodejs-inspector", "/__nextjs_restart_dev",
            "/__nextjs_devtools_config", "/__nextjs_disable_dev_indicator", "/__nuxt_devtools__/client/", "/app/__nuxt_devtools__/",
            "/__devtools/__connection.json", "/__devtools-assets/x.js",
        ]
        let passed = ["/__nextjs_font/geist.woff2", "/__nextjs_server_status", "/_next/static/chunks/main.js", "/_nuxt/entry.js", "/devtools"]

        for path in refused {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "1", "\(path)")
        }

        for path in passed {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "0", "\(path)")
        }
    }

    @Test func theHiddenRulesMarkTheFilesOfAViteDevServer() throws {
        let vite = ["/node_modules/.vite/deps/axios.js", "/_nuxt/node_modules/.vite/deps/x.js", "/.svelte-kit/generated/client/app.js", "/.svelte-kit/generated/root.svelte"]

        for path in vite {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "vite", "\(path)")
        }

        #expect(try value(of: "/.svelte-kit/generated/.x/app.js", in: ShareProtection.hiddenRules) == "1")
        #expect(try value(of: "/.svelte-kit/output/server/index.js", in: ShareProtection.hiddenRules) == "1")
    }

    @Test func theHiddenRulesPassTheNormalPathsOfASite() throws {
        let passed = [
            "/", "/index.php", "/a.phpx", "/a.php5", "/.well-known/acme-challenge/x", "/.well-known/security.txt", "/vendor/composer/installed.json",
            "/vendors/acme", "/_nexus/host/cms.shop.test/img/a.png", "/catalog", "/a.blog", "/old/page", "/sql/tips", "/adminer", "/login",
            "/_duskx", "/a/b.dbx", "/backup", "/a~b",
        ]

        for path in passed {
            #expect(try value(of: path, in: ShareProtection.hiddenRules) == "0", "\(path)")
        }
    }

    @Test func theVendorRulesRefuseTheComposerFolderInEachCaseAndPassTheStaticFiles() throws {
        let composer = [
            "/vendor/composer/installed.json", "/VENDOR/composer/installed.json", "/Vendor/Composer/Installed.json",
            "/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php", "/vendor/phpunit/phpunit/src/Util/PHP/EVAL-STDIN.PHP",
            "/vendor/x.php/y.js", "/vendor/x.PHP/y.js", "/vendor/x.phtml", "/vendor/x.phar", "/vendor/x.ts", "/vendor", "/vendor/", "/vendor/acme",
            "/vendor/autoload.php",
        ]
        let fromAHost = ["/_nexus/host/cms.shop.test/vendor/composer/installed.json", "/_nexus/host/cms.shop.test/vendor/x.php/y.js", "/_nexus/host/cms.shop.test/VENDOR/autoload.php"]
        let passed = [
            "/vendor/livewire/livewire/dist/livewire.esm.js", "/vendor/telescope/app.css", "/vendor/telescope/APP.CSS", "/vendor/x/font.woff2",
            "/vendor/x/a.mjs", "/vendors/acme", "/_nexus/host/cms.shop.test/vendor/telescope/app.css", "/",
        ]

        for path in composer {
            #expect(try value(of: path, in: ShareProtection.vendorRules) == "composer", "\(path)")
        }

        for path in fromAHost {
            #expect(try value(of: path, in: ShareProtection.vendorRules) == "1", "\(path)")
        }

        for path in passed {
            #expect(try value(of: path, in: ShareProtection.vendorRules) == "0", "\(path)")
        }
    }

    @Test func theRawPathRefusesEachFormOfADotSegmentANulAndABackslash() throws {
        let refused = [
            "/a/../b", "/a/./b", "/..", "/a/..", "/%2e%2e/x", "/%2E%2e/x", "/%2E%2E/x", "/.%2e/x", "/%2e./x", "/a/%2e/b", "/a/%2E/b",
            "/a/..%2fb", "/a/..%2Fb", "/a%2f../b", "/a%2F..%2Fb", "/a%00.php", "/a\\b", "/a%5Cb", "/a%5cb",
        ]
        let passed = ["/a/b", "/a.b/c", "/a..b", "/a?x=../b", "/a?x=%2e%2e", "/a/b?file=..%2f..%2fetc", "/.well-known/x", "/a%2fb"]

        for path in refused {
            #expect(try matches(ShareProtection.badPathPattern, path), "\(path)")
        }

        for path in passed {
            #expect(try !matches(ShareProtection.badPathPattern, path), "\(path)")
        }
    }

    @Test func theDebugRulesRefuseTheToolsInEachCase() throws {
        let rules = ShareProtection.debugRules.map { ShareProtection.Rule(pattern: $0, ignoresCase: true, value: "1") }
        let refused = [
            "/telescope", "/Telescope/requests", "/TELESCOPE", "/horizon/api/jobs", "/pulse", "/__clockwork/1", "/clockwork/app",
            "/_ignition/execute-solution", "/_IGNITION/execute-solution", "/_debugbar/open", "/log-viewer", "/_boost/browser-logs",
            "/_profiler/phpinfo", "/_wdt/a", "/_nexus/host/cms.shop.test/telescope", "/x/info.php", "/info.php", "/phpinfo.php",
            "/PHPINFO.php", "/PhpInfo.PHP", "/app.js.map", "/APP.JS.MAP", "/build/assets/app.css.map",
        ]
        let passed = ["/telescope-x", "/information.php", "/map", "/horizons", "/myinfo.php", "/a/pulse-check"]

        for path in refused {
            #expect(try value(of: path, in: rules) == "1", "\(path)")
        }

        for path in passed {
            #expect(try value(of: path, in: rules) == "0", "\(path)")
        }
    }

    @Test func theCustomPathsOfTheDebugToolsBecomeOnePatternWithoutUnsafeValues() throws {
        let pattern = try #require(ShareProtection.debugPathPattern(["admin/telescope", "ops.horizon", "a\"b", "x$y", "a b", "a{b}", ""]))

        #expect(pattern.contains(#"ops\.horizon"#))
        #expect(!pattern.contains("a\"b"))
        #expect(!pattern.contains("x$y"))
        #expect(!pattern.contains("a b"))
        #expect(!pattern.contains("{b}"))
        #expect(try matches(pattern, "/admin/telescope/requests"))
        #expect(try matches(pattern, "/ADMIN/Telescope"))
        #expect(try matches(pattern, "/_nexus/host/cms.shop.test/admin/telescope"))
        #expect(try matches(pattern, "/ops.horizon"))
        #expect(try !matches(pattern, "/admin/telescopes"))
        #expect(try !matches(pattern, "/opsxhorizon"))
        #expect(ShareProtection.debugPathPattern(["a\"b", "$x", ""]) == nil)
        #expect(ShareProtection.debugPathPattern([]) == nil)
    }

    @Test func theTriggersOfXdebugAreFoundAndRemovedFromTheCookieAsTheSiteBlockReadsThem() throws {
        let query = NginxConfig.xdebugQueryPattern
        let cookie = NginxConfig.xdebugCookiePattern

        #expect(try matches(query, "XDEBUG_SESSION=1", ignoresCase: false))
        #expect(try matches(query, "a=1&XDEBUG_TRIGGER", ignoresCase: false))
        #expect(try matches(query, "XDEBUG_SESSION_START=x", ignoresCase: false))
        #expect(try !matches(query, "XDEBUG_SESSIONX=1", ignoresCase: false))
        #expect(try !matches(query, "x=XDEBUG_SESSION", ignoresCase: false))

        #expect(try removeTriggers(from: "a=1; XDEBUG_SESSION=PHPSTORM; b=2") == "a=1; b=2")
        #expect(try removeTriggers(from: "XDEBUG_SESSION=1; XDEBUG_TRIGGER=2; a=1") == "; a=1")
        #expect(try removeTriggers(from: "XDEBUG_SESSION=1") == "")
        #expect(try removeTriggers(from: "xdebug_session=1") == "xdebug_session=1")
        #expect(try removeTriggers(from: "MY_XDEBUG_SESSION=1") == "MY_XDEBUG_SESSION=1")

        let three = try removeTriggers(from: "XDEBUG_SESSION=1; XDEBUG_TRIGGER=2; XDEBUG_SESSION=3")
        #expect(try matches(cookie, three, ignoresCase: false))
        #expect(try !matches(cookie, try removeTriggers(from: "a=1; XDEBUG_SESSION=1"), ignoresCase: false))
    }

    private func removeTriggers(from cookie: String) throws -> String {
        try [("before", "after"), ("before", "after")].reduce(cookie) { text, names in
            let regex = try NSRegularExpression(pattern: ShareProtection.cookieRemoval(before: names.0, after: names.1))

            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let before = Range(match.range(withName: names.0), in: text), let after = Range(match.range(withName: names.1), in: text) else {
                return text
            }

            return String(text[before]) + String(text[after])
        }
    }

    private func realm(_ path: String, _ method: String, override: String = "", user: String = "") throws -> String {
        let login = try value(of: path, in: ShareProtection.loginRules)
        let visitor = try value(of: user, in: [ShareProtection.userRule])
        return try value(of: "\(login):\(visitor):\(method):\(override)", in: ShareProtection.realmRules, default: "off")
    }

    @Test func thePasswordIsAskedForGetHeadAnOverrideAndTheLoginOfWordPress() throws {
        #expect(try realm("/", "GET") == "\"Nexus\"")
        #expect(try realm("/", "HEAD") == "\"Nexus\"")
        #expect(try realm("/webhook", "GET", user: "AC123") == "\"Nexus\"")

        for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
            #expect(try realm("/webhook", method) == "off", "\(method)")
            #expect(try realm("/webhook", method, user: "AC123") == "off", "\(method)")
            #expect(try realm("/webhook", method, user: "NEXUS") == "off", "\(method)")
            #expect(try realm("/webhook", method, override: "GET", user: "AC123") == "\"Nexus\"", "\(method)")
            #expect(try realm("/wp-login.php", method) == "\"Nexus\"", "\(method)")
            #expect(try realm("/", method, user: "nexus") == "\"Nexus\"", "\(method)")
        }

        #expect(try realm("/", "POST", override: "GET") == "\"Nexus\"")
        #expect(try realm("/", "POST", override: "get") == "\"Nexus\"")
        #expect(try realm("/", "GET", override: "POST") == "\"Nexus\"")
        #expect(try realm("/wp-admin/admin-ajax.php", "POST") == "off")
    }

    @Test func aPostWithoutThePasswordStaysAPostAndAVisitorWithThePasswordKeepsTheMethodOfAForm() throws {
        func method(_ method: String, user: String = "") throws -> String {
            let realm = try realm("/", method, user: user).replacingOccurrences(of: "\"", with: "")
            return try value(of: "\(realm):\(method)", in: ShareProtection.methodRules, default: "$http_x_http_method_override")
        }

        let text = ShareProtection.httpLines(for: [share(password: "/Nexus/data/share")]).joined(separator: "\n")

        #expect(try method("POST") == "POST")
        #expect(try method("POST", user: "AC123") == "POST")
        #expect(try method("POST", user: "nexus") == "$http_x_http_method_override")
        #expect(try method("PUT") == "$http_x_http_method_override")
        #expect(text.contains("map \"$nexus_guard_realm:$request_method\" $nexus_guard_method {\n    default $http_x_http_method_override;\n    \"~^off:POST$\" POST;\n}"))
        #expect(ShareProtection.answerLines(for: share(password: "/Nexus/data/share")).contains("proxy_set_header X-HTTP-Method-Override $nexus_guard_method;"))
        #expect(!ShareProtection.answerLines(for: share()).contains { $0.contains("Method-Override") })
    }

    @Test func theLoginRulesFindTheLoginPathsOfWordPressAndPassItsAjax() throws {
        let login = [
            "/wp-login.php", "/WP-LOGIN.PHP", "/xmlrpc.php", "/XMLRPC.php", "/wp-admin/", "/wp-admin", "/WP-ADMIN/", "/wp-admin/post.php",
            "/wp-admin/plugin-install.php", "/wp/wp-login.php", "/wp/wp-admin/", "/wp-login.php/x", "/_nexus/host/cms.shop.test/wp-login.php",
        ]
        let other = ["/wp-admin/admin-ajax.php", "/wp-admin/admin-post.php", "/WP-ADMIN/ADMIN-AJAX.PHP", "/my-wp-admin", "/", "/wp-content/uploads/a.png"]

        for path in login {
            #expect(try value(of: path, in: ShareProtection.loginRules) == "1", "\(path)")
        }

        for path in other {
            #expect(try value(of: path, in: ShareProtection.loginRules) == "0", "\(path)")
        }
    }

    @Test func eachMapLineEscapesABackslashAndAQuoteForNginx() {
        let line = ShareProtection.Rule(pattern: #"a\.b"c"#, ignoresCase: true, value: "1").line

        #expect(line == #""~*a\\.b\"c" 1;"#)
        #expect(ConfigText.nginxQuoted(#"\\"#) == #"\\\\"#)
    }

    @Test func theHTTPBlockHasTheMapsOnlyWithALink() {
        let lines = ShareProtection.httpLines(for: [share()])
        let text = lines.joined(separator: "\n")

        #expect(ShareProtection.httpLines(for: []).isEmpty)

        for name in ["$nexus_guard_hidden", "$nexus_guard_vendor", "$nexus_guard_bad_path", "$nexus_guard_debug", "$nexus_guard_xdebug_query", "$nexus_guard_cookie_once", "$nexus_guard_cookie", "$nexus_guard_xdebug_cookie", "$nexus_guard_login", "$nexus_guard_user", "$nexus_guard_realm", "$nexus_guard_method"] {
            #expect(lines.contains { $0.hasPrefix("map ") && $0.hasSuffix(" \(name) {") }, "\(name)")
        }

        #expect(text.contains("map $request_uri $nexus_guard_bad_path {"))
        #expect(text.contains("map \"$nexus_guard_login:$nexus_guard_user:$request_method:$http_x_http_method_override$http_x_http_method$http_x_method_override$arg__method\" $nexus_guard_realm {\n    default \"off\";"))
        #expect(text.contains("map $remote_user $nexus_guard_user {\n    default 0;\n    \"~^nexus$\" 1;\n}"))
        #expect(text.contains("map $http_cookie $nexus_guard_cookie_once {\n    default $http_cookie;"))
        #expect(text.contains(#"(?<nexus_guard_a>.*?)(?:(^|;)\\s*XDEBUG_(SESSION|TRIGGER)=)[^;]*(?<nexus_guard_b>.*)$" "$nexus_guard_a$nexus_guard_b";"#))
        #expect(!text.contains("nexus_share_"))
    }

    // MARK: The lines of the share block

    @Test func theAlwaysLinesAreTheSameWithAndWithoutTheOption() throws {
        let on = try ShareProtection.refusals(for: share())
        let off = try ShareProtection.refusals(for: share(hidesErrors: false))
        let answerOn = ShareProtection.answerLines(for: share())
        let answerOff = ShareProtection.answerLines(for: share(hidesErrors: false))

        #expect(Array(on.prefix(off.count)) == off)
        #expect(Array(answerOn.prefix(answerOff.count)) == answerOff)
        #expect(off.contains("server_tokens off;"))
        #expect(off.contains(ShareProtection.robotsLine))
        #expect(!off.contains { $0.contains("nexus_guard_debug") || $0.contains("xdebug") || $0.contains("@nexus_guard") || $0.contains("recursive_error_pages") })
        #expect(!answerOff.contains { $0.contains("error_page") || $0.contains("proxy_hide_header") || $0.contains("Cookie") || $0.contains("intercept") })
    }

    @Test func aBlockWithViteLetsItsFilesPassAndOnlyAFolderWithComposerRefusesItsVendorFolder() throws {
        let plain = try ShareProtection.refusals(for: share())
        let vite = try ShareProtection.refusals(for: share(vite: true))
        let composer = try ShareProtection.refusals(for: share(composer: true))

        #expect(plain.contains("if ($nexus_guard_hidden) {"))
        #expect(!plain.contains("if ($nexus_guard_hidden = 1) {"))
        #expect(vite.contains("if ($nexus_guard_hidden = 1) {"))
        #expect(!vite.contains("if ($nexus_guard_hidden) {"))
        #expect(plain.contains("if ($nexus_guard_bad_path) {"))

        for lines in [plain, vite, composer] {
            #expect(lines.contains("if ($nexus_guard_vendor = 1) {"))
        }

        #expect(composer.contains("if ($nexus_guard_vendor = composer) {"))
        #expect(!plain.contains("if ($nexus_guard_vendor = composer) {"))
    }

    @Test func thePasswordIsAtTheServerLevelWithTheQuotedFile() throws {
        let with = try ShareProtection.refusals(for: share(password: "/Users/me/Library/Application Support/Nexus/data/share"))
        let without = try ShareProtection.refusals(for: share())

        #expect(with.contains("auth_basic $nexus_guard_realm;"))
        #expect(with.contains("auth_basic_user_file \"/Users/me/Library/Application Support/Nexus/data/share/0123456789abcdef0123456789abcdef.htpasswd\";"))
        #expect(!without.contains { $0.contains("auth_basic") })
        #expect(throws: ConfigError.self) {
            try ShareProtection.refusals(for: share(password: "/Users/$me/share"))
        }
    }

    @Test func theOptionAddsTheDebugRefusalsAndThePlainPages() throws {
        let lines = try ShareProtection.refusals(for: share(debugPaths: ["admin/telescope"]))
        let text = lines.joined(separator: "\n")

        #expect(lines.contains("if ($nexus_guard_debug) {"))
        #expect(lines.contains(#"if ($uri ~* "^(?:/_nexus/host/[^/]+)?/(?:admin/telescope)(?:/|$)") {"#))
        #expect(lines.contains("if ($nexus_guard_xdebug_query) {"))
        #expect(lines.contains("if ($nexus_guard_xdebug_cookie) {"))
        #expect(lines.contains("recursive_error_pages on;"))
        #expect(text.contains("location @nexus_guard_error {\n    default_type text/html;\n    add_header Cache-Control no-store always;\n    \(ShareProtection.robotsLine)\n    return 500 \"\(ErrorPages.shareError)\";\n}"))
        #expect(text.contains("location @nexus_guard_waits {\n    default_type text/html;\n    add_header Cache-Control no-store always;\n    add_header Retry-After 1 always;\n    \(ShareProtection.robotsLine)\n    return 503 \"\(ErrorPages.shareWaits)\";\n}"))
        #expect(!(try ShareProtection.refusals(for: share())).contains { $0.contains("$uri ~*") })
    }

    @Test func theAnswerLinesSetTheAddressRemoveTheOtherHeadersAndReplaceTheErrorPages() {
        let lines = ShareProtection.answerLines(for: share())
        let codes = Array(500...599).filter { ![502, 503, 504].contains($0) }.map(String.init).joined(separator: " ")

        #expect(Array(lines.prefix(8)) == [
            "proxy_set_header X-Forwarded-For $http_cf_connecting_ip;",
            "proxy_set_header X-Real-IP $http_cf_connecting_ip;",
            "proxy_set_header Client-IP \"\";",
            "proxy_set_header X-Client-IP \"\";",
            "proxy_set_header X-Cluster-Client-IP \"\";",
            "proxy_set_header True-Client-IP \"\";",
            "proxy_set_header X-Original-URL \"\";",
            "proxy_set_header X-Rewrite-URL \"\";",
        ])
        #expect(lines.contains("proxy_intercept_errors on;"))
        #expect(lines.contains("error_page \(codes) @nexus_guard_error;"))
        #expect(lines.contains("error_page 502 503 504 @nexus_guard_waits;"))
        #expect(lines.contains("proxy_hide_header X-Powered-By;"))
        #expect(lines.contains("proxy_hide_header phpdebugbar-id;"))
        #expect(lines.last == "proxy_set_header Cookie $nexus_guard_cookie;")
        #expect(!ShareProtection.answerLines(for: share(), keepsCookie: false).contains { $0.contains("Cookie") })
        #expect(!lines.contains { $0.contains("X-Forwarded-Host") || $0.contains("X-Forwarded-Prefix") || $0.contains(" Forwarded ") })
    }

    @Test func aFullBlockHasTheProtectionAtTheServerLevelAndAtTheEndOfEachProxyLocation() throws {
        let block = try ShareConfig.render(share(password: "/Nexus/data/share", vite: true, composer: true, debugPaths: ["ops"]), settings: settings)
        let serverLevel = block.filter { $0.hasPrefix("    ") && !$0.hasPrefix("        ") }
        let locations = proxyLocations(in: block)

        #expect(serverLevel.contains("    server_tokens off;"))
        #expect(serverLevel.contains("    \(ShareProtection.robotsLine)"))
        #expect(serverLevel.contains("    auth_basic $nexus_guard_realm;"))
        #expect(block.filter { $0.contains("auth_basic ") }.count == 1)
        #expect(!locations.isEmpty)

        for location in locations {
            #expect(location.contains { $0.contains("error_page 502 503 504 @nexus_guard_waits;") }, "\(location.first ?? "")")
            #expect(location.contains { $0.contains("proxy_intercept_errors on;") }, "\(location.first ?? "")")

            if location.contains(where: { $0.contains("add_header") }) {
                #expect(location.contains { $0.hasSuffix(ShareProtection.robotsLine) }, "\(location.first ?? "")")
            }
        }
    }

    private func proxyLocations(in block: [String]) -> [[String]] {
        var locations: [[String]] = []
        var current: [String]?

        for line in block {
            if line.hasPrefix("    location ") {
                current = [line]
                continue
            }

            if line == "    }", let lines = current {
                if lines.contains(where: { $0.contains("proxy_pass") }) {
                    locations.append(lines)
                }

                current = nil
                continue
            }

            current?.append(line)
        }

        return locations
    }

    // MARK: The values and the files

    @Test func thePasswordLineIsSaltedSHA1ThatNginxReads() {
        let salt: [UInt8] = [1, 2, 3, 4, 250, 251, 252, 253]
        let digest = Data(Insecure.SHA1.hash(data: Data("k7mq-2xfh-9pwd-r4tc".utf8) + Data(salt)))

        #expect(ShareProtection.passwordLine(password: "k7mq-2xfh-9pwd-r4tc", salt: salt) == "nexus:{SSHA}\((digest + Data(salt)).base64EncodedString())\n")
    }

    @Test func theFastCGIValuesGiveTheAddressAlwaysAndTheDebugValuesOnlyWithTheOption() {
        var off = ShareOptions.standard
        off.hidesErrors = false

        #expect(ShareProtection.fastcgiValues(for: off) == ["REMOTE_ADDR": "$http_x_nexus_share_visitor"])
        #expect(ShareProtection.fastcgiValues(for: .standard) == [
            "REMOTE_ADDR": "$http_x_nexus_share_visitor",
            "APP_DEBUG": "false",
            "DEBUGBAR_ENABLED": "false",
            "CLOCKWORK_ENABLE": "false",
            "NEXUS_SHARE_HIDE_DUMPS": "1",
            "APP_CONFIG_CACHE": "/dev/null/nexus-share-config.php",
        ])
    }

    @Test func thePagesOfALinkNameNoHostAndOnlyTheWaitPageLoadsAgain() {
        for page in [ErrorPages.shareError, ErrorPages.shareWaits] {
            #expect(!page.contains("$"))
            #expect(!page.contains("\""))
            #expect(!page.contains(".test"))
            #expect(!page.contains("nexus "))
        }

        #expect(ErrorPages.shareError.contains("<title>The site has an error</title>"))
        #expect(ErrorPages.shareWaits.contains("<title>The site starts</title>"))
        #expect(ErrorPages.shareWaits.contains("http-equiv='refresh'"))
        #expect(!ErrorPages.shareError.contains("http-equiv"))
    }

    @Test func theMapsOfXdebugInTheSiteBlockKeepTheirText() {
        #expect(NginxConfig.xdebugMaps == [
            "    map $http_cookie $nexus_xdebug_cookie {",
            "        default 0;",
            #"        "~(^|;)\s*XDEBUG_(SESSION|TRIGGER)=" 1;"#,
            "    }",
            "",
            "    map $args $nexus_xdebug {",
            "        default $nexus_xdebug_cookie;",
            #"        "~(^|&)XDEBUG_(SESSION|SESSION_START|TRIGGER)(=|&|$)" 1;"#,
            "    }",
            "",
        ])
    }
}
