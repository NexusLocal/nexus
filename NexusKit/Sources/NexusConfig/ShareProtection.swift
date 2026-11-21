import CryptoKit
import Foundation
import NexusCore

// The protection of visitors (group 4, 4d). The share block refuses paths, removes headers and
// replaces error pages. The site block gives PHP the address of the visitor and turns off the
// debug mode of the app. Each rule is in the security review of docs/group4/contract-4d-protection.md.
public enum ShareProtection {
    // One line of a map of nginx. ignoresCase gives ~* in place of ~. APFS ignores case. So each
    // rule for a file name ignores case too.
    struct Rule: Sendable, Equatable {
        let pattern: String
        let ignoresCase: Bool
        let value: String

        var line: String {
            "\"\(ignoresCase ? "~*" : "~")\(ConfigText.nginxQuoted(pattern))\" \(value);"
        }
    }

    // Each path rule also matches below a second local host of 4c.
    static let secondHost = "\(ShareRewrite.hostPrefix)[^/]+"
    static let hostPrefix = "(?:\(secondHost))?"

    static let staticExtensions = "(?:m?js|cjs|css|svg|png|jpe?g|gif|webp|avif|ico|woff2?|ttf|otf|eot)"

    // The dev endpoints that act on the Mac. They open an editor, read or write files or run code. The
    // list comes from the source of Next.js 16.4, Nuxt 4.6 and the devtools of Vite (2026-11-20). An
    // app can have a base path. So the rule has no ^.
    static let devEndpoints = [
        "__nextjs_launch-editor",
        "__nextjs_original-stack-frames?",
        "__nextjs_source-map",
        "__nextjs_attach-nodejs-inspector",
        "__nextjs_restart_dev",
        "__nextjs_devtools_config",
        "__nextjs_disable_dev_indicator",
        "__nuxt_devtools__",
        "__devtools",
        "__devtools-assets",
    ]

    // A map of nginx checks its regular expressions in this order. The first match wins. The tests
    // run the same rules with NSRegularExpression. The first rule finds each case variant of .php.
    // APFS finds such a file. A web server can then send its source and not run it. The value "vite"
    // is a path that only a block with a dev server may pass (4e). The other rules for a dot folder
    // of 4e get the same value.
    static let hiddenRules = [
        Rule(pattern: #"\.(?!php(?:/|$))(?i:php)(?:/|$)"#, ignoresCase: false, value: "1"),
        Rule(pattern: "^\(hostPrefix)/_dusk(?:/|$)", ignoresCase: true, value: "1"),
        Rule(pattern: "^\(hostPrefix)/__open-in-editor(?:/|$)", ignoresCase: true, value: "1"),
        Rule(pattern: "/(?:\(devEndpoints.joined(separator: "|")))(?:/|$)", ignoresCase: true, value: "1"),
        Rule(pattern: #"\.(?:log|sql|sqlite3?|db|bak|old|orig|swp)$"#, ignoresCase: true, value: "1"),
        Rule(pattern: "~$", ignoresCase: false, value: "1"),
        Rule(pattern: #"/adminer[^/]*\.php(?:/|$)"#, ignoresCase: true, value: "1"),
        Rule(pattern: #"^\#(hostPrefix)/\.well-known/(?!.*/\.)"#, ignoresCase: false, value: "0"),
        Rule(pattern: #"/node_modules/\.vite/deps/[^/.][^/]*$"#, ignoresCase: false, value: "vite"),
        Rule(pattern: #"/\.svelte-kit/generated/(?:[^/.][^/]*/)*[^/.][^/]*$"#, ignoresCase: false, value: "vite"),
        Rule(pattern: #"/\."#, ignoresCase: false, value: "1"),
    ]

    // The value "composer" is a path below /vendor/ of the site. Only a block with
    // composerInDocumentRoot refuses it. The value 1 is a path below a second local host of 4c.
    // nexusd does not read the document root of a second local host. The static files are the list
    // of 4e. Each .php below /vendor/ is refused, also with a path after it. An example is
    // eval-stdin.php/x.js.
    static let vendorRules = [
        Rule(pattern: #"^\#(secondHost)/vendor/.*\.ph(?:p|tml|ar)"#, ignoresCase: true, value: "1"),
        Rule(pattern: #"^\#(secondHost)/vendor/.+\.\#(staticExtensions)$"#, ignoresCase: true, value: "0"),
        Rule(pattern: "^\(secondHost)/vendor(?:/|$)", ignoresCase: true, value: "1"),
        Rule(pattern: #"^/vendor/.*\.ph(?:p|tml|ar)"#, ignoresCase: true, value: "composer"),
        Rule(pattern: #"^/vendor/.+\.\#(staticExtensions)$"#, ignoresCase: true, value: "0"),
        Rule(pattern: "^/vendor(?:/|$)", ignoresCase: true, value: "composer"),
    ]

    // The login paths of WordPress. With the password each request to them needs it (owner,
    // 2026-11-20). The pages of a site send forms and AJAX of plugins to admin-ajax.php and
    // admin-post.php. The rules have no ^. So they also match /wp/wp-login.php of Bedrock.
    static let loginRules = [
        Rule(pattern: #"/wp-admin/admin-(?:ajax|post)\.php$"#, ignoresCase: true, value: "0"),
        Rule(pattern: #"/(?:wp-login|xmlrpc)\.php(?:/|$)"#, ignoresCase: true, value: "1"),
        Rule(pattern: "/wp-admin(?:/|$)", ignoresCase: true, value: "1"),
    ]

    // The raw path before the ?. A backend of an app gets the raw path. So nginx must refuse each
    // form of a dot segment there: raw, with %2e and with %2f. A NUL and a backslash are refused
    // too.
    static let badPathPattern = #"^[^?]*(?:(?:/|%2f)(?:\.|%2e){1,2}(?:/|%2f|$)|%2e%2e|%2e\.|\.%2e|%00|%5c|\\)"#

    // The paths of the debug tools. Each one ignores case.
    static let debugRules = [
        "^\(hostPrefix)/(?:telescope|horizon|pulse|_ignition|_debugbar|clockwork|__clockwork|log-viewer|_boost|_profiler|_wdt)(?:/|$)",
        #"(?:^|/)(?:php)?info\.php(?:/|$)"#,
        #"\.map$"#,
    ]

    // One pass removes one trigger of Xdebug from the cookie. before and after name the captures.
    // The pattern of the trigger is the pattern of the site block. So the share block removes
    // exactly what the site block would send to Xdebug.
    static func cookieRemoval(before: String, after: String) -> String {
        "^(?<\(before)>.*?)(?:\(NginxConfig.xdebugCookiePattern))[^;]*(?<\(after)>.*)$"
    }

    // The codes that get the plain page. 502, 503 and 504 get the page that loads again.
    static let waitCodes = [502, 503, 504]
    static let errorCodes = Array(500...599).filter { !waitCodes.contains($0) }

    public static let robotsLine = #"add_header X-Robots-Tag "noindex, nofollow" always;"#

    // The name in the password prompt of the browser.
    static let realm = "Nexus"

    // The maps of the http block. They are there only with at least one link.
    public static func httpLines(for shares: [ShareBlock]) -> [String] {
        guard !shares.isEmpty else {
            return []
        }

        var lines = ["", "# The protection of the links (group 4, 4d)."]

        lines += map("$uri", to: "$nexus_guard_hidden", rules: hiddenRules)
        lines += map("$uri", to: "$nexus_guard_vendor", rules: vendorRules)
        lines += map("$request_uri", to: "$nexus_guard_bad_path", rules: [Rule(pattern: badPathPattern, ignoresCase: true, value: "1")])
        lines += map("$uri", to: "$nexus_guard_debug", rules: debugRules.map { Rule(pattern: $0, ignoresCase: true, value: "1") })
        lines += map("$args", to: "$nexus_guard_xdebug_query", rules: [Rule(pattern: NginxConfig.xdebugQueryPattern, ignoresCase: false, value: "1")])
        lines += map("$http_cookie", to: "$nexus_guard_cookie_once", default: "$http_cookie", rules: [
            Rule(pattern: cookieRemoval(before: "nexus_guard_a", after: "nexus_guard_b"), ignoresCase: false, value: "\"$nexus_guard_a$nexus_guard_b\""),
        ])
        lines += map("$nexus_guard_cookie_once", to: "$nexus_guard_cookie", default: "$nexus_guard_cookie_once", rules: [
            Rule(pattern: cookieRemoval(before: "nexus_guard_c", after: "nexus_guard_d"), ignoresCase: false, value: "\"$nexus_guard_c$nexus_guard_d\""),
        ])
        lines += map("$nexus_guard_cookie", to: "$nexus_guard_xdebug_cookie", rules: [Rule(pattern: NginxConfig.xdebugCookiePattern, ignoresCase: false, value: "1")])
        lines += map("$uri", to: "$nexus_guard_login", rules: loginRules)
        lines += map("$remote_user", to: "$nexus_guard_user", rules: [userRule])
        lines += map("\"$nexus_guard_login:$nexus_guard_user:$request_method:$http_x_http_method_override$http_x_http_method$http_x_method_override$arg__method\"", to: "$nexus_guard_realm", default: "\"off\"", rules: realmRules)
        lines += map("\"$nexus_guard_realm:$request_method\"", to: "$nexus_guard_method", default: "$http_x_http_method_override", rules: methodRules)

        return lines
    }

    // The browser of a visitor sends the user name of the password file with each request. A
    // webhook with its own Basic credentials, for example of Twilio, sends another user name. nginx
    // reads $remote_user from the header without a check of the password.
    static let passwordUser = "nexus"
    static let userRule = Rule(pattern: "^\(passwordUser)$", ignoresCase: false, value: "1")

    // Only a method that is not GET or HEAD can pass without the password. It must have no override
    // and not the user name of the password file. A browser with the password then keeps the
    // _method of a form. The login paths of WordPress always need it. A webhook still reaches the
    // site, also with its own Basic credentials. auth_basic with the value "off" asks for no
    // password.
    static let realmRules = [
        Rule(pattern: "^1:", ignoresCase: false, value: "\"\(realm)\""),
        Rule(pattern: "^0:1:", ignoresCase: false, value: "\"\(realm)\""),
        Rule(pattern: "^0:0:(?:GET|HEAD):", ignoresCase: false, value: "\"\(realm)\""),
        Rule(pattern: "^0:0:[^:]+:.", ignoresCase: false, value: "\"\(realm)\""),
    ]

    // A POST without the password can hold _method=GET in its body. nginx cannot read the body
    // before the check of the password. Laravel and Symfony read X-HTTP-Method-Override before
    // _method. So the header POST keeps such a request a POST. A visitor with the password keeps
    // the _method of a form.
    static let methodRules = [
        Rule(pattern: "^off:POST$", ignoresCase: false, value: "POST"),
    ]

    private static func map(_ source: String, to name: String, default fallback: String = "0", rules: [Rule]) -> [String] {
        ["", "map \(source) \(name) {", "    default \(fallback);"] + rules.map { "    \($0.line)" } + ["}"]
    }

    // The server level of one share block: the refusals, the password and the named error pages. A
    // server level if with return runs before the choice of a location and before the password.
    // So a refused path gives 404 without a password. nginx treats an if with only a variable as
    // false only for an empty value and for 0. So a block without vite also refuses the value vite.
    public static func refusals(for share: ShareBlock) throws -> [String] {
        var lines = [
            "",
            "server_tokens off;",
            robotsLine,
        ]

        lines += refusal(share.vite == nil ? "$nexus_guard_hidden" : "$nexus_guard_hidden = 1")
        lines += refusal("$nexus_guard_bad_path")
        lines += refusal("$nexus_guard_vendor = 1")
        lines += share.composerInDocumentRoot ? refusal("$nexus_guard_vendor = composer") : []

        if let passwordFile = share.passwordFile {
            lines += [
                "",
                "auth_basic $nexus_guard_realm;",
                "auth_basic_user_file \(try ConfigText.quoted(passwordFile));",
            ]
        }

        guard share.options.hidesErrors else {
            return lines
        }

        lines += refusal("$nexus_guard_debug")
        lines += debugPathPattern(share.debugPaths).map { refusal("$uri ~* \"\(ConfigText.nginxQuoted($0))\"") } ?? []
        lines += refusal("$nexus_guard_xdebug_query")
        lines += refusal("$nexus_guard_xdebug_cookie")

        // nginx checks recursive_error_pages in the place of the first error page of a request. That
        // can be a 418 of 4e at this level or the 418 in a location of 4c. Without this line a 500
        // after such a 418 reaches the visitor.
        lines += [
            "",
            "recursive_error_pages on;",
            "",
            "location @nexus_guard_error {",
            "    default_type text/html;",
            "    add_header Cache-Control no-store always;",
            "    \(robotsLine)",
            "    return 500 \"\(ErrorPages.shareError)\";",
            "}",
            "",
            "location @nexus_guard_waits {",
            "    default_type text/html;",
            "    add_header Cache-Control no-store always;",
            "    add_header Retry-After 1 always;",
            "    \(robotsLine)",
            "    return 503 \"\(ErrorPages.shareWaits)\";",
            "}",
        ]

        return lines
    }

    private static func refusal(_ condition: String) -> [String] {
        ["", "if (\(condition)) {", "    return 404;", "}"]
    }

    // The lines at the end of each proxy location of a share block. They set the headers and replace
    // the error pages. nginx sends no header with an empty value. So an empty
    // value removes a header of the visitor. Cloudflare sets CF-Connecting-IP and replaces a value
    // of the visitor. 4c sets the X-Forwarded headers of the host. The error_page lines have no =.
    // So the visitor gets the status of the site. A location with its own error_page gets no
    // error_page of the server level. So these lines are in each location. The Vite location of 4e
    // passes keepsCookie false, because it sends no cookie to Vite.
    public static func answerLines(for share: ShareBlock, keepsCookie: Bool = true) -> [String] {
        var lines = [
            "proxy_set_header X-Forwarded-For $http_cf_connecting_ip;",
            "proxy_set_header X-Real-IP $http_cf_connecting_ip;",
            "proxy_set_header Client-IP \"\";",
            "proxy_set_header X-Client-IP \"\";",
            "proxy_set_header X-Cluster-Client-IP \"\";",
            "proxy_set_header True-Client-IP \"\";",
            "proxy_set_header X-Original-URL \"\";",
            "proxy_set_header X-Rewrite-URL \"\";",
        ]

        if share.passwordFile != nil {
            lines.append("proxy_set_header X-HTTP-Method-Override $nexus_guard_method;")
        }

        guard share.options.hidesErrors else {
            return lines
        }

        lines += [
            "proxy_intercept_errors on;",
            "error_page \(errorCodes.map(String.init).joined(separator: " ")) @nexus_guard_error;",
            "error_page \(waitCodes.map(String.init).joined(separator: " ")) @nexus_guard_waits;",
            "proxy_hide_header X-Powered-By;",
            "proxy_hide_header X-Debug-Token;",
            "proxy_hide_header X-Debug-Token-Link;",
            "proxy_hide_header X-Clockwork-Id;",
            "proxy_hide_header X-Clockwork-Version;",
            "proxy_hide_header X-Clockwork-Path;",
            "proxy_hide_header phpdebugbar-id;",
        ]

        return lines + (keepsCookie ? ["proxy_set_header Cookie $nexus_guard_cookie;"] : [])
    }

    // The values of 4d for each request of the link (overview, 4d). 4c writes them into the site
    // block of a PHP site in nginx with if_not_empty. REMOTE_ADDR is in ShareRewrite.fastcgiDefaults
    // of 4c. So a request that is not of the link keeps $remote_addr. A FastCGI value holds for one
    // request only. A visitor cannot send it.
    public static func fastcgiValues(for options: ShareOptions) -> [String: String] {
        let address = ["REMOTE_ADDR": ShareConfig.Header.visitor.variable]

        guard options.hidesErrors else {
            return address
        }

        return address.merging(hiddenErrorValues) { _, new in new }
    }

    // The values of "Hide error details and debug tools". A PHP site in nginx gets them as FastCGI
    // values and an Apache site through SetEnvIf. NEXUS_SHARE_HIDE_DUMPS keeps each dump out of the
    // page of a visitor (PageMode.php). Laravel with a cached config ignores the other values. So
    // APP_CONFIG_CACHE names a file that cannot exist. Laravel then reads the .env and the config
    // files for a request of the link.
    public static let hiddenErrorValues = [
        "APP_DEBUG": "false",
        "DEBUGBAR_ENABLED": "false",
        "CLOCKWORK_ENABLE": "false",
        "NEXUS_SHARE_HIDE_DUMPS": "1",
        "APP_CONFIG_CACHE": "/dev/null/nexus-share-config.php",
    ]

    // One line of the password file: {SSHA} of RFC 2307, which nginx reads. SHA-1 is enough here.
    // The password is random with about 79 bits. So a list of words does not help.
    public static func passwordLine(password: String, salt: [UInt8]) -> String {
        let digest = Data(Insecure.SHA1.hash(data: Data(password.utf8) + Data(salt)))
        return "\(passwordUser):{SSHA}\((digest + Data(salt)).base64EncodedString())\n"
    }

    // The custom paths from .env as part of a regular expression. A value with another character
    // than letters, digits and . _ ~ / - is left out. No valid value gives nil.
    static func debugPathPattern(_ paths: [String]) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~/-")
        let valid = paths.filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }

        guard !valid.isEmpty else {
            return nil
        }

        let names = valid.map(ConfigText.regexEscaped).joined(separator: "|")
        return "^\(hostPrefix)/(?:\(names))(?:/|$)"
    }
}
