import Darwin
import Foundation
import NexusCore
import NexusTestSupport
import Testing
@testable import NexusConfig

struct ShareViteRoutesTests {
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]
    private static let publicHost = "calm-river-tree-lamp.trycloudflare.com"

    private let settings = NginxSettings(httpPort: 8080, httpsPort: 8443, apachePort: 8081, lanAccess: false, runtime: URL(filePath: "/Nexus/runtimes/nginx/1.30", directoryHint: .isDirectory), runFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory), modules: [])

    private func share(port: Int = 18_000, vite: ShareViteTarget?, hidesErrors: Bool = true, logs: String = "/Nexus/logs") -> ShareBlock {
        var options = ShareOptions.standard
        options.hidesErrors = hidesErrors

        return ShareBlock(id: "\(port)".padding(toLength: 32, withPad: "0", startingAt: 0), host: "shop.test", port: port, mode: .publicHost, options: options, vite: vite, visitorLog: URL(filePath: "\(logs)/share-\(port).jsonl"))
    }

    private func laravel(hotText: String = "http://[::1]:20002", secure: Bool = false, port: Int = 20_002, project: String = "/Sites/shop") -> ShareViteTarget {
        ShareViteTarget(kind: .laravel(hotText: hotText, secure: secure, documentRoot: URL(filePath: "\(project)/public", directoryHint: .isDirectory)), port: port, projectFolder: URL(filePath: project, directoryHint: .isDirectory))
    }

    private func app(port: Int = 30_001, project: String = "/Sites/kit.app") -> ShareViteTarget {
        ShareViteTarget(kind: .app, port: port, projectFolder: URL(filePath: project, directoryHint: .isDirectory))
    }

    private func mapValue(_ map: [String], for input: String) throws -> String {
        for line in map.dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard trimmed.hasPrefix("\"") else {
                return String(trimmed.split(separator: " ").last?.dropLast() ?? "")
            }

            let end = try #require(trimmed.range(of: "\" ", options: .backwards))
            var pattern = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end.lowerBound]).replacingOccurrences(of: #"\\"#, with: #"\"#)
            var options: NSRegularExpression.Options = []

            if pattern.hasPrefix("~*") {
                options.insert(.caseInsensitive)
                pattern.removeFirst(2)
            } else {
                pattern.removeFirst()
            }

            let expression = try NSRegularExpression(pattern: pattern, options: options)

            if expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil {
                return String(trimmed[end.upperBound...].dropLast())
            }
        }

        return ""
    }

    // MARK: The lines

    @Test func aBlockWithoutViteGetsNoLines() throws {
        let block = share(vite: nil)

        #expect(try ShareViteRoutes.httpLines(for: [block]).isEmpty)
        #expect(try ShareViteRoutes.lines(for: block).isEmpty)
        #expect(ShareViteRoutes.siteLines(for: block).isEmpty)
    }

    @Test func twoLaravelBlocksGetEachMapOneTimeAndAnUpstreamForEachPort() throws {
        let lines = try ShareViteRoutes.httpLines(for: [share(port: 18_000, vite: laravel(port: 20_002)), share(port: 18_002, vite: laravel(port: 20_004)), share(port: 18_004, vite: nil)])
        let maps = lines.filter { $0.hasPrefix("map ") }

        #expect(maps == ["map $request_uri $nexus_vite_bad_uri {", "map $http_sec_websocket_protocol $nexus_vite_socket {", "map $uri $nexus_vite_fixed {", "map $uri $nexus_vite_source {"])
        #expect(lines.filter { $0.hasPrefix("upstream ") } == ["upstream nexus_share_vite_18000 {", "upstream nexus_share_vite_18002 {"])
        #expect(lines.contains("    server [::1]:20002;"))
        #expect(lines.contains("    server 127.0.0.1:20002 backup;"))
        #expect(lines.contains("    server [::1]:20004;"))
        #expect(lines.contains("    server 127.0.0.1:20004 backup;"))
        #expect(try #require(lines.firstIndex(of: "    server [::1]:20002;")) < #require(lines.firstIndex(of: "    server 127.0.0.1:20002 backup;")))
    }

    @Test func anAppBlockGetsItsOwnMapWithoutTheMapsOfLaravel() throws {
        let lines = try ShareViteRoutes.httpLines(for: [share(vite: app())])

        #expect(lines.filter { $0.hasPrefix("map ") } == ["map $http_sec_websocket_protocol $nexus_vite_socket {", "map $request_uri $nexus_vite_app_bad_uri {"])
        #expect(!lines.contains { $0.hasPrefix("upstream ") })
    }

    @Test func theLaravelLinesRefuseFirstAndSendOnlyFilesOfTheProjectToVite() throws {
        let lines = try ShareViteRoutes.lines(for: share(vite: laravel()))
        let order = [
            "error_page 418 = @nexus_vite;",
            "if ($nexus_vite_bad_uri) {",
            "if ($nexus_vite_socket) {",
            "if ($nexus_vite_fixed) {",
            "set $nexus_vite_file $nexus_vite_source;",
            #"if (-f "/Sites/shop/public$uri") {"#,
            #"if (!-f "/Sites/shop$uri") {"#,
            "if ($nexus_vite_file = 1) {",
            "location @nexus_vite {",
        ]
        let positions = order.compactMap { lines.firstIndex(of: $0) }

        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        #expect(lines.contains("    proxy_pass http://nexus_share_vite_18000;"))
        #expect(lines.contains("    proxy_set_header Host localhost;"))
        #expect(lines.contains(#"    proxy_set_header Cookie "";"#))
        #expect(lines.contains(#"    proxy_set_header Authorization "";"#))
        #expect(lines.contains(#"    proxy_set_header Accept-Encoding "";"#))
        #expect(lines.contains(#"    sub_filter "http://[::1]:20002" "https://$host";"#))
        #expect(lines.contains(#"    sub_filter "localhost:20002/" "$host/";"#))
        #expect(lines.contains("    sub_filter_once off;"))
        #expect(lines.contains("    sub_filter_last_modified on;"))
        #expect(lines.contains("    recursive_error_pages on;"))
        #expect(lines.last == "}")
    }

    @Test func withErrorDetailsTheViteLocationHasNoRecursiveErrorPages() throws {
        let lines = try ShareViteRoutes.lines(for: share(vite: laravel(), hidesErrors: false))

        #expect(!lines.contains("    recursive_error_pages on;"))
    }

    @Test func aSecureHotFileGivesAnUpstreamOverHTTPS() throws {
        let lines = try ShareViteRoutes.lines(for: share(vite: laravel(hotText: "https://shop.test:5173", secure: true, port: 5173)))

        #expect(lines.contains("    proxy_pass https://nexus_share_vite_18000;"))
        #expect(lines.contains(#"    sub_filter "https://shop.test:5173" "https://$host";"#))
    }

    @Test func aProjectFolderWithASpaceIsQuotedAndAFolderWithADollarSignIsRefused() throws {
        let lines = try ShareViteRoutes.lines(for: share(vite: laravel(project: "/Sites/my shop")))

        #expect(lines.contains(#"if (-f "/Sites/my shop/public$uri") {"#))
        #expect(lines.contains(#"if (!-f "/Sites/my shop$uri") {"#))
        #expect(throws: ConfigError.unsafePath("/Sites/$shop/public")) {
            try ShareViteRoutes.lines(for: share(vite: laravel(project: "/Sites/$shop")))
        }
        #expect(throws: ConfigError.unsafePath("/Sites/$kit")) {
            try ShareViteRoutes.lines(for: share(vite: app(project: "/Sites/$kit")))
        }
    }

    @Test func theAppLinesPassFSOnlyInsideTheEscapedProjectFolder() throws {
        let lines = try ShareViteRoutes.lines(for: share(vite: app(project: "/Sites/kit.app+one")))

        #expect(lines.contains("if ($nexus_vite_app_bad_uri) {"))
        #expect(lines.contains("if ($nexus_vite_socket) {"))
        #expect(lines.contains(#"if ($uri ~ "/@fs/") {"#))
        #expect(lines.contains(#"if ($uri ~ "^(/[A-Za-z0-9_-]+)?/@fs/Sites/kit\.app\+one/") {"#))
        #expect(lines.contains("if ($nexus_vite_fs) {"))
        #expect(!lines.contains { $0.contains("@nexus_vite") })
        #expect(ConfigText.regexEscaped("/a.b+c(d)|^") == #"/a\.b\+c\(d\)\|\^"#)
    }

    @Test func theSiteLinesChangeTheHotTextInHTMLAndJSONAndTheSocketOfAnApp() {
        #expect(ShareViteRoutes.siteLines(for: share(vite: laravel())) == [
            #"sub_filter "http://[::1]:20002" "https://$host";"#,
            #"sub_filter "http:\\/\\/[::1]:20002" "https:\\/\\/$host";"#,
        ])
        #expect(ShareViteRoutes.siteLines(for: share(vite: app())) == [#"sub_filter "localhost:30001/" "$host/";"#])
    }

    @Test func onlyAnAddressWithAPortAndSafeCharactersIsAHotText() {
        #expect(ShareViteRoutes.checkedHotText("http://[::1]:5173\n") == "http://[::1]:5173")
        #expect(ShareViteRoutes.checkedHotText("https://shop.test:5173/") == "https://shop.test:5173")
        #expect(ShareViteRoutes.checkedHotText("http://localhost:5173") == "http://localhost:5173")
        #expect(ShareViteRoutes.checkedHotText("http://localhost") == nil)
        #expect(ShareViteRoutes.checkedHotText("http://[::1]:5173/build") == nil)
        #expect(ShareViteRoutes.checkedHotText("http://evil$host:5173") == nil)
        #expect(ShareViteRoutes.checkedHotText(#"http://a";x:5173"#) == nil)
        #expect(ShareViteRoutes.checkedHotText("file:///etc:5173") == nil)
    }

    // MARK: The maps

    @Test(arguments: [
        "/.env", "/.env?raw", "/.env?vite-wasm-instance", "/resources/../storage/logs/laravel.log",
        "/resources/%2e%2e/composer.json", "/resources/%2E%2E/composer.json",
        "/node_modules/.vite/deps/../../../storage/logs/laravel.log", "/@fs/etc/hosts",
        "/@fs/Sites/shop/storage/logs/laravel.log", "/@id/__vite-browser-external:probe", "/@id//etc/hosts?raw",
        "/__open-in-editor?file=routes/web.php", "/resources/js/app.js.map", "/node_modules/.vite/deps/axios.js.map",
        "/resources\\app.js", "/resources/js/app.js%00", "/.git/config", "/node_modules/.vite/deps/.hidden.js",
    ])
    func eachUnsafePathOfLaravelIsRefused(_ path: String) throws {
        #expect(try mapValue(ShareViteRoutes.badURIMap, for: path) == "1")
    }

    @Test(arguments: ["/resources/js/app.js", "/resources/js/app.js?raw", "/node_modules/.vite/deps/axios.js?v=5f2b", "/.well-known/security.txt", "/@vite/client", "/composer.json", "/resources/js/app.js?import&t=.x"])
    func eachSafePathOfLaravelPasses(_ path: String) throws {
        #expect(try mapValue(ShareViteRoutes.badURIMap, for: path) == "0")
    }

    @Test func theFixedPathsAndTheSourceFilesGoToVite() throws {
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/@vite/client") == "1")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/@id/__x00__plugin-vue:export-helper") == "1")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/@id/virtual:pwa-register") == "1")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/@id/astro:scripts/page.js") == "0")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/node_modules/.vite/deps/axios.js") == "1")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/node_modules/.vite/deps/_metadata.json") == "0")
        #expect(try mapValue(ShareViteRoutes.fixedMap, for: "/__laravel_vite_plugin__/fonts/instrument-sans.woff2") == "1")
        #expect(try mapValue(ShareViteRoutes.sourceMap, for: "/resources/js/app.js") == "1")
        #expect(try mapValue(ShareViteRoutes.sourceMap, for: "/resources/views/welcome.blade.php") == "0")
        #expect(try mapValue(ShareViteRoutes.sourceMap, for: "/vendor/livewire/livewire/dist/livewire.esm.js") == "1")
        #expect(try mapValue(ShareViteRoutes.sourceMap, for: "/vendor/composer/installed.json") == "0")
        #expect(try mapValue(ShareViteRoutes.sourceMap, for: "/vendor/laravel/framework/src/Illuminate/Foundation/Vite.php") == "0")
        #expect(try mapValue(ShareViteRoutes.socketMap, for: "vite-hmr") == "1")
        #expect(try mapValue(ShareViteRoutes.socketMap, for: "Vite-Ping") == "1")
        #expect(try mapValue(ShareViteRoutes.socketMap, for: "graphql-ws") == "0")
    }

    @Test func anAppPassesItsGeneratedFilesAndSafeIDsBelowABase() throws {
        for path in ["/.svelte-kit/generated/client/app.js", "/_nuxt/@vite/client", "/@id/astro:scripts/page.js", "/_nuxt/node_modules/.vite/deps/vue.js?v=1", "/.well-known/x"] {
            #expect(try mapValue(ShareViteRoutes.appBadURIMap, for: path) == "0", "\(path)")
        }

        for path in ["/.env", "/_nuxt/__open-in-editor?file=x", "/@id/%2e%2e", "/@id/a b", "/.svelte-kit/output/server/index.js", "/.svelte-kit/generated/.x", "/src/app.js.map", "/@id/__vite-browser-external:fs"] {
            #expect(try mapValue(ShareViteRoutes.appBadURIMap, for: path) == "1", "\(path)")
        }
    }

    // MARK: The real nginx

    private struct RealSetup {
        let root: URL
        let project: URL
        let appFolder: URL
        let configFile: URL
        let nginx: URL
        let laravelPort: Int
        let appPort: Int
        let devPort: Int
        let requests: URL
    }

    private static func freePort() -> Int {
        while true {
            let port = Int.random(in: 50_001...60_000)

            if canBind(port, family: AF_INET), canBind(port, family: AF_INET6) {
                return port
            }
        }
    }

    private static func canBind(_ port: Int, family: Int32) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, 0)
        defer { close(descriptor) }

        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    private static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func realSetup() throws -> RealSetup {
        let root = URL(filePath: "/tmp/nxv-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let project = root.appending(path: "shop app", directoryHint: .isDirectory)
        let appFolder = root.appending(path: "kit", directoryHint: .isDirectory)
        let run = root.appending(path: "run", directoryHint: .isDirectory)
        let nginxFolder = URL(filePath: try #require(Self.realRuntimes)).appending(path: "nginx/1.30", directoryHint: .isDirectory)

        for file in ["resources/js/app.js", "resources/views/welcome.blade.php", "composer.json", ".env", "storage/logs/laravel.log", "vendor/composer/installed.json", "public/index.php"] {
            try Self.write("secret \(file)\n", to: project.appending(path: file))
        }

        for folder in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"] {
            try FileManager.default.createDirectory(at: run.appending(path: "nginx/\(folder)"), withIntermediateDirectories: true)
        }

        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        let devPort = Self.freePort()
        let laravelPort = Self.freePort()
        let appPort = Self.freePort()
        let settings = NginxSettings(httpPort: Self.freePort(), httpsPort: Self.freePort(), apachePort: 0, lanAccess: false, runtime: nginxFolder, runFolder: run, modules: [])
        let laravelBlock = share(port: laravelPort, vite: laravel(hotText: "http://[::1]:\(devPort)", port: devPort, project: RealPath.of(project)), logs: root.path(percentEncoded: false))
        let appBlock = share(port: appPort, vite: app(port: Self.freePort(), project: RealPath.of(appFolder)), logs: root.path(percentEncoded: false))
        let configFile = root.appending(path: "nginx.conf")

        try Self.write(try NginxConfig.render(sites: [], shares: [laravelBlock, appBlock], settings: settings), to: configFile)

        return RealSetup(root: root, project: project, appFolder: appFolder, configFile: configFile, nginx: nginxFolder.appending(path: "sbin/nginx"), laravelPort: laravelPort, appPort: appPort, devPort: devPort, requests: root.appending(path: "requests.txt"))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func start(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func waitForPort(_ port: Int) async -> Bool {
        for _ in 0..<200 {
            if !canBind(port, family: AF_INET) {
                return true
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    private static func devServer(port: Int, requests: URL) throws -> Process {
        let body = #"import "http://[::1]:\#(port)/resources/js/b.js"; const target = "localhost:\#(port)/";"#
        let script = #"use IO::Socket::INET; my ($port, $log, $body) = @ARGV; my $server = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $port, Listen => 16, ReuseAddr => 1) or die "bind: $!"; while (my $client = $server->accept) { my $head = ""; while (my $line = <$client>) { $head .= $line; last if $line eq "\r\n"; } open(my $file, ">>", $log); print $file $head; close($file); print $client "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n" . $body; close $client; }"#

        return try start(URL(filePath: "/usr/bin/perl"), ["-e", script, String(port), requests.path(percentEncoded: false), body])
    }

    private static func fetch(_ port: Int, _ path: String, headers: [String] = []) throws -> (status: Int, body: String) {
        let arguments = ["-s", "--path-as-is", "--http1.1", "--max-time", "5", "-H", "Host: \(publicHost)"] + headers.flatMap { ["-H", $0] } + ["-w", "\n%{http_code}", "http://127.0.0.1:\(port)\(path)"]
        let text = try run(URL(filePath: "/usr/bin/curl"), arguments).output
        let status = Int(text.split(separator: "\n").last ?? "") ?? 0

        return (status, String(text.dropLast(String(status).count + 1)))
    }

    private static let socketHeaders = ["Connection: Upgrade", "Upgrade: websocket", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(1)))
    func aRealNginxAcceptsALaravelBlockAndAnAppBlock() throws {
        let setup = try realSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let check = try Self.run(setup.nginx, ["-t", "-p", setup.root.path(percentEncoded: false), "-c", setup.configFile.path(percentEncoded: false), "-e", "stderr"])

        #expect(check.status == 0, "\(check.output)")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(1)))
    func aRealNginxRefusesEachUnsafePathAndSendsOnlyTheSourceFilesToTheDevServer() async throws {
        let setup = try realSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let devServer = try Self.devServer(port: setup.devPort, requests: setup.requests)
        let nginx = try Self.start(setup.nginx, ["-p", setup.root.path(percentEncoded: false), "-c", setup.configFile.path(percentEncoded: false), "-e", "stderr"])
        defer {
            nginx.terminate()
            devServer.terminate()
            nginx.waitForEnd()
            devServer.waitForEnd()
        }

        #expect(await Self.waitForPort(setup.laravelPort))
        #expect(await Self.waitForPort(setup.devPort))

        let refused = [
            "/.env", "/.env?raw", "/.env?vite-wasm-instance", "/resources/../storage/logs/laravel.log",
            "/resources/%2e%2e/composer.json", "/node_modules/.vite/deps/../../../storage/logs/laravel.log",
            "/@fs/etc/hosts", "/@fs\(RealPath.of(setup.project).replacingOccurrences(of: " ", with: "%20"))/storage/logs/laravel.log",
            "/@id/__vite-browser-external:probe", "/@id//etc/hosts?raw", "/__open-in-editor?file=routes/web.php",
            "/resources/js/app.js.map",
        ]
        let toTheSite = ["/storage/logs/laravel.log", "/composer.json", "/node_modules/.vite/deps/_metadata.json", "/resources/views/welcome.blade.php", "/vendor/composer/installed.json", "/vendor/laravel/framework/src/Illuminate/Foundation/Vite.php", "/index.html"]
        let appRefused = ["/@fs/etc/hosts", "/_nuxt/@fs/etc/hosts", "/.env", "/@id/a%20b"]

        for path in refused {
            let answer = try Self.fetch(setup.laravelPort, path)
            #expect([403, 404].contains(answer.status), "\(path): \(answer.status)")
            #expect(!answer.body.contains("secret"), "\(path)")
        }

        for path in toTheSite {
            let answer = try Self.fetch(setup.laravelPort, path)
            #expect(answer.status != 200, "\(path): \(answer.status)")
            #expect(!answer.body.contains("secret"), "\(path)")
        }

        for path in appRefused {
            let answer = try Self.fetch(setup.appPort, path)
            #expect(answer.status == 404, "\(path): \(answer.status)")
        }

        for protocolName in ["vite-hmr", "vite-ping"] {
            for origin in [[], ["Origin: https://\(Self.publicHost)"]] {
                #expect(try Self.fetch(setup.laravelPort, "/", headers: Self.socketHeaders + ["Sec-WebSocket-Protocol: \(protocolName)"] + origin).status == 403)
                #expect(try Self.fetch(setup.appPort, "/", headers: Self.socketHeaders + ["Sec-WebSocket-Protocol: \(protocolName)"] + origin).status == 403)
            }
        }

        let module = try Self.fetch(setup.laravelPort, "/resources/js/app.js", headers: ["Cookie: laravel_session=abc", "Authorization: Basic bmV4dXM6c2VjcmV0"])
        let raw = try Self.fetch(setup.laravelPort, "/resources/js/app.js?raw")
        let client = try Self.fetch(setup.laravelPort, "/@vite/client")
        let requests = (try? String(contentsOf: setup.requests, encoding: .utf8)) ?? ""
        let firstLines = requests.split(separator: "\r\n").filter { $0.hasPrefix("GET ") }

        #expect(module.status == 200)
        #expect(module.body == #"import "https://\#(Self.publicHost)/resources/js/b.js"; const target = "\#(Self.publicHost)/";"#)
        #expect(raw.status == 200)
        #expect(client.status == 200)
        #expect(firstLines == ["GET /resources/js/app.js HTTP/1.1", "GET /resources/js/app.js?raw HTTP/1.1", "GET /@vite/client HTTP/1.1"])
        #expect(requests.contains("Host: localhost\r\n"))
        #expect(!requests.localizedCaseInsensitiveContains("cookie"))
        #expect(!requests.localizedCaseInsensitiveContains("authorization"))
    }
}
