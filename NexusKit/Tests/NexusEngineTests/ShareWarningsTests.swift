import Foundation
import NexusCore
import NexusIPC
import NexusTestSupport
import Testing
@testable import NexusEngine

struct ShareWarningsTests {
    private let base = NexusEngineTests()

    private func folder() throws -> URL {
        let folder = shortTemporaryRoot().appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to path: String, in folder: URL) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    // MARK: The mail

    @Test func onlyAMailWithAPlaceThatCanReachAPersonIsRealMail() {
        let laravel = SiteMail(sendsToNexus: false, warning: "This site sends mail through Postmark. So a mail can reach a real person.", destination: "Postmark")
        let node = SiteMail(sendsToNexus: false, warning: "This site sends mail through Resend. So a mail can reach a real person.", destination: "Resend")
        let plugin = SiteMail(sendsToNexus: false, warning: "WP Mail SMTP sends the mail of this site.", destination: "WP Mail SMTP (Mailgun)")
        let tls = SiteMail(sendsToNexus: false, warning: "The mail service of Nexus does not offer TLS.")
        let local = SiteMail(sendsToNexus: false, destination: "the SMTP server on port 1025")
        let problem = SiteMail(sendsToNexus: false, problem: "Nexus cannot check the mail code of this site.")
        let nexus = SiteMail(sendsToNexus: true)

        #expect(ShareWarningCheck.sendsRealMail(laravel))
        #expect(ShareWarningCheck.sendsRealMail(node))
        #expect(ShareWarningCheck.sendsRealMail(plugin))
        #expect(!ShareWarningCheck.sendsRealMail(tls))
        #expect(!ShareWarningCheck.sendsRealMail(local))
        #expect(!ShareWarningCheck.sendsRealMail(problem))
        #expect(!ShareWarningCheck.sendsRealMail(nexus))
    }

    // MARK: OAuth

    @Test(arguments: [
        #"{"require": {"laravel/socialite": "^5.0"}}"#,
        #"{"require": {"socialiteproviders/microsoft": "^4.0"}}"#,
        #"{"require-dev": {"league/oauth2-google": "^4.0"}}"#,
        #"{"require": {"Laravel/Socialite": "^5.0"}}"#,
    ])
    func aComposerPackageForALoginWithAnotherServiceGivesTheWarning(composer: String) throws {
        let folder = try folder()
        defer { remove(folder) }
        try write(composer, to: "composer.json", in: folder)

        #expect(ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
    }

    @Test(arguments: ["next-auth", "@auth/core", "passport-google-oauth20", "better-auth", "@clerk/nextjs"])
    func aNodePackageForALoginWithAnotherServiceGivesTheWarning(package: String) throws {
        let folder = try folder()
        defer { remove(folder) }
        try write(#"{"dependencies": {"\#(package)": "1.0.0"}}"#, to: "package.json", in: folder)

        #expect(ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
    }

    @Test func aLoginWithAPasswordOfTheSiteGivesNoWarning() throws {
        let folder = try folder()
        defer { remove(folder) }
        try write(#"{"dependencies": {"passport-local": "1.0.0", "passport": "0.7.0"}}"#, to: "package.json", in: folder)
        try write(#"{"require": {"laravel/framework": "^13.0", "laravel/sanctum": "^4.0"}}"#, to: "composer.json", in: folder)

        #expect(!ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
    }

    @Test(arguments: ["wp-content/plugins", "media/plugins", "web/app/plugins", "wp-content/mu-plugins"])
    func aPluginForALoginWithAnotherServiceGivesTheWarning(plugins: String) throws {
        let folder = try folder()
        defer { remove(folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "\(plugins)/nextend-facebook-connect"), withIntermediateDirectories: true)

        #expect(ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
    }

    @Test func aPluginFolderDeeperThanThreeLevelsOrInVendorGivesNoWarning() throws {
        let folder = try folder()
        defer { remove(folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "a/b/c/plugins/oauth-login"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "vendor/x/plugins/oauth-login"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "wp-content/plugins/woocommerce"), withIntermediateDirectories: true)

        #expect(!ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
    }

    @Test func aRedirectKeyWithTheHostOfTheSiteGivesTheWarningAndAnotherHostDoesNot() throws {
        let folder = try folder()
        defer { remove(folder) }

        try write("GOOGLE_REDIRECT_URI=https://shop.test/auth/callback\n", to: ".env", in: folder)
        let ownHost = ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test", "www.shop.test"])

        try write("GOOGLE_REDIRECT_URI=https://accounts.example.com/callback\n", to: ".env", in: folder)
        let otherHost = ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"])

        try write("APP_URL=https://www.shop.test\nGITHUB_CALLBACK_URL=\"${APP_URL}/auth/github\"\n", to: ".env", in: folder)
        let throughAppURL = ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test", "www.shop.test"])

        #expect(ownHost)
        #expect(!otherHost)
        #expect(throughAppURL)
    }

    @Test func anEmptyFolderGivesNoWarning() throws {
        let folder = try folder()
        defer { remove(folder) }

        #expect(!ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: ["shop.test"]))
        #expect(!ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2)))
    }

    // MARK: Streamed text

    @Test(arguments: ShareWarningCheck.streamMarkers)
    func eachMarkerOfStreamedTextInTheCodeOfTheSiteGivesTheWarning(marker: String) throws {
        let folder = try folder()
        defer { remove(folder) }
        try write("<?php\n// \(marker)\n", to: "app/Http/Controllers/ChatController.php", in: folder)

        #expect(ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2)))
    }

    @Test(arguments: ["vendor/x/Stream.php", "node_modules/x/index.js", "storage/framework/views/a.php", "public/build/assets/app.js", "bootstrap/cache/x.php", ".git/hooks/x.js", "app/notes.txt"])
    func aMarkerOnlyInAFolderOfToolsOrInAnotherKindOfFileGivesNoWarning(path: String) throws {
        let folder = try folder()
        defer { remove(folder) }
        try write("header('Content-Type: text/event-stream');", to: path, in: folder)

        #expect(!ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2)))
    }

    @Test func aLargeFileIsSkippedAndAnEndTimeInThePastGivesNoWarning() throws {
        let folder = try folder()
        defer { remove(folder) }
        try write(String(repeating: "x", count: 600 * 1_024) + "text/event-stream", to: "app/large.js", in: folder)
        let large = ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2))

        try write("new EventSource('/chat')", to: "resources/js/chat.js", in: folder)

        #expect(!large)
        #expect(ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2)))
        #expect(!ShareWarningCheck.streamsText(folder: folder, until: .now - .seconds(1)))
    }

    // MARK: Custom access rules

    @Test func eachAllowOrDenyOfTheCustomLinesGivesTheWarning() {
        for lines in [["allow 10.0.0.1;"], ["  deny all;"], ["location /admin { deny all; }"], ["if ($x) {allow 1.2.3.4;}"], ["client_max_body_size 1m;", "\tdeny 192.168.0.0/16;"]] {
            #expect(ShareWarningCheck.hasAccessRules(lines), "\(lines)")
        }

        for lines in [["# deny all;"], ["add_header X-Deny-Reason x;"], ["set $allowed 1;"], [], ["client_max_body_size 1m;", "gzip on; # allow all"], ["location /denylist { return 404; }"]] {
            #expect(!ShareWarningCheck.hasAccessRules(lines), "\(lines)")
        }
    }

    // MARK: The engine

    private func target(_ host: String, workspace: String? = nil, names: [String]? = nil) -> ShareTarget {
        ShareTarget(host: host, site: host, workspace: workspace, owner: host, names: names ?? [host])
    }

    private func warnings(_ engine: NexusEngine, _ host: String) async -> [ShareWarning] {
        let target = target(host)
        return await engine.protectionWarnings(of: target, project: engine.shareProject(of: target, in: engine.stateStore.current()))
    }

    @Test func theWarningsComeInTheOrderOfTheDesignAndTheCustomLinesComeLast() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "app", directoryHint: .isDirectory)
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)

        try write("RESEND_API_KEY=re_123\n", to: ".env", in: app)
        try write(#"{"dependencies": {"next-auth": "5.0.0"}}"#, to: "package.json", in: app)
        try write("const response = new Response(stream, { headers: { 'Content-Type': 'text/event-stream' } })", to: "app/api/chat/route.ts", in: app)

        for folder in [shop, blog] {
            try write(#"{"require": {"laravel/socialite": "^5.0"}}"#, to: "composer.json", in: folder)
            try write("<?php return response()->eventStream(fn () => yield 'x');", to: "routes/web.php", in: folder)
        }

        var state = EngineState()
        state.sites = [
            Site(host: "app.test", folder: app, php: "8.4", runsAs: .node),
            Site(host: "shop.test", folder: shop, php: "8.4", nginxLines: ["location /admin {", "    deny all;", "}"]),
            Site(host: "blog.test", folder: blog, php: "8.4", server: .apache, nginxLines: ["deny all;"], apacheLines: ["Require ip 10.0.0.1"]),
        ]
        let engine = try base.makeSiteEngine(root: root, state: state)

        try await base.whileRunning(engine) {
            #expect(await warnings(engine, "app.test") == [.sendsRealMail, .oauthLogin, .serverSentEvents])
            #expect(await warnings(engine, "shop.test") == [.oauthLogin, .serverSentEvents, .customAccessRules])
            #expect(await warnings(engine, "blog.test") == [.oauthLogin, .serverSentEvents])
            #expect(await warnings(engine, "nothing.test") == [])
        }
    }

    @Test func theMailCheckOfAWorkspaceReadsTheFolderOfTheWorkspace() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appending(path: "app", directoryHint: .isDirectory)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try write("SMTP_HOST=127.0.0.1\nSMTP_PORT=1025\n", to: ".env", in: main)
        try write("RESEND_API_KEY=re_123\n", to: ".env", in: worktree)

        var state = EngineState()
        let site = Site(host: "app.test", folder: main, php: "8.4", runsAs: .node)
        state.sites = [site]
        state.worktrees[ProjectFolder.workspaceKey(of: site)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: worktree.path(percentEncoded: false), folder: worktree.path(percentEncoded: false))])
        let engine = try base.makeSiteEngine(root: root, state: state)

        try await base.whileRunning(engine) {
            let mainWarnings = await warnings(engine, "app.test")
            let fix = ShareTarget(host: "fix.app.test", site: "app.test", workspace: "fix", owner: "fix", names: ["fix.app.test"])
            let project = await engine.shareProject(of: fix, in: await engine.stateStore.current())
            let workspace = await engine.shareSendsRealMail(fix, project: project)

            #expect(mainWarnings == [])
            #expect(workspace)
            #expect(project?.folder.path(percentEncoded: false) == worktree.path(percentEncoded: false))
        }
    }
}
