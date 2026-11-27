import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

// The sample sites of the VM local-golden (docs/group11-local.md).
struct LocalMovePlannerTests {
    private let home = URL(filePath: "/Users/ann", directoryHint: .isDirectory)

    private var local: URL {
        home.appending(path: "Library/Application Support/Local", directoryHint: .isDirectory)
    }

    private func site(_ name: String, php: String = "8.2.29", server: WebServer = .nginx, database: String = "8.4.0", port: Int, network: WordPressNetworkKind? = nil, networkDomains: [String] = [], ownLines: [String] = [], phpIniLines: [String] = []) -> LocalSetup.Site {
        LocalSetup.Site(
            id: "id-\(name)",
            name: name,
            domain: "\(name).local",
            folder: home.appending(path: "Local Sites/\(name)", directoryHint: .isDirectory),
            runFolder: local.appending(path: "run/id-\(name)", directoryHint: .isDirectory),
            php: php,
            server: server,
            databaseKind: "mysql",
            databaseVersion: database,
            databasePort: port,
            network: network,
            networkDomains: networkDomains,
            ownLines: ownLines,
            phpIniLines: phpIniLines
        )
    }

    private var setup: LocalSetup {
        LocalSetup(folder: local, sites: [
            site("blog", php: "7.4.30", server: .apache, database: "8.0.35", port: 10008),
            site("legacy", php: "8.0.30", database: "5.7.28", port: 10013),
            site("shop", port: 10003, ownLines: [#"add_header X-Shop-Test "moved" always;"#], phpIniLines: ["memory_limit = 512M", "max_input_vars = 5000"]),
            site("subnet", php: "8.3.30", database: "8.0.35", port: 10023, network: .subdomains, networkDomains: ["one.subnet.local"]),
        ])
    }

    private func facts(running: Set<String> = ["id-shop"], dataFolders: Set<String> = ["id-blog", "id-legacy", "id-subnet"], dumps: [String: Date] = [:], installed: Set<String> = ["php-8.6", "mysql-8.4"], nexusHosts: Set<String> = [], nexusSiteCount: Int = 0) -> LocalMoveFacts {
        var facts = LocalMoveFacts(
            home: home,
            localRuns: true,
            offered: ["php": ["8.2", "8.3", "8.4", "8.5", "8.6"], "mysql": ["8.0", "8.4", "9.7"], "mariadb": ["10.11", "11.4"], "httpd": ["2.4"], "wp-cli": ["2"]],
            installed: installed,
            packageBytes: ["php-8.2": 30_000_000]
        )
        facts.running = running
        facts.hasDataFolder = dataFolders
        facts.dumpDates = dumps
        facts.hasWPConfig = ["id-blog", "id-legacy", "id-shop", "id-subnet"]
        facts.hasEnvrc = ["id-shop"]
        facts.direnv = true
        facts.trusted = ["shop.local"]
        facts.nexusHosts = nexusHosts
        facts.nexusSiteCount = nexusSiteCount
        facts.nexusTLD = "test"
        return facts
    }

    @Test func eachSiteMovesWithItsFolderNameAndDatabase() throws {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts())
        let shop = try #require(plan.sites.first { $0.hosts[0] == "shop.local" })
        let subnet = try #require(plan.sites.first { $0.hosts[0] == "subnet.local" })

        #expect(plan.source == .local)
        #expect(plan.sites.map { $0.hosts[0] } == ["blog.local", "legacy.local", "shop.local", "subnet.local"])
        #expect(shop.folder == "/Users/ann/Local Sites/shop/app/public")
        #expect(shop.projectType == .wordpress)
        #expect(shop.ownLines == [#"add_header X-Shop-Test "moved" always;"#])
        #expect(subnet.hosts == ["subnet.local", "one.subnet.local"])
        #expect(subnet.network == .subdomains)
        #expect(plan.sites.first { $0.hosts[0] == "blog.local" }?.server == .apache)
        #expect(plan.databases.map(\.targetName) == ["blog", "legacy", "shop", "subnet"])
        #expect(plan.wpConfigs.map(\.host) == ["blog.local", "legacy.local", "shop.local", "subnet.local"])
        #expect(plan.httpsSites == ["blog.local", "legacy.local", "shop.local", "subnet.local"])
        #expect(plan.files.map(\.path) == ["/Users/ann/Local Sites/shop/app/.envrc"])
        #expect(plan.certificates == ["/Users/ann/Library/Application Support/Local/run/router/nginx/certs/shop.local.crt"])
    }

    @Test func aRunningSiteGivesItsSocketAndAStoppedSiteACopyOfItsDataFolder() throws {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts())
        let shop = try #require(plan.databases.first { $0.sites == ["shop.local"] })
        let legacy = try #require(plan.databases.first { $0.sites == ["legacy.local"] })

        #expect(shop.runs == true)
        #expect(shop.dataFolder == nil)
        #expect(shop.socket == "/Users/ann/Library/Application Support/Local/run/id-shop/mysql/mysqld.sock")
        #expect(shop.account == DatabaseAccount(user: "root", password: "root"))
        #expect(shop.way == "runs in Local")
        #expect(legacy.runs == false)
        #expect(legacy.dataFolder == "/Users/ann/Library/Application Support/Local/run/id-legacy/mysql/data/")
        #expect(legacy.readerLine == "8.0")
        #expect(legacy.way == "from a copy of the data folder")
    }

    @Test func oldVersionsGetTheOldestLineOfNexus() throws {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts())
        let blog = try #require(plan.sites.first { $0.hosts[0] == "blog.local" })
        let legacy = try #require(plan.databases.first { $0.sites == ["legacy.local"] })

        #expect(blog.herdPHP == "7.4.30")
        #expect(blog.php == "8.2")
        #expect(legacy.line == "8.0")
        #expect(legacy.lineChoices == ["8.0", "8.4", "9.7"])
        #expect(plan.notes.contains("blog.local uses PHP 7.4. Nexus has PHP 8.2 and newer, so the site gets PHP 8.2."))
        #expect(plan.notes.contains("legacy.local uses MySQL 5.7. Nexus has MySQL 8.0 and newer, so the database goes to MySQL 8.0."))
    }

    @Test func aSiteWithoutDataFolderUsesItsDumpWithANote() throws {
        let date = Date(timeIntervalSince1970: 1_795_724_760)
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts(dataFolders: ["id-legacy", "id-subnet"], dumps: ["id-blog": date]))
        let blog = try #require(plan.databases.first { $0.sites == ["blog.local"] })

        #expect(blog.dataFolder == nil)
        #expect(blog.dump == "/Users/ann/Local Sites/blog/app/sql/local.sql")
        #expect(blog.dumpDate == date)
        #expect(blog.way == "from local.sql")
        #expect(plan.notes.contains { $0.hasPrefix("Nexus cannot read the data folder of blog.local.") })
    }

    @Test func thePackagesAreThePHPDatabaseApacheAndWPCLIThatNexusDoesNotHave() {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts())

        #expect(plan.packages.map(\.id) == ["php-8.2", "php-8.3", "mysql-8.0", "httpd-2.4", "wp-cli-2"])
        #expect(plan.packages.last?.reason == "for the URLs")
        #expect(plan.packages.first?.reason == "for blog.local, legacy.local and shop.local")
        #expect(plan.packages.first?.bytes == 30_000_000)
    }

    @Test func thePHPLinesOfTheSitesGetMaxInputVarsOfLocal() {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts())

        #expect(plan.ini.map(\.line) == ["8.2", "8.3"])
        #expect(plan.ini.first?.lines == ["memory_limit = 512M", "max_input_vars = 5000"])
        #expect(plan.ini.last?.lines == ["max_input_vars = 4000"])
    }

    @Test func twoSitesWithAnotherValueOnOnePHPVersionGiveTheLargerValue() {
        let setup = LocalSetup(folder: local, sites: [
            site("a", port: 1, phpIniLines: ["memory_limit = 256M"]),
            site("b", port: 2, phpIniLines: ["memory_limit = 1G"]),
        ])
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts(running: [], dataFolders: []))

        #expect(plan.ini.first?.lines == ["memory_limit = 1G", "max_input_vars = 4000"])
        #expect(plan.notes.contains("a.local has memory_limit = 256M and b.local has memory_limit = 1G. PHP 8.2 gets 1G."))
    }

    @Test func twoSitesWithTheSameFirstLabelGetTwoDatabaseNames() {
        var sites = [site("shop", port: 1)]
        sites.append(LocalSetup.Site(id: "id-2", name: "shop2", domain: "shop.wpe.local", folder: home.appending(path: "Local Sites/shop2"), runFolder: local.appending(path: "run/id-2"), php: "8.2.29", server: .nginx, databaseKind: "mysql", databaseVersion: "8.4.0", databasePort: 2))
        let plan = LocalMovePlanner.plan(setup: LocalSetup(folder: local, sites: sites), facts: facts())

        #expect(plan.databases.map(\.targetName) == ["shop", "shop_2"])
    }

    @Test func aSiteThatNexusHasAlreadyStaysOut() {
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts(nexusHosts: ["shop.local"]))

        #expect(!plan.sites.contains { $0.hosts[0] == "shop.local" })
        #expect(plan.inNexus == ["shop.local"])
        #expect(!plan.databases.contains { $0.sites == ["shop.local"] })
    }

    @Test func theDevTLDSwitchIsOnOnlyForANexusWithoutSites() throws {
        let empty = try #require(LocalMovePlanner.plan(setup: setup, facts: facts()).devTLD)
        let used = try #require(LocalMovePlanner.plan(setup: setup, facts: facts(nexusSiteCount: 12)).devTLD)

        #expect(empty.isOnByDefault)
        #expect(!used.isOnByDefault)
        #expect(used.nexusSites == 12)
    }

    @Test func aSiteThatIsOffTakesItsDatabaseConfigAndURLsAlong() throws {
        let facts = facts()
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts)
        let shop = try #require(plan.sites.first { $0.hosts[0] == "shop.local" })
        let result = LocalMovePlanner.applying(HerdMoveRequest(skipped: [shop.id]), to: plan, facts: facts)

        #expect(!result.sites.contains { $0.hosts[0] == "shop.local" })
        #expect(!result.databases.contains { $0.sites == ["shop.local"] })
        #expect(!result.wpConfigs.contains { $0.host == "shop.local" })
        #expect(!result.httpsSites.contains("shop.local"))
        #expect(result.files.isEmpty)
    }

    @Test func theChoicesOfTheUserChangeThePlan() throws {
        let facts = facts()
        let plan = LocalMovePlanner.plan(setup: setup, facts: facts)
        let blog = try #require(plan.sites.first { $0.hosts[0] == "blog.local" })
        let legacy = try #require(plan.databases.first { $0.sites == ["legacy.local"] })
        let request = HerdMoveRequest(skipped: [HerdMovePlan.httpsID, HerdMovePlan.ownLinesID], php: [blog.id: "8.4"], databaseLines: [legacy.id: "8.4"], useDevTLD: false)
        let result = LocalMovePlanner.applying(request, to: plan, facts: facts)

        #expect(result.sites.first { $0.hosts[0] == "blog.local" }?.php == "8.4")
        #expect(result.sites.allSatisfy { $0.ownLines.isEmpty })
        #expect(result.databases.first { $0.sites == ["legacy.local"] }?.line == "8.4")
        #expect(result.databases.first { $0.sites == ["legacy.local"] }?.readerLine == "8.0")
        #expect(result.httpsSites.isEmpty)
        #expect(result.devTLD == nil)
        #expect(result.packages.map(\.id).contains("mysql-8.0"))
        #expect(result.packages.map(\.id).contains("php-8.4"))
        #expect(!result.packages.map(\.id).contains("wp-cli-2"))
    }
}
