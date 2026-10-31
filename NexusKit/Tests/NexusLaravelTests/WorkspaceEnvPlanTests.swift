import NexusCore
import Testing
@testable import NexusLaravel

struct WorkspaceEnvPlanTests {
    private let request = WorkspaceEnvRequest(
        workspace: "ticket-1",
        mainFolder: "/work/shop",
        workspaceFolder: "/work/ticket-1",
        mysqlPorts: [13306],
        postgresqlPorts: [15432],
        redisPorts: [16379]
    )

    private func keyed(_ value: ConfigValue, _ key: String) -> ConfigSetting {
        ConfigSetting(value: value, keys: [key], exact: true)
    }

    private func connection(_ name: String, database: ConfigSetting, driver: String = "mysql", port: Int = 13306, host: String = "127.0.0.1") -> [String: ConfigSetting] {
        [
            "database.connections.\(name).driver": ConfigSetting(value: .text(driver)),
            "database.connections.\(name).database": database,
            "database.connections.\(name).host": keyed(.text(host), "DB_HOST"),
            "database.connections.\(name).port": keyed(.text(String(port)), "DB_PORT"),
        ]
    }

    private func plan(_ settings: [String: ConfigSetting], connections: [String] = ["main"], redis: [String] = []) -> WorkspaceEnvPlan {
        let all = settings.merging(["database.default": ConfigSetting(value: .text("main"))]) { own, _ in own }
        return WorkspaceEnvPlan(
            configuration: LaravelConfiguration(version: "12.0.0", settings: all, databaseConnections: connections, redisConnections: redis),
            request: request
        )
    }

    private func redisConnection(_ name: String, database: ConfigSetting, port: Int = 16379) -> [String: ConfigSetting] {
        [
            "database.redis.\(name).database": database,
            "database.redis.\(name).port": keyed(.number(Double(port)), "REDIS_PORT"),
        ]
    }

    private let sessionOnRedis = ["session.driver": ConfigSetting(value: .text("redis"))]

    @Test func reverbGetsItsPortKeysAndKeepsThePortOfItsRedisConnection() {
        let result = plan([
            "broadcasting.default": ConfigSetting(value: .text("reverb")),
            "broadcasting.connections.reverb.driver": ConfigSetting(value: .text("reverb")),
            "broadcasting.connections.reverb.options.port": keyed(.number(8080), "REVERB_PORT"),
            "reverb.servers.reverb.port": keyed(.number(8080), "REVERB_SERVER_PORT"),
            "reverb.servers.reverb.scaling.server.port": keyed(.number(6379), "REDIS_PORT"),
            "reverb.apps.apps.0.options.port": keyed(.number(8080), "REVERB_APP_PORT"),
        ])

        #expect(result.reverbPortKeys == ["REVERB_APP_PORT", "REVERB_PORT", "REVERB_SERVER_PORT", "VITE_REVERB_PORT"])
    }

    @Test func anApplicationWithoutReverbHasNoReverbPortKeys() {
        let result = plan([
            "broadcasting.default": ConfigSetting(value: .text("pusher")),
            "broadcasting.connections.pusher.driver": ConfigSetting(value: .text("pusher")),
            "broadcasting.connections.pusher.options.port": keyed(.number(443), "PUSHER_PORT"),
        ])

        #expect(result.reverbPortKeys.isEmpty)
    }

    @Test func aDatabaseOnANexusInstanceGetsACopyName() {
        let result = plan(connection("main", database: keyed(.text("shop"), "DB_DATABASE")))

        #expect(result.keys == ["DB_DATABASE": "shop_ticket_1"])
        #expect(result.database == "shop_ticket_1")
        #expect(result.problems.isEmpty)
    }

    @Test func thePlanNamesEachDatabaseThatTheSetupCopiesOnce() {
        let settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
            .merging(connection("sessions", database: keyed(.text("shop"), "DB_DATABASE"))) { own, _ in own }
            .merging(connection("cms", database: keyed(.text("shop_cms"), "DB_CMS"))) { own, _ in own }

        let result = plan(settings, connections: ["sessions", "cms", "main"])

        #expect(result.databases == [
            WorkspaceDatabase(name: "shop", copy: "shop_ticket_1", port: 13306, isDefault: true),
            WorkspaceDatabase(name: "shop_cms", copy: "shop_cms_ticket_1", port: 13306, isDefault: false),
        ])
    }

    @Test func aFixedDatabaseNameIsNoCopy() {
        #expect(plan(connection("cms", database: ConfigSetting(value: .text("shop_cms"))), connections: ["cms"]).databases.isEmpty)
    }

    @Test func aSQLiteFileIsAFileToClone() {
        let result = plan(connection("main", database: keyed(.text("/work/shop/database/database.sqlite"), "DB_DATABASE"), driver: "sqlite"))

        #expect(result.sqliteFiles == [WorkspaceFile(from: "/work/shop/database/database.sqlite", to: "/work/ticket-1/database/database.sqlite")])
    }

    @Test func aSQLiteFileIsNoCloneWhenTheDefaultConnectionGivesItsKeyAnotherValue() {
        let settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
            .merging(connection("sqlite", database: keyed(.text("/work/shop/database/database.sqlite"), "DB_DATABASE"), driver: "sqlite")) { own, _ in own }

        let result = plan(settings, connections: ["sqlite", "main"])

        #expect(result.keys["DB_DATABASE"] == "shop_ticket_1")
        #expect(result.sqliteFiles.isEmpty)
    }

    @Test func aPostgreSQLDatabaseUsesThePortOfPostgreSQL() {
        let result = plan(connection("main", database: keyed(.text("shop"), "DB_DATABASE"), driver: "pgsql", port: 15432))

        #expect(result.keys == ["DB_DATABASE": "shop_ticket_1"])
    }

    @Test func theFourMySQLConnectionsGetTheirOwnKeys() {
        let settings = connection("main", database: keyed(.text("a"), "DB_DATABASE"))
            .merging(connection("postcalc", database: keyed(.text("b"), "DB_DATABASE_POSTCALC"))) { own, _ in own }
            .merging(connection("smartforms", database: keyed(.text("c"), "DB_DATABASE_SMARTFORMS"))) { own, _ in own }
            .merging(connection("sessions", database: keyed(.text("a"), "DB_DATABASE"))) { own, _ in own }

        let result = plan(settings, connections: ["main", "postcalc", "smartforms", "sessions"])

        #expect(result.keys == ["DB_DATABASE": "a_ticket_1", "DB_DATABASE_POSTCALC": "b_ticket_1", "DB_DATABASE_SMARTFORMS": "c_ticket_1"])
    }

    @Test func aFixedDatabaseNameIsNotIsolated() {
        let result = plan(connection("cms", database: ConfigSetting(value: .text("shop_cms"))), connections: ["cms"])

        #expect(result.problems == ["The connection cms has a fixed database name in config/database.php."])
    }

    @Test func aDatabaseNameThatTheApplicationChangesIsNotIsolated() {
        let result = plan(connection("main", database: ConfigSetting(value: .text("app_shop"), keys: ["TENANT"], exact: false)))

        #expect(result.problems == ["The connection main has a fixed database name in config/database.php."])
    }

    @Test func theDefaultConnectionOnAnotherServerIsNotIsolated() {
        let result = plan(connection("main", database: keyed(.text("shop"), "DB_DATABASE"), port: 3306))

        #expect(result.keys.isEmpty)
        #expect(result.problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func anotherConnectionOnAnotherServerChangesNothing() {
        let settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
            .merging(connection("old", database: keyed(.text("old"), "OLD_DB"), port: 3306)) { own, _ in own }

        let result = plan(settings, connections: ["main", "old"])

        #expect(result.keys == ["DB_DATABASE": "shop_ticket_1"])
        #expect(result.problems.isEmpty)
    }

    @Test func aRemoteHostIsNotANexusInstance() {
        let result = plan(connection("main", database: keyed(.text("shop"), "DB_DATABASE"), host: "db.example.test"))

        #expect(result.problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func aDefaultConnectionWithADriverOfAnotherServerIsNotIsolated() {
        let result = plan(connection("main", database: keyed(.text("shop"), "DB_DATABASE"), driver: "sqlsrv"))

        #expect(result.keys.isEmpty)
        #expect(result.problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func anotherConnectionWithADriverOfAnotherServerChangesNothing() {
        let settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
            .merging(connection("old", database: keyed(.text("old"), "OLD_DB"), driver: "sqlsrv")) { own, _ in own }

        #expect(plan(settings, connections: ["old", "main"]).problems.isEmpty)
    }

    @Test func aDefaultSQLiteFileKeepsItsKeyWhenAMySQLConnectionSharesThatKey() {
        let settings = connection("main", database: keyed(.text("/work/shop/database/database.sqlite"), "DB_DATABASE"), driver: "sqlite")
            .merging(connection("mysql", database: keyed(.text("laravel"), "DB_DATABASE"))) { own, _ in own }

        let result = plan(settings, connections: ["mysql", "main"])

        #expect(result.keys == ["DB_DATABASE": "/work/ticket-1/database/database.sqlite"])
        #expect(result.database == "/work/ticket-1/database/database.sqlite")
    }

    @Test func aRemoteWriteHostBehindAnEmptyHostIsNotANexusInstance() {
        let settings: [String: ConfigSetting] = [
            "database.connections.main.driver": ConfigSetting(value: .text("mysql")),
            "database.connections.main.database": keyed(.text("shop"), "DB_DATABASE"),
            "database.connections.main.host": ConfigSetting(value: .null),
            "database.connections.main.port": ConfigSetting(value: .null),
            "database.connections.main.write.host": keyed(.text("db.example.test"), "DB_HOST_PRIMARY"),
            "database.connections.main.write.port": keyed(.text("13306"), "DB_PORT_PRIMARY"),
        ]

        #expect(plan(settings).problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func aRemoteWriteHostOverALocalHostIsNotANexusInstance() {
        var settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
        settings["database.connections.main.write.host"] = keyed(.text("db.example.test"), "DB_HOST_PRIMARY")

        #expect(plan(settings).problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func aRemoteWriteHostInAListIsNotANexusInstance() {
        var settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
        settings["database.connections.main.write.host.0"] = keyed(.text("db.example.test"), "DB_HOST_PRIMARY")

        #expect(plan(settings).problems == ["The connection main does not use a Nexus database instance."])
    }

    @Test func aSQLitePathThatTheApplicationBuildsFromAKeyIsNotIsolated() {
        let database = ConfigSetting(value: .text("/work/shop/database/shop.sqlite"), keys: ["DB_FILE"], exact: false)

        let result = plan(connection("main", database: database, driver: "sqlite"))

        #expect(result.keys.isEmpty)
        #expect(result.problems == ["The connection main builds its SQLite path from an env key, so Nexus cannot change it."])
    }

    @Test func aFixedSQLitePathInTheProjectFollowsTheWorktree() {
        let result = plan(connection("main", database: ConfigSetting(value: .text("/work/shop/database/shop.sqlite")), driver: "sqlite"))

        #expect(result.keys.isEmpty)
        #expect(result.database == "/work/ticket-1/database/shop.sqlite")
        #expect(result.problems.isEmpty)
    }

    @Test func aConnectionWithAURLIsNotIsolated() {
        var settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
        settings["database.connections.main.url"] = keyed(.text("mysql://127.0.0.1/shop"), "DB_URL")

        #expect(plan(settings).problems == ["The connection main has its database name in a URL."])
    }

    @Test func anEmptyURLIsNoProblem() {
        var settings = connection("main", database: keyed(.text("shop"), "DB_DATABASE"))
        settings["database.connections.main.url"] = keyed(.text(""), "DB_URL")

        #expect(plan(settings).problems.isEmpty)
    }

    @Test func aConnectionWithReadAndWriteHostsUsesTheWriteHost() {
        let settings: [String: ConfigSetting] = [
            "database.connections.main.driver": ConfigSetting(value: .text("mysql")),
            "database.connections.main.database": keyed(.text("shop"), "DB_DATABASE"),
            "database.connections.main.host": ConfigSetting(value: .null),
            "database.connections.main.port": ConfigSetting(value: .null),
            "database.connections.main.write.host": keyed(.text("127.0.0.1"), "DB_HOST_PRIMARY"),
            "database.connections.main.write.port": keyed(.text("13306"), "DB_PORT_PRIMARY"),
        ]

        #expect(plan(settings).keys == ["DB_DATABASE": "shop_ticket_1"])
    }

    @Test func aMergedConnectionWithoutANameIsSkipped() {
        #expect(plan(connection("main", database: keyed(.null, "VECTOR_DB"), driver: "pgsql", port: 15432)).keys.isEmpty)
    }

    @Test func aSQLiteFileInTheProjectGetsThePathInTheWorktree() {
        let result = plan(connection("main", database: keyed(.text("/work/shop/database/database.sqlite"), "DB_DATABASE"), driver: "sqlite"))

        #expect(result.keys == ["DB_DATABASE": "/work/ticket-1/database/database.sqlite"])
        #expect(result.database == "/work/ticket-1/database/database.sqlite")
    }

    @Test func aSQLiteFileOutsideTheProjectIsNotIsolated() {
        let result = plan(connection("main", database: keyed(.text("/data/shop.sqlite"), "DB_DATABASE"), driver: "sqlite"))

        #expect(result.problems == ["The connection main uses a SQLite file outside the project."])
    }

    @Test func aSQLiteConnectionWithADatabaseNameIsNoSQLiteFile() {
        let result = plan(connection("sqlite", database: keyed(.text("shop"), "DB_DATABASE"), driver: "sqlite"), connections: ["sqlite"])

        #expect(result.keys.isEmpty)
        #expect(result.problems.isEmpty)
    }

    @Test func aRedisIndexWithAKeyGoesToNexusd() {
        let settings = redisConnection("default", database: keyed(.number(0), "REDIS_DB"))
            .merging(redisConnection("cache", database: keyed(.number(1), "REDIS_CACHE_DB"))) { own, _ in own }
            .merging(sessionOnRedis) { own, _ in own }

        #expect(plan(settings, connections: [], redis: ["default", "cache"]).redisKeys == ["REDIS_CACHE_DB", "REDIS_DB"])
    }

    @Test func aRedisKeyNamesItsInstanceAndTheIndexOfTheMainSite() {
        let settings = redisConnection("default", database: keyed(.number(2), "REDIS_DB"))
            .merging(redisConnection("cache", database: keyed(.text("20"), "REDIS_CACHE_DB"))) { own, _ in own }
            .merging(sessionOnRedis) { own, _ in own }

        let result = plan(settings, connections: [], redis: ["default", "cache"])

        #expect(result.redisPorts == [16379])
        #expect(result.mainRedisIndexes == [2, 20])
    }

    @Test func aRedisIndexCountsAlsoWhenTheCacheTheSessionsAndTheQueueDoNotUseRedis() {
        let settings = redisConnection("reports", database: ConfigSetting(value: .number(20)))

        let result = plan(settings, connections: [], redis: ["reports"])

        #expect(result.redisKeys.isEmpty)
        #expect(result.mainRedisIndexes == [20])
    }

    @Test func aFixedRedisIndexIsAnIndexOfTheMainSiteAndNamesNoInstance() {
        let settings = redisConnection("cache", database: ConfigSetting(value: .number(20))).merging(sessionOnRedis) { own, _ in own }

        let result = plan(settings, connections: [], redis: ["cache"])

        #expect(result.redisPorts.isEmpty)
        #expect(result.mainRedisIndexes == [20])
    }

    @Test func oneKeyForFourConnectionsCountsOnce() {
        let settings = ["default", "cache", "session", "queue"]
            .reduce(sessionOnRedis) { all, name in all.merging(redisConnection(name, database: keyed(.number(0), "REDIS_DB"))) { own, _ in own } }

        #expect(plan(settings, connections: [], redis: ["default", "cache", "session", "queue"]).redisKeys == ["REDIS_DB"])
    }

    @Test func aFixedRedisIndexIsNotIsolated() {
        let settings = redisConnection("cache", database: ConfigSetting(value: .number(1))).merging(sessionOnRedis) { own, _ in own }

        #expect(plan(settings, connections: [], redis: ["cache"]).problems == ["The Redis connection cache has a fixed index in config/database.php."])
    }

    @Test func redisOnAnotherServerIsNotIsolated() {
        let settings = redisConnection("cache", database: keyed(.number(1), "REDIS_DB"), port: 6379).merging(sessionOnRedis) { own, _ in own }

        #expect(plan(settings, connections: [], redis: ["cache"]).problems == ["The Redis connection cache does not use a Nexus Redis instance."])
    }

    @Test func redisOnARemoteHostWithTheSamePortIsNotIsolated() {
        var settings = redisConnection("cache", database: keyed(.number(1), "REDIS_DB")).merging(sessionOnRedis) { own, _ in own }
        settings["database.redis.cache.host"] = keyed(.text("redis.example.test"), "REDIS_HOST")

        #expect(plan(settings, connections: [], redis: ["cache"]).problems == ["The Redis connection cache does not use a Nexus Redis instance."])
    }

    @Test func aRedisConnectionWithoutAnIndexIsNotIsolated() {
        let settings = sessionOnRedis.merging(["database.redis.cache.port": keyed(.number(16379), "REDIS_PORT")]) { own, _ in own }

        #expect(plan(settings, connections: [], redis: ["cache"]).problems == ["The Redis connection cache has a fixed index in config/database.php."])
    }

    @Test func anApplicationThatDoesNotUseRedisNeedsNoRedisKey() {
        let result = plan(redisConnection("cache", database: ConfigSetting(value: .number(1))), connections: [], redis: ["cache"])

        #expect(result.redisKeys.isEmpty)
        #expect(result.problems.isEmpty)
    }

    @Test(arguments: [
        ["cache.default": ConfigSetting(value: .text("redis")), "cache.stores.redis.driver": ConfigSetting(value: .text("redis"))],
        ["queue.default": ConfigSetting(value: .text("jobs")), "queue.connections.jobs.driver": ConfigSetting(value: .text("redis"))],
    ])
    func aCacheOrAQueueOnRedisUsesRedis(settings: [String: ConfigSetting]) {
        let all = redisConnection("cache", database: keyed(.number(1), "REDIS_DB")).merging(settings) { own, _ in own }

        #expect(plan(all, connections: [], redis: ["cache"]).redisKeys == ["REDIS_DB"])
    }
}

struct WorkspaceKeysTests {
    @Test func theValuesGetThePlaceholdersFilledIn() {
        let keys = [
            WorkspaceEnvKey(key: "PUSHER_HOST", value: "{host}"),
            WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}"),
            WorkspaceEnvKey(key: "NAME", value: "{workspace}:{database}"),
        ]

        let result = WorkspaceKeys.expanded(keys, workspace: "fix", host: "shop-fix.test", database: "shop_fix", ports: ["scout": 20000])

        #expect(result == ["PUSHER_HOST": "shop-fix.test", "SCOUT_PORT": "20000", "NAME": "fix:shop_fix"])
    }

    @Test func eachPortNameCountsOnce() {
        let keys = [WorkspaceEnvKey(key: "A", value: "{port:vite}:{port:scout}"), WorkspaceEnvKey(key: "B", value: "{port:vite}")]

        #expect(WorkspaceKeys.portNames(in: keys.map(\.value)) == ["scout", "vite"])
    }

    @Test func aValueForTheShellGetsQuotesOnlyWhenItNeedsThem() {
        #expect(WorkspaceKeys.shellWord("shop_fix") == "shop_fix")
        #expect(WorkspaceKeys.shellWord("/Users/tim/shop/database.sqlite") == "/Users/tim/shop/database.sqlite")
        #expect(WorkspaceKeys.shellWord("/Users/Tim Klaversma/db.sqlite") == "'/Users/Tim Klaversma/db.sqlite'")
        #expect(WorkspaceKeys.shellWord("/Users/tim's/db.sqlite") == #"'/Users/tim'\''s/db.sqlite'"#)
    }
}
