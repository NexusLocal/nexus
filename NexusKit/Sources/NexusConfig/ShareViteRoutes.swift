import Foundation
import NexusCore

// The lines of Live (group 4, 4e). The facts come from research 7. The share block sends the paths
// of Vite to the dev server of a Laravel site. A Node.js app gets only the refusals. Each socket of
// Vite gets 403, because it gives fetchModule to a visitor.
public enum ShareViteRoutes {
    // The raw path before the query decides. nginx reads \\\\ in a quoted value as \\, which the
    // regular expression reads as one backslash. The .map rule comes before the exception of
    // .vite/deps. So a map file in that folder also gets 404.
    static let badURIMap = [
        "map $request_uri $nexus_vite_bad_uri {",
        #"    "~*^[^?]*(\.\.|%2e|%2f|%5c|%00|%23|#|\\\\|//)" 1;"#,
        #"    "~*^[^?]*\.map(\?|$)" 1;"#,
        #"    "~^/node_modules/\.vite/deps/[^/?.][^/?]*(\?|$)" 0;"#,
        #"    "~^/\.well-known/" 0;"#,
        #"    "~^[^?]*/\." 1;"#,
        #"    "~^/(@fs/|__open-in-editor)" 1;"#,
        #"    "~*browser-external" 1;"#,
        "    default 0;",
        "}",
    ]

    static let socketMap = [
        "map $http_sec_websocket_protocol $nexus_vite_socket {",
        #"    "~*vite-(hmr|ping)" 1;"#,
        "    default 0;",
        "}",
    ]

    // The paths of Vite itself. The list below /node_modules/ is static files only.
    static let fixedMap = [
        "map $uri $nexus_vite_fixed {",
        #"    "~^/@vite/(client|env)$" 1;"#,
        #"    "~^/@react-refresh$" 1;"#,
        #"    "~^/@id/(__x00__|virtual:)[A-Za-z0-9_./:@-]+$" 1;"#,
        #"    "~*^/__laravel_vite_plugin__/fonts/[A-Za-z0-9_-]+\.(woff2?|ttf|otf|eot)$" 1;"#,
        #"    "~*^/node_modules/.+\.\#(ShareProtection.staticExtensions)$" 1;"#,
        "    default 0;",
        "}",
    ]

    // The source files that Vite serves. The list below /vendor/ is the static list of 4d.
    static let sourceMap = [
        "map $uri $nexus_vite_source {",
        #"    "~*^/resources/.+\.(m?js|cjs|ts|mts|tsx|jsx|vue|svelte|css|scss|sass|less|styl|pcss|postcss|json|svg|png|jpe?g|gif|webp|avif|ico|woff2?|ttf|otf|eot|mp4|webm|mp3|wav)$" 1;"#,
        #"    "~*^/vendor/.+\.\#(ShareProtection.staticExtensions)$" 1;"#,
        "    default 0;",
        "}",
    ]

    // An app can serve below a base, for example /_nuxt/@vite/client. It passes each /@id/ with safe
    // characters and .svelte-kit/generated/ (owner, 4e question 2).
    static let appBadURIMap = [
        "map $request_uri $nexus_vite_app_bad_uri {",
        #"    "~*^[^?]*(\.\.|%2e|%2f|%5c|%00|%23|#|\\\\|//)" 1;"#,
        #"    "~*^[^?]*\.map(\?|$)" 1;"#,
        #"    "~^[^?]*/__open-in-editor" 1;"#,
        #"    "~*browser-external" 1;"#,
        #"    "~^[^?]*/@id/[^?]*[^A-Za-z0-9_./:@?-]" 1;"#,
        #"    "~^/\.well-known/" 0;"#,
        #"    "~^[^?]*/node_modules/\.vite/deps/[^/?.][^/?]*(\?|$)" 0;"#,
        #"    "~^[^?]*/\.svelte-kit/generated/([^/?.][^/?]*/)*[^/?.][^/?]*(\?|$)" 0;"#,
        #"    "~^[^?]*/\." 1;"#,
        "    default 0;",
        "}",
    ]

    // The http block: the maps one time and one upstream for each Laravel block. The upstream has
    // the port of the share block in its name, because that port is unique for each open link. The
    // dev server listens on [::1] or on 127.0.0.1. A host in public/hot never becomes a target.
    public static func httpLines(for shares: [ShareBlock]) throws -> [String] {
        let targets = shares.compactMap { share in share.vite.map { (share: share, vite: $0) } }

        guard !targets.isEmpty else {
            return []
        }

        let laravel = targets.filter { $0.vite.kind != .app }
        let hasApp = targets.contains { $0.vite.kind == .app }
        var lines = [""]

        if !laravel.isEmpty {
            lines += badURIMap + [""]
        }

        lines += socketMap + [""]

        if !laravel.isEmpty {
            lines += fixedMap + [""] + sourceMap + [""]
        }

        if hasApp {
            lines += appBadURIMap + [""]
        }

        for (share, vite) in laravel {
            lines += [
                "upstream \(upstreamName(of: share)) {",
                "    server [::1]:\(vite.port);",
                "    server 127.0.0.1:\(vite.port) backup;",
                "}",
                "",
            ]
        }

        return lines
    }

    // The server level. A return in a server-level if runs before nginx chooses a location. So the
    // redirect to @nexus_vite uses the error_page of the server level. The location has no
    // add_header line. So the headers of 4d at the server level reach it.
    public static func lines(for share: ShareBlock) throws -> [String] {
        guard let vite = share.vite else {
            return []
        }

        guard case .laravel(let hotText, let secure, let documentRoot) = vite.kind else {
            return try appLines(projectFolder: vite.projectFolder)
        }

        var lines = [
            "",
            "error_page 418 = @nexus_vite;",
            "",
            "if ($nexus_vite_bad_uri) {",
            "    return 404;",
            "}",
            "",
            "if ($nexus_vite_socket) {",
            "    return 403;",
            "}",
            "",
            "if ($nexus_vite_fixed) {",
            "    return 418;",
            "}",
            "",
            "set $nexus_vite_file $nexus_vite_source;",
            "",
            "if (-f \(try quotedStart(of: documentRoot))$uri\") {",
            "    set $nexus_vite_file 0;",
            "}",
            "",
            "if (!-f \(try quotedStart(of: vite.projectFolder))$uri\") {",
            "    set $nexus_vite_file 0;",
            "}",
            "",
            "if ($nexus_vite_file = 1) {",
            "    return 418;",
            "}",
            "",
            "location @nexus_vite {",
            "    proxy_pass \(secure ? "https" : "http")://\(upstreamName(of: share));",
            "    proxy_http_version 1.1;",
            "    proxy_set_header Host localhost;",
            "    proxy_set_header Accept-Encoding \"\";",
            "    proxy_set_header Cookie \"\";",
            "    proxy_set_header Authorization \"\";",
            "    proxy_set_header Connection \"\";",
            "    proxy_read_timeout 60;",
            "    sub_filter_types text/javascript application/javascript text/css;",
            "    sub_filter \"\(hotText)\" \"https://$host\";",
            "    sub_filter \"localhost:\(vite.port)/\" \"$host/\";",
            "    sub_filter_once off;",
            "    sub_filter_last_modified on;",
        ]

        lines += ShareRewrite.viteLines(for: share).map { "    \($0)" }

        // nginx checks this setting in the place of the first error page. 4d writes it at the
        // server level too, because the 418 of the server level is that first error page.
        if share.options.hidesErrors {
            lines.append("    recursive_error_pages on;")
        }

        // The cookie lines of 4d would undo Cookie "".
        lines += ShareProtection.answerLines(for: share, keepsCookie: false).map { "    \($0)" }
        lines.append("}")
        return lines
    }

    // The lines in location / after the lines of 4c. 4c writes sub_filter_types, sub_filter_once
    // and Accept-Encoding there. nginx gives sub_filter of the server level to no location with its
    // own sub_filter lines. Livewire sends HTML inside JSON. So the text of public/hot also comes in
    // its JSON form. The client of Vite of an app then tries its fallback socket on the public host.
    public static func siteLines(for share: ShareBlock) -> [String] {
        guard let vite = share.vite else {
            return []
        }

        guard case .laravel(let hotText, _, _) = vite.kind else {
            return ["sub_filter \"localhost:\(vite.port)/\" \"$host/\";"]
        }

        let jsonText = hotText.replacingOccurrences(of: "/", with: #"\\/"#)

        return [
            "sub_filter \"\(hotText)\" \"https://$host\";",
            #"sub_filter "\#(jsonText)" "https:\\/\\/$host";"#,
        ]
    }

    // The text of public/hot that Live accepts: an http or https address with a port and without a
    // path. Its characters are letters, digits and : / . [ ] _ -. So it needs no escape in nginx.
    // Returns the text without white space and without a slash at its end.
    public static func checkedHotText(_ contents: String) -> String? {
        var text = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasSuffix("/") {
            text.removeLast()
        }

        guard text.wholeMatch(of: #/https?:\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):[0-9]{1,5}/#) != nil else {
            return nil
        }

        return text
    }

    static func upstreamName(of share: ShareBlock) -> String {
        "nexus_share_vite_\(share.port)"
    }

    // An app passes /@fs/ only inside its own project folder, also below a base such as /_nuxt.
    private static func appLines(projectFolder: URL) throws -> [String] {
        let folder = RealPath.trimmed(projectFolder.path(percentEncoded: false))
        _ = try ConfigText.quoted(URL(filePath: folder))

        return [
            "",
            "if ($nexus_vite_app_bad_uri) {",
            "    return 404;",
            "}",
            "",
            "if ($nexus_vite_socket) {",
            "    return 403;",
            "}",
            "",
            "set $nexus_vite_fs 0;",
            "",
            "if ($uri ~ \"/@fs/\") {",
            "    set $nexus_vite_fs 1;",
            "}",
            "",
            "if ($uri ~ \"^(/[A-Za-z0-9_-]+)?/@fs\(ConfigText.regexEscaped(folder))/\") {",
            "    set $nexus_vite_fs 0;",
            "}",
            "",
            "if ($nexus_vite_fs) {",
            "    return 404;",
            "}",
        ]
    }

    // The quoted path without the quote at its end. $uri" follows it.
    private static func quotedStart(of folder: URL) throws -> String {
        let quoted = try ConfigText.quoted(URL(filePath: RealPath.trimmed(folder.path(percentEncoded: false))))
        return String(quoted.dropLast())
    }
}
