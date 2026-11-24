import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

private extension URL {
    var plain: String {
        HerdMovePlanner.folderPath(self)
    }
}

struct HerdMovePlannerTests {
    private struct Folders {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "nexus-herd-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func folder(_ path: String) throws -> URL {
            let url = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.standardizedFileURL
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func facts(home: URL, projects: [String: HerdMoveFacts.Project] = [:], servers: [Int: HerdMoveFacts.Server] = [:], installed: Set<String> = ["php-8.5", "mysql-8.4"], shellFiles: [String: String] = [:]) -> HerdMoveFacts {
        HerdMoveFacts(
            home: home,
            herdRuns: true,
            offered: ["php": ["8.2", "8.3", "8.4", "8.5"], "mysql": ["8.0", "8.4", "9.7"], "mariadb": ["10.11", "11.4", "11.8", "12.3"], "postgresql": ["14", "15", "16", "17", "18"], "redis": ["7.2", "8.2", "8"]],
            installed: installed,
            packageBytes: ["php-8.3": 31_000_000, "postgresql-17": 42_000_000],
            servers: servers,
            redisKeys: [6379: 3],
            projects: projects,
            shellFiles: shellFiles
        )
    }

    private func laravel(_ env: [String: String], files: [String: [String]] = [:]) -> HerdMoveFacts.Project {
        HerdMoveFacts.Project(type: .laravel, env: env, wordPress: nil, projectFiles: files)
    }

    @Test func eachParkedFolderLinkAndProxyIsASiteWithItsPHPVersion() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        let shop = try folders.folder("Herd/shop")
        _ = try folders.folder("Herd/blog")
        let feature = try folders.folder("Herd/shop-feature")
        let api = try folders.folder("Code/api-server")
        let setup = HerdSetup(
            parkedFolders: [herd],
            links: [HerdSetup.Link(names: ["api", "api-v2"], folder: api)],
            siteFiles: [
                HerdSetup.SiteFile(host: "api.test", php: "8.3", secured: true, ownLines: ["add_header X-Test 1;"]),
                HerdSetup.SiteFile(host: "admin.test", proxy: "http://127.0.0.1:3000"),
            ],
            defaultPHP: "8.5",
            workspaces: [HerdSetup.Workspace(kind: "worktree", folder: feature, site: "shop")]
        )

        let plan = HerdMovePlanner.plan(setup: setup, facts: facts(home: folders.root))

        #expect(plan.parked == [HerdMovePlan.ParkedFolder(folder: herd.plain, php: "8.5")])
        #expect(plan.sites.map(\.hosts) == [["blog.test"], ["shop.test"], ["api.test", "api-v2.test"], ["admin.test"]])
        #expect(plan.sites.first { $0.hosts.contains("shop.test") }?.folder == shop.plain)
        #expect(plan.sites.first { $0.hosts.contains("api.test") }?.php == "8.3")
        #expect(plan.sites.first { $0.hosts.contains("api.test") }?.ownLines == ["add_header X-Test 1;"])
        #expect(plan.sites.first { $0.hosts.contains("admin.test") }?.kind == .proxy)
        #expect(plan.sites.first { $0.hosts.contains("admin.test") }?.address == "http://127.0.0.1:3000")
    }

    @Test func anOldPHPGetsTheOldestLineAndANewPHPGetsTheNewestLine() {
        #expect(HerdMovePlanner.phpLine(for: "8.1", offered: ["8.2", "8.3", "8.4", "8.5"]) == "8.2")
        #expect(HerdMovePlanner.phpLine(for: "7.4", offered: ["8.2", "8.3", "8.4", "8.5"]) == "8.2")
        #expect(HerdMovePlanner.phpLine(for: "8.3", offered: ["8.2", "8.3", "8.4", "8.5"]) == "8.3")
        #expect(HerdMovePlanner.phpLine(for: "8.6", offered: ["8.2", "8.3", "8.4", "8.5"]) == "8.5")
    }

    @Test func aSiteOnAnOldPHPGetsANoteInPlainWords() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let legacy = try folders.folder("Code/legacy-app")
        let setup = HerdSetup(links: [HerdSetup.Link(names: ["legacy"], folder: legacy)], siteFiles: [HerdSetup.SiteFile(host: "legacy.test", php: "8.1")], defaultPHP: "8.5")

        let plan = HerdMovePlanner.plan(setup: setup, facts: facts(home: folders.root))

        #expect(plan.sites.first?.php == "8.2")
        #expect(plan.notes == ["legacy.test uses PHP 8.1. Nexus has PHP 8.2 and newer, so the site gets PHP 8.2."])
    }

    @Test func aDatabaseGoesToTheSameLineOrTheNearestNewerLine() {
        #expect(HerdMovePlanner.databaseLine(for: "8.4.7", offered: ["8.0", "8.4", "9.7"]) == ("8.4", ["8.4", "9.7"]))
        #expect(HerdMovePlanner.databaseLine(for: "9.4.0", offered: ["8.0", "8.4", "9.7"]) == ("9.7", ["9.7"]))
        #expect(HerdMovePlanner.databaseLine(for: "17.7", offered: ["14", "15", "16", "17", "18"]) == ("17", ["17", "18"]))
        #expect(HerdMovePlanner.databaseLine(for: nil, offered: ["8.0", "8.4", "9.7"]) == ("9.7", ["8.0", "8.4", "9.7"]))
    }

    @Test func twoSitesOnOneDatabaseGiveOneDatabaseWithBothSites() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        let shop = try folders.folder("Herd/shop")
        let admin = try folders.folder("Herd/shop-admin")
        let blog = try folders.folder("Herd/blog")
        let env = ["DB_CONNECTION": "mysql", "DB_HOST": "127.0.0.1", "DB_PORT": "3306", "DB_DATABASE": "shop", "DB_USERNAME": "root", "DB_PASSWORD": ""]
        let projects = [
            shop.plain: laravel(env),
            admin.plain: laravel(env),
            blog.plain: laravel(["DB_CONNECTION": "pgsql", "DB_HOST": "127.0.0.1", "DB_PORT": "5432", "DB_DATABASE": "blog", "DB_USERNAME": "admin"]),
        ]
        let servers = [3306: HerdMoveFacts.Server(kind: "mysql", version: "8.4.7"), 5432: HerdMoveFacts.Server(kind: "postgresql", version: "17.7")]

        let plan = HerdMovePlanner.plan(setup: HerdSetup(parkedFolders: [herd], defaultPHP: "8.5"), facts: facts(home: folders.root, projects: projects, servers: servers))

        #expect(plan.databases.map(\.name) == ["blog", "shop"])
        #expect(plan.databases.first { $0.name == "shop" }?.sites == ["shop.test", "shop-admin.test"])
        #expect(plan.databases.first { $0.name == "shop" }?.line == "8.4")
        #expect(plan.databases.first { $0.name == "blog" }?.kind == "postgresql")
        #expect(plan.databases.first { $0.name == "blog" }?.account == DatabaseAccount(user: "admin", password: ""))
        #expect(plan.envFiles.map(\.host) == ["blog.test", "shop.test", "shop-admin.test"])
    }

    @Test func aSiteThatNexusHasAlreadyLeavesThePlanWithItsDatabase() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        let shop = try folders.folder("Herd/shop")
        let blog = try folders.folder("Herd/blog")
        let projects = [
            shop.plain: laravel(["DB_CONNECTION": "mysql", "DB_PORT": "3306", "DB_DATABASE": "shop"]),
            blog.plain: laravel(["DB_CONNECTION": "mysql", "DB_PORT": "3306", "DB_DATABASE": "blog"]),
        ]
        var known = facts(home: folders.root, projects: projects, servers: [3306: HerdMoveFacts.Server(kind: "mysql", version: "8.4.7")])
        known.nexusHosts = ["shop.test"]

        let plan = HerdMovePlanner.plan(setup: HerdSetup(parkedFolders: [herd], defaultPHP: "8.5"), facts: known)

        #expect(plan.sites.map(\.hosts) == [["blog.test"]])
        #expect(plan.databases.map(\.name) == ["blog"])
        #expect(plan.parked.map(\.folder) == [herd.plain])
        #expect(plan.inNexus == ["shop.test"])
        #expect(plan.notes == ["shop.test is in Nexus already, so the move leaves it out."])
    }

    @Test func aPlanAfterAMoveIsEmptyAndSaysWhy() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        _ = try folders.folder("Herd/shop")
        let proxy = HerdSetup.SiteFile(host: "admin.test", proxy: "http://127.0.0.1:3000")
        var known = facts(home: folders.root)
        known.nexusHosts = ["shop.test", "admin.test"]
        known.nexusParked = [herd.plain]

        let plan = HerdMovePlanner.plan(setup: HerdSetup(parkedFolders: [herd], siteFiles: [proxy], defaultPHP: "8.5"), facts: known)

        #expect(plan.isEmpty)
        #expect(HerdMoveText.nothingToMove(plan) == "Each site of Herd is in Nexus already.")
        #expect(HerdMoveText.nothingToMove(nil) == "Nexus found no sites of Herd on this Mac.")
    }

    @Test func aDatabaseOnAServerThatDoesNotRunGetsANoteAndNoCopy() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        let blog = try folders.folder("Herd/blog")
        let projects = [blog.plain: laravel(["DB_CONNECTION": "pgsql", "DB_DATABASE": "blog"])]

        let plan = HerdMovePlanner.plan(setup: HerdSetup(parkedFolders: [herd], defaultPHP: "8.5"), facts: facts(home: folders.root, projects: projects))

        #expect(plan.databases.isEmpty)
        #expect(plan.packages.isEmpty)
        #expect(plan.notes == ["The server of the database blog on port 5432 does not run, so Nexus cannot copy it. Start that server, then open this sheet again."])
        #expect(plan.sites.first?.folder == blog.plain)
        #expect(plan.sites.first?.folder.hasSuffix("/") == false)
    }

    @Test func aMySQLConnectionToMariaDBGoesToMariaDB() {
        let project = laravel(["DB_CONNECTION": "mysql", "DB_DATABASE": "crm", "DB_PORT": "3307"])

        let endpoint = HerdMovePlanner.databaseEndpoint(of: project, servers: [3307: HerdMoveFacts.Server(kind: "mariadb", version: "11.8.3")])

        #expect(endpoint?.kind == "mariadb")
        #expect(endpoint?.port == 3307)
    }

    @Test func aWordPressSiteGivesItsDatabaseFromWPConfig() {
        let project = HerdMoveFacts.Project(type: .wordpress, env: nil, wordPress: ["DB_NAME": "news", "DB_USER": "root", "DB_PASSWORD": "", "DB_HOST": "127.0.0.1:3306"], projectFiles: [:])

        let endpoint = HerdMovePlanner.databaseEndpoint(of: project, servers: [:])

        #expect(endpoint == HerdMovePlanner.Endpoint(kind: "mysql", port: 3306, socket: nil, name: "news", account: DatabaseAccount(user: "root", password: "")))
    }

    @Test func aDatabaseOnAnotherHostIsNotPartOfTheMove() {
        let project = laravel(["DB_CONNECTION": "mysql", "DB_HOST": "db.example.com", "DB_DATABASE": "shop"])

        #expect(HerdMovePlanner.databaseEndpoint(of: project, servers: [:]) == nil)
    }

    @Test func redisMovesOnlyForASiteThatUsesItAndValkeyGoesToTheNewestRedis() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let herd = try folders.folder("Herd")
        let shop = try folders.folder("Herd/shop")
        let cache = try folders.folder("Herd/cache")
        let blog = try folders.folder("Herd/blog")
        let projects = [
            shop.plain: laravel(["CACHE_STORE": "redis", "REDIS_HOST": "127.0.0.1", "REDIS_PORT": "6379"]),
            cache.plain: laravel(["QUEUE_CONNECTION": "redis", "REDIS_PORT": "6380"]),
            blog.plain: laravel(["CACHE_STORE": "file", "REDIS_PORT": "6379"]),
        ]
        let servers = [6379: HerdMoveFacts.Server(kind: "redis", version: "7.4.2"), 6380: HerdMoveFacts.Server(kind: "valkey", version: "8.1.1")]

        let plan = HerdMovePlanner.plan(setup: HerdSetup(parkedFolders: [herd], defaultPHP: "8.5"), facts: facts(home: folders.root, projects: projects, servers: servers))

        #expect(plan.redis.map(\.port) == [6380, 6379])
        #expect(plan.redis.first { $0.port == 6379 }?.line == "8.2")
        #expect(plan.redis.first { $0.port == 6379 }?.keys == 3)
        #expect(plan.redis.first { $0.port == 6379 }?.sites == ["shop.test"])
        #expect(plan.redis.first { $0.port == 6380 }?.valkey == true)
        #expect(plan.redis.first { $0.port == 6380 }?.line == "8")
    }

    @Test func eachPackageThatIsNotInstalledComesFirstWithItsReasons() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let api = try folders.folder("Code/api")
        let docs = try folders.folder("Code/docs")
        let blog = try folders.folder("Code/blog")
        let setup = HerdSetup(
            links: [HerdSetup.Link(names: ["api"], folder: api), HerdSetup.Link(names: ["docs"], folder: docs), HerdSetup.Link(names: ["blog"], folder: blog)],
            siteFiles: [HerdSetup.SiteFile(host: "api.test", php: "8.3"), HerdSetup.SiteFile(host: "docs.test", php: "8.3")],
            defaultPHP: "8.5"
        )
        let projects = [blog.plain: laravel(["DB_CONNECTION": "pgsql", "DB_DATABASE": "blog"])]

        let plan = HerdMovePlanner.plan(setup: setup, facts: facts(home: folders.root, projects: projects, servers: [5432: HerdMoveFacts.Server(kind: "postgresql", version: "17.7")]))

        #expect(plan.packages == [
            HerdMovePlan.Package(name: "php", line: "8.3", reason: "for api.test, docs.test", bytes: 31_000_000),
            HerdMovePlan.Package(name: "postgresql", line: "17", reason: "for blog", bytes: 42_000_000),
        ])
    }

    @Test func theShellLinesOfHerdLeaveTheOwnNVMOfTheUserAlone() {
        let text = """
        export NVM_DIR="/Users/ann/Library/Application Support/Herd/config/nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"  # This loads nvm

        [[ -f "/Applications/Herd.app/Contents/Resources/config/shell/zshrc.zsh" ]] && builtin source "/Applications/Herd.app/Contents/Resources/config/shell/zshrc.zsh"

        # Herd injected PHP binary.
        export PATH="/Users/ann/Library/Application Support/Herd/bin":$PATH
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"  # This loads nvm
        alias ll="ls -la"
        """

        #expect(HerdMovePlanner.herdShellLines(in: text) == [
            #"export NVM_DIR="/Users/ann/Library/Application Support/Herd/config/nvm""#,
            #"[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm"#,
            #"[[ -f "/Applications/Herd.app/Contents/Resources/config/shell/zshrc.zsh" ]] && builtin source "/Applications/Herd.app/Contents/Resources/config/shell/zshrc.zsh""#,
            "# Herd injected PHP binary.",
            #"export PATH="/Users/ann/Library/Application Support/Herd/bin":$PATH"#,
        ])
    }

    @Test func twoHerdVersionsOnOneLineKeepTheLinesOfThatVersion() {
        let setup = HerdSetup(phpIniLines: ["8.1": ["memory_limit=256M"], "8.2": ["memory_limit=1G"], "8.5": ["max_execution_time=123"]])

        let items = HerdMovePlanner.iniItems(setup: setup, phpLines: ["8.2", "8.3", "8.4", "8.5"])

        #expect(items == [HerdMovePlan.IniItem(herdPHP: "8.2", line: "8.2", lines: ["memory_limit=1G"]), HerdMovePlan.IniItem(herdPHP: "8.5", line: "8.5", lines: ["max_execution_time=123"])])
    }
}
