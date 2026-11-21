import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

// The protection of visitors with the real nginx and PHP (group 4, 4d), only when
// NEXUS_REAL_RUNTIMES names a runtimes folder. No test opens a tunnel. Each request comes to the
// share block on 127.0.0.1 with the header that Cloudflare sets.
@Suite(.serialized)
struct ShareProtectionRealTests {
    private let base = NexusEngineTests()
    private static let visitor = "203.0.113.7"

    struct Answer {
        let status: Int
        let headers: [String: String]
        let body: String

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    private struct Fixture {
        let root: URL
        let paths: NexusPaths
        let engine: NexusEngine
        let project: URL
        let httpsPort: Int
    }

    // OPcache puts the value of ini_get('name') into the cached code when the pool locks the setting.
    // The cache serves each pool. So the script reads each setting through a variable.
    private static let index = """
        <?php
        $setting = fn (string $name) => ini_get($name);
        header('Content-Type: application/json');
        echo json_encode([
            'REMOTE_ADDR' => $_SERVER['REMOTE_ADDR'] ?? null,
            'HTTP_X_FORWARDED_FOR' => $_SERVER['HTTP_X_FORWARDED_FOR'] ?? null,
            'HTTP_CLIENT_IP' => $_SERVER['HTTP_CLIENT_IP'] ?? null,
            'HTTP_COOKIE' => $_SERVER['HTTP_COOKIE'] ?? null,
            'HTTP_X_HTTP_METHOD_OVERRIDE' => $_SERVER['HTTP_X_HTTP_METHOD_OVERRIDE'] ?? null,
            'DEBUGBAR_ENABLED' => $_SERVER['DEBUGBAR_ENABLED'] ?? null,
            'APP_CONFIG_CACHE' => $_SERVER['APP_CONFIG_CACHE'] ?? null,
            'APP_DEBUG' => $_SERVER['APP_DEBUG'] ?? null,
            'NEXUS_SHARE_HIDE_DUMPS' => $_SERVER['NEXUS_SHARE_HIDE_DUMPS'] ?? null,
            'display_errors' => $setting('display_errors'),
            'start_with_request' => $setting('xdebug.start_with_request'),
            'marker' => 'index of the site',
        ]);

        """

    private static let files = [
        "index.php": index,
        "warn.php": "<?php\necho $undefinedVariable;\necho 'done';\n",
        "status.php": "<?php\nhttp_response_code((int) ($_GET['code'] ?? 200));\necho 'detail of the site';\n",
        "secret.php": "<?php\n// secret source text\necho 'secret ran';\n",
        "info.PHP": "<?php\n// info source text\necho 'info ran';\n",
        "vendor/autoload.php": "<?php\necho 'vendor ran';\n",
        "vendor/phpunit/x/eval.php": "<?php\necho 'eval ran';\n",
        "vendor/x/app.css": "body { color: red; }\n",
        ".env": "APP_KEY=base64:secret-of-the-site\n",
        "node_modules/.vite/deps/x.js": "export const secret = 'vite file';\n",
        "dump.sql": "INSERT INTO users VALUES ('secret row');\n",
        "adminer.php": "<?php\necho 'adminer ran';\n",
    ]

    private static func paths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
    }

    private func fixture(hosts: [String] = ["shop.test", "blog.test", "pass.test"], phpIni: String? = nil, apache: Bool = false) async throws -> Fixture {
        let root = shortTemporaryRoot()
        let paths = Self.paths(root)
        try paths.createFolders()
        try base.linkRealRuntimes(in: paths, ["nginx/1.30", "php/8.5"] + (apache ? ["httpd/2.4"] : []))

        let httpsPort = base.freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = base.freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()

        if apache {
            state.ports[ServiceCatalog.apacheID] = base.freePort()
        }
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        if let phpIni {
            let folder = paths.phpConfigFolder(line: "8.5")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(phpIni.utf8).write(to: folder.appending(path: "php.ini"))
        }

        let projects = root.appending(path: "projects", directoryHint: .isDirectory)

        for host in hosts {
            let folder = projects.appending(path: host, directoryHint: .isDirectory)

            for (name, text) in Self.files {
                let file = folder.appending(path: name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
        }

        let engine = NexusEngine(
            paths: paths,
            helper: base.helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: base.keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )

        return Fixture(root: root, paths: paths, engine: engine, project: projects, httpsPort: httpsPort)
    }

    private func addSites(_ fixture: Fixture, _ hosts: [String], server: WebServer = .nginx) async throws {
        for host in hosts {
            _ = await fixture.engine.handle(.addSite(folder: fixture.project.appending(path: host).path(percentEncoded: false), host: host, aliases: [], php: "8.5", server: server))
        }

        for host in hosts {
            let page = await eventually(seconds: 20) { await base.curl(["https://\(host):\(fixture.httpsPort)/"], host: host, port: fixture.httpsPort, seconds: 5).contains("index of the site") }
            try #require(page, "\(host) does not answer")
        }
    }

    private func openLinks(_ fixture: Fixture, _ links: [(host: String, options: ShareOptions)]) async throws -> [String: (port: Int, password: String?)] {
        var records: [ShareRecord] = []
        var opened: [String: (port: Int, password: String?)] = [:]

        for (index, link) in links.enumerated() {
            let id = String(format: "%032x", index + 1)
            let port = base.freePort()
            let password = link.options.password ? try await fixture.engine.writeSharePassword(id) : nil
            records.append(ShareRecord(id: id, host: link.host, site: link.host, options: link.options, mode: .localHost, password: password, port: port, started: .now, state: .open))
            opened[link.host] = (port, password)
        }

        try await fixture.engine.stateStore.update { $0.shares = records }
        let engine = fixture.engine
        _ = try await engine.serialWeb { try await engine.applyWeb(.shares) }

        for (host, link) in opened {
            let answers = await eventually(seconds: 10) { await request(link.port, "/").status != 0 }
            try #require(answers, "The share block of \(host) does not answer")
        }

        return opened
    }

    private func eventually(seconds: Int, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)

        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        return false
    }

    private func request(_ port: Int, _ target: String, method: String = "GET", headers: [String] = [], body: String? = nil, user: String? = nil, visitor: Bool = true) async -> Answer {
        var arguments = ["-s", "--max-time", "10", "--request-target", target] + (method == "HEAD" ? ["-I"] : ["-i", "-X", method])
        arguments += (visitor ? ["CF-Connecting-IP: \(Self.visitor)"] : []).flatMap { ["-H", $0] }
        arguments += headers.flatMap { ["-H", $0] }
        arguments += body.map { ["--data-binary", $0] } ?? []
        arguments += user.map { ["-u", $0] } ?? []
        arguments.append("http://127.0.0.1:\(port)")
        return Self.answer(Self.run("/usr/bin/curl", arguments))
    }

    private func siteRequest(_ fixture: Fixture, host: String, _ path: String, arguments: [String] = []) -> Answer {
        Self.answer(Self.run("/usr/bin/curl", ["-sk", "-i", "--max-time", "10", "--path-as-is", "--resolve", "\(host):\(fixture.httpsPort):127.0.0.1"] + arguments + ["https://\(host):\(fixture.httpsPort)\(path)"]))
    }

    private static func run(_ program: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func answer(_ raw: String) -> Answer {
        guard let end = raw.range(of: "\r\n\r\n") else {
            return Answer(status: 0, headers: [:], body: raw)
        }

        let lines = raw[..<end.lowerBound].components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }

            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        return Answer(status: status, headers: headers, body: String(raw[end.upperBound...]))
    }

    private func json(_ answer: Answer) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(answer.body.utf8)) as? [String: Any] else {
            return [:]
        }

        return object.compactMapValues { $0 as? String }
    }

    private func isOff(_ value: String?) -> Bool {
        ["", "0", "off", "Off"].contains(value ?? "")
    }

    private func options(hidesErrors: Bool = true, password: Bool = false) -> ShareOptions {
        var options = ShareOptions.standard
        options.hidesErrors = hidesErrors
        options.password = password
        return options
    }

    private func checkRobots(_ answer: Answer, _ name: String) {
        #expect(answer.header("X-Robots-Tag") == "noindex, nofollow", "\(name)")
        #expect(answer.header("Server") == "nginx", "\(name)")
        #expect(answer.header("X-Powered-By") == nil, "\(name)")
    }

    // MARK: R1

    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(2)))
    func theRealNginxAcceptsABlockWithAllOptionsAndABlockWithoutOptions() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nginx = URL(filePath: NexusEngineTests.realRuntimes!).appending(path: "nginx/1.30", directoryHint: .isDirectory)
        let run = root.appending(path: "run", directoryHint: .isDirectory)
        let config = root.appending(path: "nginx.conf")
        let settings = NginxSettings(httpPort: base.freePort(), httpsPort: base.freePort(), apachePort: 0, lanAccess: false, runtime: nginx, runFolder: run, modules: [])
        var all = ShareOptions.standard
        all.password = true
        var none = ShareOptions.standard
        none.hidesErrors = false
        let shares = [
            ShareBlock(id: String(repeating: "a", count: 32), host: "shop.test", port: 18_700, mode: .localHost, options: all, vite: ShareViteTarget(kind: .laravel(hotText: "http://[::1]:5173", secure: false, documentRoot: root.appending(path: "shop/public", directoryHint: .isDirectory)), port: 5173, projectFolder: root.appending(path: "shop", directoryHint: .isDirectory)), passwordFile: root.appending(path: "share/a.htpasswd"), visitorLog: root.appending(path: "a.jsonl"), debugPaths: ["admin/telescope", "ops.horizon"], composerInDocumentRoot: true),
            ShareBlock(id: String(repeating: "b", count: 32), host: "blog.test", port: 18_701, mode: .localHost, options: none, visitorLog: root.appending(path: "b.jsonl")),
        ]

        for folder in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"] {
            try FileManager.default.createDirectory(at: run.appending(path: "nginx/\(folder)"), withIntermediateDirectories: true)
        }

        try Data(try NginxConfig.render(sites: [], shares: shares, settings: settings).utf8).write(to: config)
        let output = Self.checkOutput(nginx.appending(path: "sbin/nginx"), ["-t", "-p", root.path(percentEncoded: false), "-c", config.path(percentEncoded: false), "-e", "stderr"])

        #expect(output.status == 0, "\(output.text)")
        #expect(!output.text.contains("[warn]"), "\(output.text)")
    }

    private static func checkOutput(_ program: URL, _ arguments: [String]) -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: R2 to R7, R9 and R10

    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(4)))
    func theShareBlockProtectsVisitorsAndTheMac() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await base.whileRunning(fixture.engine) {
            try await addSites(fixture, ["shop.test", "blog.test", "pass.test"])
            let links = try await openLinks(fixture, [
                ("shop.test", options()),
                ("blog.test", options(hidesErrors: false)),
                ("pass.test", options(password: true)),
            ])
            let shop = try #require(links["shop.test"]?.port)
            let blog = try #require(links["blog.test"]?.port)
            let pass = try #require(links["pass.test"]?.port)
            let password = try #require(links["pass.test"]?.password)
            let config = try String(contentsOf: fixture.paths.nginxConfig, encoding: .utf8)

            try await oneSiteOnly(shop: shop)
            try await refusedPaths(fixture, shop: shop, blog: blog)
            try await plainPages(shop: shop, blog: blog)
            await phpWarnings(fixture, shop: shop)
            await addressAndValues(fixture, shop: shop, config: config)
            await passwordRules(pass: pass, password: password)
        }
    }

    private func oneSiteOnly(shop: Int) async throws {
        let otherHost = await request(shop, "/", headers: ["Host: other.test"])
        let absolute = await request(shop, "http://127.0.0.1:\(shop)/")

        #expect(json(otherHost)["marker"] == "index of the site", "\(otherHost.body)")
        #expect(json(absolute)["marker"] == "index of the site", "\(absolute.body)")
    }

    // nginx answers 400 itself for a path above the root.
    private func refusedPaths(_ fixture: Fixture, shop: Int, blog: Int) async throws {
        let refused = [
            "/.env", "/%2eenv", "/%2Eenv", "/.ENV", "/.%45NV", "/a/../.env", "/a/%2e%2e/.env", "/a/./.env", "/.git/config",
            "/vendor/autoload.php", "/VENDOR/autoload.php", "/%76endor/autoload.php", "/vendor%2Fautoload.php", "/Vendor/Autoload.PHP",
            "/vendor/phpunit/x/eval.php", "/vendor/phpunit/x/eval.php/a.js", "/vendor/phpunit/x/EVAL.PHP",
            "/_dusk/login/1", "/_DUSK/login/1", "/%5Fdusk/login/1", "/telescope", "/Telescope/requests", "/%74elescope",
            "/node_modules/.vite/deps/x.js", "/node_modules/%2Evite/deps/x.js",
            "/dump.sql", "/DUMP.SQL", "/dump%2Esql", "/adminer.php", "/Adminer.PHP",
            "/SECRET.PHP", "/secret.Php", "/secret.%50HP", "/secret%2EPHP",
            "/__nextjs_launch-editor", "/__open-in-editor", "/PHPINFO.php", "/app.js.map",
            "/a\\b", "/a%5Cb", "/a%00.php", "/..%2f.env",
        ]
        let secrets = ["secret-of-the-site", "vendor ran", "eval ran", "vite file", "secret row", "adminer ran", "secret source text", "secret ran", "index of the site"]

        for path in refused {
            let answer = await request(shop, path)

            #expect([400, 404].contains(answer.status), "\(path): \(answer.status)")
            #expect(!secrets.contains(where: answer.body.contains), "\(path): \(answer.body)")

            if answer.status == 404 {
                checkRobots(answer, path)
            }
        }

        let style = await request(shop, "/vendor/x/app.css")
        let root = await request(shop, "/")
        let siteSource = siteRequest(fixture, host: "shop.test", "/SECRET.PHP")
        let siteDump = siteRequest(fixture, host: "shop.test", "/dump.sql")
        let siteTelescope = siteRequest(fixture, host: "shop.test", "/telescope")
        let telescopeWithoutOption = await request(blog, "/telescope")

        #expect(style.status == 200)
        #expect(style.body.contains("color: red"))
        #expect(root.status == 200)
        checkRobots(style, "/vendor/x/app.css")
        checkRobots(root, "/")
        #expect(siteSource.status == 403, "nginx on macOS ignores case in a location. So PHP-FPM refuses /SECRET.PHP in the site block.")
        #expect(!siteSource.body.contains("secret source text"))
        #expect(siteDump.body.contains("secret row"))
        #expect(siteTelescope.body.contains("index of the site"))
        #expect(telescopeWithoutOption.body.contains("index of the site"))
    }

    private func plainPages(shop: Int, blog: Int) async throws {
        for code in [500, 507, 599] {
            let answer = await request(shop, "/status.php?code=\(code)")

            #expect(answer.status == code, "\(code)")
            #expect(answer.body == ErrorPages.shareError, "\(code): \(answer.body)")
            #expect(answer.header("Cache-Control") == "no-store", "\(code)")
            checkRobots(answer, "\(code)")
        }

        for code in [502, 503, 504] {
            let answer = await request(shop, "/status.php?code=\(code)")

            #expect(answer.status == code, "\(code)")
            #expect(answer.body == ErrorPages.shareWaits, "\(code): \(answer.body)")
            #expect(answer.header("Retry-After") == "1", "\(code)")
            checkRobots(answer, "\(code)")
        }

        for code in [500, 503, 507] {
            let answer = await request(blog, "/status.php?code=\(code)")

            #expect(answer.status == code, "\(code)")
            #expect(answer.body.contains("detail of the site"), "\(code): \(answer.body)")
        }

        let notFound = await request(shop, "/status.php?code=404")
        #expect(notFound.status == 404)
        #expect(notFound.body.contains("detail of the site"))
    }

    private func phpWarnings(_ fixture: Fixture, shop: Int) async {
        let throughLink = await request(shop, "/warn.php")
        let folder = fixture.project.path(percentEncoded: false)

        #expect(throughLink.status == 200)
        #expect(throughLink.body.contains("done"))
        #expect(!throughLink.body.contains("Warning"), "\(throughLink.body)")
        #expect(!throughLink.body.contains(folder))

        for attempt in 1...20 {
            let local = siteRequest(fixture, host: "shop.test", "/warn.php")
            #expect(local.body.contains("Warning"), "\(attempt): \(local.body)")
        }
    }

    // 4c writes the FastCGI values of the link into the site block.
    private func addressAndValues(_ fixture: Fixture, shop: Int, config: String) async {
        let link = json(await request(shop, "/index.php", headers: ["X-Forwarded-For: 127.0.0.1", "Client-IP: 127.0.0.1", "X-Real-IP: 127.0.0.1", "Cookie: a=1; XDEBUG_SESSION=1"]))
        let local = json(siteRequest(fixture, host: "shop.test", "/index.php"))
        let thirdTrigger = await request(shop, "/index.php", headers: ["Cookie: XDEBUG_SESSION=1; XDEBUG_TRIGGER=1; XDEBUG_SESSION=2"])

        #expect(isOff(link["display_errors"]), "\(link)")
        #expect(link["HTTP_X_FORWARDED_FOR"] == Self.visitor, "\(link)")
        #expect(link["HTTP_CLIENT_IP"] == nil, "\(link)")
        #expect(link["HTTP_COOKIE"] == "a=1", "\(link)")
        #expect(thirdTrigger.status == 404)
        #expect(!isOff(local["display_errors"]), "\(local)")
        #expect(local["APP_DEBUG"] == nil)
        #expect(local["NEXUS_SHARE_HIDE_DUMPS"] == nil)

        #expect(config.contains("fastcgi_param REMOTE_ADDR $nexus_share_"))
        #expect(link["REMOTE_ADDR"] == Self.visitor, "\(link)")
        #expect(link["APP_DEBUG"] == "false", "\(link)")
        #expect(link["NEXUS_SHARE_HIDE_DUMPS"] == "1", "\(link)")
        #expect(local["REMOTE_ADDR"] == "127.0.0.1", "\(local)")
    }

    private func passwordRules(pass: Int, password: String) async {
        let credentials = "nexus:\(password)"
        let get = await request(pass, "/")
        let head = await request(pass, "/", method: "HEAD")
        let withPassword = await request(pass, "/", user: credentials)
        let wrong = await request(pass, "/", user: "nexus:k7mq-2xfh-9pwd-r4tc")
        let post = await request(pass, "/", method: "POST", body: "a=1")
        let override = await request(pass, "/", method: "POST", headers: ["X-HTTP-Method-Override: GET"], body: "a=1")
        let methodField = await request(pass, "/?_method=GET", method: "POST", body: "a=1")
        let options = await request(pass, "/", method: "OPTIONS")
        let login = await request(pass, "/wp-login.php", method: "POST", body: "log=admin&pwd=password")
        let caseLogin = await request(pass, "/WP-Login.php", method: "POST", body: "log=admin")
        let upperLogin = await request(pass, "/WP-LOGIN.PHP", method: "POST", body: "log=admin")
        let xmlrpc = await request(pass, "/xmlrpc.php", method: "POST", body: "<x/>")
        let admin = await request(pass, "/wp-admin/plugin-install.php", method: "POST", body: "a=1")
        let ajax = await request(pass, "/wp-admin/admin-ajax.php", method: "POST", body: "action=x")
        let refused = await request(pass, "/.env")
        let bodyOverride = await request(pass, "/index.php", method: "POST", body: "_method=GET")
        let formOfVisitor = await request(pass, "/index.php", method: "POST", body: "_method=DELETE", user: credentials)
        let wrongOnPost = await request(pass, "/index.php", method: "POST", body: "a=1", user: "nexus:k7mq-2xfh-9pwd-r4tc")
        let webhook = await request(pass, "/index.php", method: "POST", body: "_method=GET", user: "AC123:webhook-secret")
        let webhookGet = await request(pass, "/index.php", user: "AC123:webhook-secret")

        #expect(get.status == 401)
        #expect(get.header("WWW-Authenticate") == "Basic realm=\"Nexus\"")
        #expect(head.status == 401)
        #expect(withPassword.status == 200)
        #expect(json(withPassword)["marker"] == "index of the site")
        #expect(wrong.status == 401)
        #expect(post.status == 200)
        #expect(override.status == 401)
        #expect(methodField.status == 401)
        #expect(options.status != 401)
        #expect(login.status == 401)
        #expect(caseLogin.status == 401)
        #expect(upperLogin.status == 404)
        #expect(xmlrpc.status == 401)
        #expect(admin.status == 401)
        #expect(ajax.status != 401)
        #expect(refused.status == 404)
        #expect(bodyOverride.status == 200)
        #expect(json(bodyOverride)["HTTP_X_HTTP_METHOD_OVERRIDE"] == "POST", "\(bodyOverride.body)")
        #expect(formOfVisitor.status == 200)
        #expect(json(formOfVisitor)["HTTP_X_HTTP_METHOD_OVERRIDE"] == nil, "\(formOfVisitor.body)")
        #expect(wrongOnPost.status == 401)
        #expect(webhook.status == 200)
        #expect(json(webhook)["HTTP_X_HTTP_METHOD_OVERRIDE"] == "POST", "\(webhook.body)")
        #expect(webhookGet.status == 401)

        for (name, answer) in [("GET", get), ("POST", post), ("login", login), ("refused", refused)] {
            checkRobots(answer, name)
        }
    }

    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(3)))
    func anApacheSiteGetsTheValuesAndThePoolOfHiddenErrors() async throws {
        let fixture = try await fixture(hosts: ["apache.test"], apache: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await base.whileRunning(fixture.engine) {
            try await addSites(fixture, ["apache.test"], server: .apache)
            let links = try await openLinks(fixture, [("apache.test", options())])
            let port = try #require(links["apache.test"]?.port)
            let hidden = await eventually(seconds: 10) { await json(request(port, "/index.php"))["APP_DEBUG"] == "false" }
            let link = json(await request(port, "/index.php"))
            let warning = await request(port, "/warn.php")
            let local = json(siteRequest(fixture, host: "apache.test", "/index.php"))
            let localWarning = siteRequest(fixture, host: "apache.test", "/warn.php")

            #expect(hidden, "\(link)")
            #expect(link["DEBUGBAR_ENABLED"] == "false", "\(link)")
            #expect(link["NEXUS_SHARE_HIDE_DUMPS"] == "1", "\(link)")
            #expect(link["APP_CONFIG_CACHE"] == ShareProtection.hiddenErrorValues["APP_CONFIG_CACHE"], "\(link)")
            #expect(link["REMOTE_ADDR"] == Self.visitor, "\(link)")
            #expect(isOff(link["display_errors"]), "\(link)")
            #expect(warning.body.contains("done"))
            #expect(!warning.body.contains("Warning"), "\(warning.body)")
            #expect(local["APP_DEBUG"] == nil, "\(local)")
            #expect(!isOff(local["display_errors"]), "\(local)")
            #expect(localWarning.body.contains("Warning"), "\(localWarning.body)")
        }
    }

    // The site block without a link, as each device of the LAN reaches it. APFS finds a file
    // through each case variant of its name.
    @Test(.enabled(if: NexusEngineTests.realRuntimes != nil), .timeLimit(.minutes(3)))
    func aPHPFileWithAnExtensionInCapitalsShowsNoSourceInNginxOrInApache() async throws {
        let fixture = try await fixture(hosts: ["shop.test", "apache.test"], apache: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await base.whileRunning(fixture.engine) {
            try await addSites(fixture, ["shop.test"])
            try await addSites(fixture, ["apache.test"], server: .apache)

            for host in ["shop.test", "apache.test"] {
                for path in ["/info.PHP", "/SECRET.PHP", "/secret.Php", "/Secret.pHp?a=1", "/info.PHP/x", "/secret.PHP/x.js"] {
                    let answer = siteRequest(fixture, host: host, path)

                    #expect(!answer.body.contains("source text"), "\(host)\(path) gives \(answer.status): \(answer.body)")
                    #expect([403, 404].contains(answer.status), "\(host)\(path) gives \(answer.status): \(answer.body)")
                }

                let secret = siteRequest(fixture, host: host, "/secret.php")
                let info = siteRequest(fixture, host: host, "/info.php")

                #expect(secret.body == "secret ran", "\(host) gives \(secret.status): \(secret.body)")
                #expect(info.body == "info ran", "\(host) gives \(info.status): \(info.body)")
            }
        }
    }

    // MARK: R8

    // A listener for the debug connection of Xdebug. It accepts and closes each connection. So
    // Xdebug gives up and the request ends.
    final class DebugListener: @unchecked Sendable {
        let port: Int
        private let descriptor: Int32

        init() {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(listener, 8)
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
            descriptor = listener
            port = Int(UInt16(bigEndian: bound.sin_port))
        }

        func connects(within seconds: Int) -> Bool {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)

            guard poll(&waiting, 1, Int32(seconds * 1_000)) > 0 else {
                return false
            }

            let client = accept(descriptor, nil, nil)

            if client >= 0 {
                close(client)
            }

            return true
        }

        deinit {
            close(descriptor)
        }
    }

    static let hasXdebug: Bool = {
        guard let runtimes = NexusEngineTests.realRuntimes else {
            return false
        }

        let extensions = URL(filePath: runtimes).appending(path: "php/8.5/lib/php/extensions", directoryHint: .isDirectory)
        let files = FileManager.default.enumerator(at: extensions, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.contains { $0.lastPathComponent == "xdebug.so" }
    }()

    private func connects(_ listener: DebugListener, seconds: Int, during request: () async -> Answer) async -> (connected: Bool, answer: Answer) {
        let waiting = Task.detached { listener.connects(within: seconds) }
        let answer = await request()
        return (await waiting.value, answer)
    }

    @Test(.enabled(if: hasXdebug), .timeLimit(.minutes(3)))
    func aTriggerOfXdebugThroughALinkStartsNoDebugSessionWhileTheSwitchIsOn() async throws {
        let fixture = try await fixture(hosts: ["shop.test"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listener = DebugListener()

        try await base.whileRunning(fixture.engine) {
            try await addSites(fixture, ["shop.test"])
            _ = await fixture.engine.handle(.setCustomSettings(php: "8.5", lines: ["xdebug.client_host = 127.0.0.1", "xdebug.client_port = \(listener.port)", "xdebug.connect_timeout_ms = 500"]))
            _ = await fixture.engine.handle(.setExtension(php: "8.5", name: "xdebug", enabled: true))
            let shop = try #require(try await openLinks(fixture, [("shop.test", options())])["shop.test"]?.port)

            let cookie = await connects(listener, seconds: 3) { await request(shop, "/index.php", headers: ["Cookie: a=1; XDEBUG_SESSION=1"]) }
            let query = await request(shop, "/index.php?XDEBUG_SESSION_START=1")
            let local = await eventually(seconds: 20) {
                await connects(listener, seconds: 2) { siteRequest(fixture, host: "shop.test", "/index.php", arguments: ["-b", "a=1; XDEBUG_SESSION=1"]) }.connected
            }

            #expect(!cookie.connected)
            #expect(json(cookie.answer)["HTTP_COOKIE"] == "a=1", "\(cookie.answer.body)")
            #expect(query.status == 404)
            #expect(local, "The cookie on the site block starts a debug session. That proves the setup.")
        }
    }

    @Test(.enabled(if: hasXdebug), .timeLimit(.minutes(3)))
    func aPHPIniThatLoadsXdebugStartsNoDebugSessionInThePoolOfTheLinks() async throws {
        let listener = DebugListener()
        let phpIni = "zend_extension = xdebug\nxdebug.mode = debug\nxdebug.start_with_request = trigger\nxdebug.client_host = 127.0.0.1\nxdebug.client_port = \(listener.port)\nxdebug.connect_timeout_ms = 500\n"
        let fixture = try await fixture(hosts: ["shop.test"], phpIni: phpIni)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await base.whileRunning(fixture.engine) {
            try await addSites(fixture, ["shop.test"])
            let shop = try #require(try await openLinks(fixture, [("shop.test", options())])["shop.test"]?.port)
            let pool = try String(contentsOf: fixture.paths.phpConfigFolder(line: "8.5").appending(path: "php-fpm.conf"), encoding: .utf8)

            let link = await connects(listener, seconds: 3) { await request(shop, "/index.php", method: "POST", body: "XDEBUG_TRIGGER=1") }
            let local = await eventually(seconds: 20) {
                await connects(listener, seconds: 2) { siteRequest(fixture, host: "shop.test", "/index.php", arguments: ["--data", "XDEBUG_TRIGGER=1"]) }.connected
            }

            #expect(pool.contains("php_admin_value[xdebug.start_with_request] = \"no\""))
            #expect(!link.connected)
            #expect(json(link.answer)["start_with_request"] == "no", "\(link.answer.body)")
            #expect(local, "A trigger in the body on the site block starts a debug session. That proves the setup.")
        }
    }
}
