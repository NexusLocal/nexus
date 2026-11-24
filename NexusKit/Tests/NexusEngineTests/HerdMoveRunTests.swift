import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

struct HerdMoveRunTests {
    @Test func theRemovalOfTheHerdLinesKeepsEachOtherLineAndOneEmptyLine() {
        let text = "alias ll=\"ls -la\"\n\n# Herd injected PHP binary.\nexport PATH=\"/Users/ann/Library/Application Support/Herd/bin\":$PATH\n\n\nexport EDITOR=vim\n"

        let result = NexusEngine.removingLines(["# Herd injected PHP binary.", "export PATH=\"/Users/ann/Library/Application Support/Herd/bin\":$PATH"], from: text)

        #expect(result == "alias ll=\"ls -la\"\n\nexport EDITOR=vim\n")
    }

    @Test func aPHPOfHerdInAProjectFileBecomesThePHPOfNexus() {
        let text = #"{"mcpServers":{"laravel-boost":{"command":"/Users/ann/Library/Application Support/Herd/bin/php85","args":["artisan","boost:mcp"]}}}"#
        let bin = URL(filePath: "/Users/ann/Library/Application Support/Nexus/bin", directoryHint: .isDirectory)

        let result = NexusEngine.usingNexusPHP(in: text, bin: bin)

        #expect(result == #"{"mcpServers":{"laravel-boost":{"command":"/Users/ann/Library/Application Support/Nexus/bin/php","args":["artisan","boost:mcp"]}}}"#)
    }

    @Test(arguments: [
        ("/opt/homebrew/opt/mysql@8.4/bin/mysqld", "/opt/homebrew/opt/mysql@8.4/bin/mysqld  Ver 8.4.7 for macos15.7 on arm64 (Homebrew)", "mysql", "8.4.7"),
        ("/opt/homebrew/opt/mariadb/bin/mysqld", "mysqld  Ver 11.8.3-MariaDB for osx10.20 on arm64 (Homebrew)", "mariadb", "11.8.3"),
        ("/opt/homebrew/opt/postgresql@17/bin/postgres", "postgres (PostgreSQL) 17.7 (Homebrew)", "postgresql", "17.7"),
        ("/opt/homebrew/opt/redis/bin/redis-server", "Redis server v=8.4.0 sha=00000000:0 malloc=libc bits=64 build=1", "redis", "8.4.0"),
        ("/Users/Shared/Herd/services/valkey/8.1/bin/valkey-server", "Valkey server v=8.1.1 sha=00000000:0", "valkey", "8.1.1"),
        ("/usr/local/bin/mongod", "db version v8.0.4\nBuild Info: {}", "mongodb", "8.0.4"),
    ])
    func eachServerGivesItsKindAndItsVersion(executable: String, output: String, kind: String, version: String) {
        #expect(NexusEngine.serverKind(executable: executable, versionOutput: output) == kind)
        #expect(NexusEngine.serverVersion(in: output) == version)
    }

    @Test func wpConfigGivesThePlainValuesOfTheDatabaseConstants() {
        let text = """
        <?php
        define( 'DB_NAME', 'news' );
        define("DB_USER", "root");
        define( 'DB_PASSWORD', '' );
        define( 'DB_HOST', '127.0.0.1:3306' );
        define( 'WP_DEBUG', false );
        """

        #expect(NexusEngine.wordPressConstants(in: text) == ["DB_NAME": "news", "DB_USER": "root", "DB_PASSWORD": "", "DB_HOST": "127.0.0.1:3306"])
    }

    @Test func theChoicesOfTheUserChangeThePlanAndItsPackages() {
        let sites = [
            HerdMovePlan.SiteItem(hosts: ["api.test"], folder: "/Code/api", kind: .php, herdPHP: "8.3", php: "8.3", phpChoices: ["8.2", "8.3", "8.4", "8.5"]),
            HerdMovePlan.SiteItem(hosts: ["legacy.test"], folder: "/Code/legacy", kind: .php, herdPHP: "8.1", php: "8.2", phpChoices: ["8.2", "8.3", "8.4", "8.5"]),
        ]
        let database = HerdMovePlan.DatabaseItem(name: "shop", kind: "mysql", version: "9.4.0", port: 3306, account: DatabaseAccount(user: "root", password: ""), line: "9.7", lineChoices: ["9.7"], sites: ["api.test"])
        let plan = HerdMovePlan(herdRuns: true, tld: "test", sites: sites, databases: [database], envFiles: [HerdMovePlan.EnvItem(host: "legacy.test", file: "/Code/legacy/.env")])
        let facts = HerdMoveFacts(home: URL(filePath: "/Users/ann"), herdRuns: true, offered: [:], installed: ["php-8.5"], packageBytes: [:], servers: [:], redisKeys: [:], projects: [:], shellFiles: [:])

        let result = HerdMovePlanner.applying(HerdMoveRequest(skipped: ["site:legacy.test"], php: ["site:api.test": "8.5"], databaseLines: [database.id: "8.0"]), to: plan, facts: facts)

        #expect(result.sites.map(\.hosts) == [["api.test"]])
        #expect(result.sites.first?.php == "8.5")
        #expect(result.databases.first?.line == "9.7")
        #expect(result.envFiles.isEmpty)
        #expect(result.packages.map(\.id) == ["mysql-9.7"])
    }

    @Test func theSwitchOfTheOwnNginxLinesKeepsTheLinesOfEachSiteOutOfTheMove() {
        let site = HerdMovePlan.SiteItem(hosts: ["api.test"], folder: "/Code/api", kind: .php, herdPHP: "8.3", php: "8.3", phpChoices: ["8.3"], ownLines: ["add_header Access-Control-Allow-Origin *;"])
        let plan = HerdMovePlan(herdRuns: false, tld: "test", sites: [site])
        let facts = HerdMoveFacts(home: URL(filePath: "/Users/ann"), herdRuns: false, offered: [:], installed: ["php-8.3"], packageBytes: [:], servers: [:], redisKeys: [:], projects: [:], shellFiles: [:])

        let kept = HerdMovePlanner.applying(HerdMoveRequest(), to: plan, facts: facts)
        let skipped = HerdMovePlanner.applying(HerdMoveRequest(skipped: [HerdMovePlan.ownLinesID]), to: plan, facts: facts)

        #expect(kept.sites.first?.ownLines == site.ownLines)
        #expect(skipped.sites.map(\.hosts) == [["api.test"]])
        #expect(skipped.sites.first?.ownLines == [])
        #expect(skipped.sites.first?.php == "8.3")
    }

    @Test func aParkedFolderWithASiteThatIsOffBringsItsOtherSitesOneByOne() {
        let shop = HerdMovePlan.SiteItem(hosts: ["shop.test"], folder: "/Users/ann/Herd/shop", kind: .php, herdPHP: "8.5", php: "8.5", phpChoices: ["8.5"], parkedIn: "/Users/ann/Herd")
        let old = HerdMovePlan.SiteItem(hosts: ["old.test"], folder: "/Users/ann/Herd/old", kind: .php, herdPHP: "8.5", php: "8.5", phpChoices: ["8.5"], parkedIn: "/Users/ann/Herd")
        let plan = HerdMovePlan(herdRuns: false, tld: "test", parked: [HerdMovePlan.ParkedFolder(folder: "/Users/ann/Herd", php: "8.5")], sites: [shop, old])
        let facts = HerdMoveFacts(home: URL(filePath: "/Users/ann"), herdRuns: false, offered: [:], installed: ["php-8.5"], packageBytes: [:], servers: [:], redisKeys: [:], projects: [:], shellFiles: [:])

        let whole = HerdMovePlanner.applying(HerdMoveRequest(), to: plan, facts: facts)
        let partial = HerdMovePlanner.applying(HerdMoveRequest(skipped: [old.id]), to: plan, facts: facts)

        #expect(whole.parked.count == 1)
        #expect(partial.parked.isEmpty)
        #expect(partial.sites.map(\.hosts) == [["shop.test"]])
        #expect(partial.sites.first?.parkedIn == nil)
    }
}
