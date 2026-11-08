import Foundation
import Testing
@testable import NexusCore

struct SiteTemplateTests {
    @Test func aNameIsAFolderAHostAndAPackageName() throws {
        #expect(try NewSiteName.validated("shop") == "shop")
        #expect(try NewSiteName.validated("my-shop2") == "my-shop2")

        for wrong in ["", "Shop", "my_shop", "-shop", "shop-", "shop.test", "my shop", String(repeating: "a", count: 51)] {
            #expect(throws: NewSiteError.invalidName(wrong)) { try NewSiteName.validated(wrong) }
        }
    }

    @Test func theDatabaseAndTheWorkFolderComeFromTheName() {
        #expect(NewSiteName.databaseBase(of: "my-shop") == "my_shop")
        #expect(NewSiteName.workFolder(of: "shop") == ".nexus-new-shop")
    }

    @Test func laravelWithoutAKitGetsNoKitFlags() {
        let site = NewSite(template: .laravel, name: "shop", parent: "/tmp", teams: true)

        #expect(SiteTemplateCommands.laravelNew(site, database: .mysql, hasNode: true) == ["new", "shop", "--no-interaction", "--pest", "--boost", "--database=mysql", "--npm"])
    }

    @Test func laravelWithAKitGetsItsAuthenticationAndTeams() {
        let site = NewSite(template: .laravel, name: "shop", parent: "/tmp", starterKit: .vue, authentication: .none, teams: true, tests: .phpunit, boost: false)

        #expect(SiteTemplateCommands.laravelNew(site, database: .postgresql, hasNode: false) == ["new", "shop", "--no-interaction", "--vue", "--no-authentication", "--teams", "--phpunit", "--no-boost", "--database=pgsql", "--no-node"])
        #expect(SiteTemplateCommands.laravelNew(NewSite(template: .laravel, name: "shop", parent: "/tmp", starterKit: .react, authentication: .workos), database: nil, hasNode: true).contains("--workos"))
        #expect(SiteTemplateCommands.laravelConnection(nil) == "sqlite")
        #expect(SiteTemplateCommands.laravelConnection(.mariadb) == "mariadb")
    }

    @Test func eachNodeTemplateMakesOnlyTheFilesWithAFixedMajorVersion() {
        let next = SiteTemplateCommands.create(NewSite(template: .next, name: "shop", parent: "/tmp", packageManager: .pnpm))
        let nuxt = SiteTemplateCommands.create(NewSite(template: .nuxt, name: "shop", parent: "/tmp"))
        let vite = SiteTemplateCommands.create(NewSite(template: .vite, name: "shop", parent: "/tmp", framework: .svelte))
        let astro = SiteTemplateCommands.create(NewSite(template: .astro, name: "shop", parent: "/tmp"))

        #expect(next?.prefix(3) == ["--yes", "create-next-app@16", "shop"])
        #expect(next?.contains("--use-pnpm") == true)
        #expect(next?.contains("--skip-install") == true)
        #expect(next?.contains("--disable-git") == true)
        #expect(nuxt == ["--yes", "create-nuxt@4", "shop", "--template", "minimal", "--packageManager", "npm", "--no-gitInit", "--no-install", "--no-modules"])
        #expect(vite == ["--yes", "create-vite@9", "shop", "--template", "svelte-ts", "--no-interactive"])
        #expect(astro == ["--yes", "create-astro@5", "shop", "--template", "basics", "--no-install", "--no-git", "--yes", "--skip-houston"])
        #expect(SiteTemplateCommands.create(NewSite(template: .laravel, name: "shop", parent: "/tmp")) == nil)
    }

    @Test func wordPressGetsThePasswordOnItsInputAndANetworkItsKind() {
        let site = NewSite(template: .wordpress, name: "blog", parent: "/tmp", locale: "nl_NL", adminUser: "tim", adminEmail: "tim@blog.test", network: .subdomains)
        let install = SiteTemplateCommands.wordPressInstall(site, url: "https://blog.test", path: "/tmp/blog")

        #expect(SiteTemplateCommands.wordPressDownload(site, path: "/tmp/blog") == ["core", "download", "--locale=nl_NL", "--path=/tmp/blog"])
        #expect(install.prefix(3) == ["core", "multisite-install", "--subdomains"])
        #expect(install.contains("--prompt=admin_password"))
        #expect(install.contains("--quiet"))
        #expect(!install.contains { $0.hasPrefix("--admin_password") })

        var single = site
        single.network = nil
        #expect(SiteTemplateCommands.wordPressInstall(single, url: "https://blog.test", path: "/tmp/blog").prefix(2) == ["core", "install"])
    }

    @Test func theTemplatesOfPHPAreSitesOfPHP() {
        #expect(SiteTemplate.laravel.kind == .php)
        #expect(SiteTemplate.wordpress.kind == .php)
        #expect(SiteTemplate.allCases.filter { $0.kind == .node } == [.next, .nuxt, .vite, .astro])
    }
}

struct WordPressLocaleTests {
    @Test func theLanguagesOfMacOSComeFirstAndEnglishOnlyOnce() {
        let choices = WordPressLocale.choices(preferred: ["nl-NL", "en-NL", "de-CH"], displayLocale: Locale(identifier: "en_US"))

        #expect(choices.map(\.code) == ["nl_NL", "en_US", "de_CH"])
    }

    @Test func aLanguageThatWordPressDoesNotHaveIsNotInTheList() {
        #expect(WordPressLocale.code(for: "xx-YY") == nil)
        #expect(WordPressLocale.code(for: "pt-BR") == "pt_BR")
        #expect(WordPressLocale.code(for: "en-GB") == "en_GB")
        #expect(WordPressLocale.code(for: "fr") == "fr_FR")
    }
}

struct TerminalOutputTests {
    @Test func escapeSequencesAndLinksGo() {
        let text = "\u{1B}[90m ┌\u{1B}[39m \u{1B}[36mReady\u{1B}[39m\n\u{1B}]8;;https://laravel.com\u{1B}\\docs\u{1B}]8;;\u{1B}\\ here\n"

        #expect(TerminalOutput.lines(text) == [" ┌ Ready", "docs here"])
    }

    @Test func eachFrameOfASpinnerReplacesTheFrameBeforeIt() {
        let text = " ⠰ Building assets...\n\u{1B}[1G\u{1B}[1A\u{1B}[J ⠠ Building assets...\n\n ✔ Building assets...\n ⠶ Running database migrations...\n"

        #expect(TerminalOutput.lines(text) == [" ✔ Building assets...", " ⠶ Running database migrations..."])
        #expect(TerminalOutput.activity(in: TerminalOutput.lines(text)) == "Running database migrations")
    }

    @Test func aDoneStepIsNoActivity() {
        #expect(TerminalOutput.activity(in: [" ✔ Setting up Pest..."]) == nil)
    }

    @Test func aCarriageReturnStartsTheLineAgain() {
        #expect(TerminalOutput.lines("10%\r50%\r100%\ndone") == ["100%", "done"])
    }

    @Test func aCarriageReturnBeforeANewlineKeepsTheLine() {
        #expect(TerminalOutput.lines("Error: no host\r\nnext line\r\n") == ["Error: no host", "next line"])
    }

    @Test func theTailOfALargeFileStartsAtAWholeLine() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "nexus-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((1...2000).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: file)

        let tail = TerminalOutput.tail(of: file, lines: 3, maximumBytes: 100)

        #expect(tail == ["line 1998", "line 1999", "line 2000"])
    }
}
