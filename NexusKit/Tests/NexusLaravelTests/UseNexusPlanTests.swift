import NexusCore
import Testing
@testable import NexusLaravel

struct UseNexusPlanTests {
    private static let mampSocket = "/Applications/MAMP/tmp/mysql/mysql.sock"

    private static let mampEnv = """
        APP_URL=http://localhost:8888
        DB_CONNECTION=mysql
        DB_HOST=localhost
        DB_PORT=8889
        DB_SOCKET=/Applications/MAMP/tmp/mysql/mysql.sock
        DB_DATABASE=shop
        DB_USERNAME=root
        DB_PASSWORD=root
        CACHE_STORE=redis
        REDIS_HOST=127.0.0.1
        REDIS_PASSWORD=null
        REDIS_PORT=6379

        """

    private static let mysql84 = UseNexusPlan.Server(id: "mysql-8.4", name: "MySQL 8.4", kind: .mysql, version: "8.4.3", port: 13306, socket: "/nexus/run/mysql-8.4.sock", account: .newInstance)
    private static let redis74 = UseNexusPlan.RedisServer(id: "redis-7.4", port: 16379, running: true)

    private func setting(_ value: ConfigValue, _ key: String?) -> ConfigSetting {
        ConfigSetting(value: value, keys: key.map { [$0] } ?? [], exact: key != nil)
    }

    private func mampSettings() -> [String: ConfigSetting] {
        [
            "app.url": setting(.text("http://localhost:8888"), "APP_URL"),
            "database.default": setting(.text("mysql"), "DB_CONNECTION"),
            "database.connections.mysql.driver": ConfigSetting(value: .text("mysql")),
            "database.connections.mysql.url": setting(.null, "DB_URL"),
            "database.connections.mysql.host": setting(.text("localhost"), "DB_HOST"),
            "database.connections.mysql.port": setting(.text("8889"), "DB_PORT"),
            "database.connections.mysql.database": setting(.text("shop"), "DB_DATABASE"),
            "database.connections.mysql.username": setting(.text("root"), "DB_USERNAME"),
            "database.connections.mysql.password": setting(.text("root"), "DB_PASSWORD"),
            "database.connections.mysql.unix_socket": setting(.text(Self.mampSocket), "DB_SOCKET"),
            "cache.default": setting(.text("redis"), "CACHE_STORE"),
            "cache.stores.redis.driver": ConfigSetting(value: .text("redis")),
            "database.redis.default.url": setting(.null, "REDIS_URL"),
            "database.redis.default.host": setting(.text("127.0.0.1"), "REDIS_HOST"),
            "database.redis.default.port": setting(.number(6379), "REDIS_PORT"),
            "database.redis.default.password": setting(.null, "REDIS_PASSWORD"),
            "database.redis.cache.url": setting(.null, "REDIS_URL"),
            "database.redis.cache.host": setting(.text("127.0.0.1"), "REDIS_HOST"),
            "database.redis.cache.port": setting(.number(6379), "REDIS_PORT"),
            "database.redis.cache.password": setting(.null, "REDIS_PASSWORD"),
        ]
    }

    private func plan(
        _ settings: [String: ConfigSetting],
        env: String = mampEnv,
        hosts: [String] = ["shop.test"],
        servers: [UseNexusPlan.Server] = [mysql84],
        redisServers: [UseNexusPlan.RedisServer] = [redis74],
        connections: [String] = ["mysql"]
    ) -> UseNexusPlan {
        let configuration = LaravelConfiguration(version: "12.0.0", settings: settings, databaseConnections: connections, redisConnections: ["default", "cache"])
        let input = UseNexusPlan.Input(envText: env, hosts: hosts, url: "https://shop.test:8443", httpsPort: 8443, databaseServers: servers, redisServers: redisServers)

        return UseNexusPlan(configuration: configuration, input: input)
    }

    private func with(_ changes: [String: ConfigSetting]) -> [String: ConfigSetting] {
        mampSettings().merging(changes) { _, new in new }
    }

    private func choice(_ id: String, kind: DatabaseKind = .mysql, version: String) -> UseNexusPlan.Choice {
        UseNexusPlan.Choice(server: UseNexusPlan.Server(id: id, name: id, kind: kind, version: version, port: 13306, socket: "/nexus/run/\(id).sock", account: .newInstance), changes: [])
    }

    @Test func theMAMPSiteOfTheDesignGetsSixKeys() {
        let plan = self.plan(mampSettings())

        #expect(plan.appURL == EnvValueChange(key: "APP_URL", oldValue: "http://localhost:8888", newValue: "https://shop.test:8443"))
        #expect(plan.appURLValue == "http://localhost:8888")
        #expect(plan.database?.connection == "mysql")
        #expect(plan.database?.name == "shop")
        #expect(plan.database?.choices.map(\.server.id) == ["mysql-8.4"])
        #expect(plan.database?.choices.first?.changes == [
            EnvValueChange(key: "DB_HOST", oldValue: "localhost", newValue: "127.0.0.1"),
            EnvValueChange(key: "DB_PORT", oldValue: "8889", newValue: "13306"),
            EnvValueChange(key: "DB_SOCKET", oldValue: Self.mampSocket, newValue: nil),
            EnvValueChange(key: "DB_PASSWORD", oldValue: "root", newValue: ""),
        ])
        #expect(plan.database?.source == UseNexusPlan.Source(kind: .mysql, host: "localhost", port: 8889, socket: Self.mampSocket, account: .standard))
        #expect(plan.redis == [EnvValueChange(key: "REDIS_PORT", oldValue: "6379", newValue: "16379")])
        #expect(plan.changes(choosing: "mysql-8.4").map(\.key) == ["APP_URL", "DB_HOST", "DB_PORT", "DB_SOCKET", "DB_PASSWORD", "REDIS_PORT"])
        #expect(plan.changes(choosing: nil).map(\.key) == ["APP_URL", "REDIS_PORT"])
    }

    @Test func aSiteOnNexusGetsAnEmptyPlan() {
        let settings = with([
            "app.url": setting(.text("https://shop.test:8443"), "APP_URL"),
            "database.connections.mysql.host": setting(.text("127.0.0.1"), "DB_HOST"),
            "database.connections.mysql.port": setting(.text("13306"), "DB_PORT"),
            "database.connections.mysql.password": setting(.text(""), "DB_PASSWORD"),
            "database.connections.mysql.unix_socket": setting(.text(""), "DB_SOCKET"),
            "database.redis.default.port": setting(.number(16379), "REDIS_PORT"),
            "database.redis.cache.port": setting(.number(16379), "REDIS_PORT"),
        ])

        #expect(plan(settings).isEmpty)
    }

    @Test func theSocketOfAnInstanceCountsAsNexus() {
        let settings = with(["database.connections.mysql.unix_socket": setting(.text("/nexus/run/mysql-8.4.sock"), "DB_SOCKET")])

        #expect(plan(settings).database == nil)
    }

    @Test func localhostWithoutASocketIsNoNexusServerForMySQL() {
        let settings = with([
            "database.connections.mysql.port": setting(.text("13306"), "DB_PORT"),
            "database.connections.mysql.password": setting(.text(""), "DB_PASSWORD"),
            "database.connections.mysql.unix_socket": setting(.text(""), "DB_SOCKET"),
        ])

        let database = plan(settings).database

        #expect(database?.choices.first?.changes == [EnvValueChange(key: "DB_HOST", oldValue: "localhost", newValue: "127.0.0.1")])
        #expect(database?.source == UseNexusPlan.Source(kind: .mysql, host: "127.0.0.1", port: 13306, socket: nil, account: DatabaseAccount(user: "root", password: "")))
    }

    @Test func localhostCountsAsNexusForPostgreSQL() {
        let settings: [String: ConfigSetting] = [
            "database.default": setting(.text("pgsql"), "DB_CONNECTION"),
            "database.connections.pgsql.driver": ConfigSetting(value: .text("pgsql")),
            "database.connections.pgsql.host": setting(.text("localhost"), "DB_HOST"),
            "database.connections.pgsql.port": setting(.text("15432"), "DB_PORT"),
            "database.connections.pgsql.database": setting(.text("shop"), "DB_DATABASE"),
            "database.connections.pgsql.username": setting(.text("root"), "DB_USERNAME"),
            "database.connections.pgsql.password": setting(.text(""), "DB_PASSWORD"),
        ]
        let postgresql = UseNexusPlan.Server(id: "postgresql-17", name: "PostgreSQL 17", kind: .postgresql, version: "17.2", port: 15432, socket: "/nexus/run/.s.PGSQL.15432", account: .newInstance)

        #expect(plan(settings, servers: [postgresql], connections: ["pgsql"]).database == nil)
    }

    @Test func aDatabaseOnAnotherComputerStays() {
        let settings = with([
            "database.connections.mysql.host": setting(.text("db.example.com"), "DB_HOST"),
            "database.connections.mysql.unix_socket": setting(.text(""), "DB_SOCKET"),
        ])

        #expect(plan(settings).database == nil)
    }

    @Test func aFixedHostInTheConfigurationLeavesTheDatabaseOut() {
        let settings = with(["database.connections.mysql.host": setting(.text("localhost"), nil)])

        #expect(plan(settings).database == nil)
    }

    @Test func aURLOfTheConnectionLeavesTheDatabaseOut() {
        let settings = with(["database.connections.mysql.url": setting(.text("mysql://root:root@127.0.0.1:8889/shop"), "DB_URL")])

        #expect(plan(settings).database == nil)
    }

    @Test func aSocketKeyWithoutALineGetsAnEmptyValue() {
        let env = Self.mampEnv.replacing("DB_SOCKET=\(Self.mampSocket)\n", with: "")

        let changes = plan(mampSettings(), env: env).database?.choices.first?.changes ?? []

        #expect(changes.contains(EnvValueChange(key: "DB_SOCKET", oldValue: nil, newValue: "")))
    }

    @Test func aSQLiteApplicationHasNoDatabasePart() {
        let settings = with([
            "database.default": setting(.text("sqlite"), "DB_CONNECTION"),
            "database.connections.sqlite.driver": ConfigSetting(value: .text("sqlite")),
            "database.connections.sqlite.database": ConfigSetting(value: .text("/work/shop/database/database.sqlite")),
        ])

        #expect(plan(settings, connections: ["sqlite", "mysql"]).database == nil)
    }

    @Test func anInvalidDatabaseNameGivesNoName() {
        let settings = with(["database.connections.mysql.database": setting(.text("shop.old"), "DB_DATABASE")])

        let database = plan(settings).database

        #expect(database != nil)
        #expect(database?.name == nil)
        #expect(database?.choices.first?.changes.isEmpty == false)
    }

    @Test(arguments: ["https://www.shop.test:8443/", "HTTPS://SHOP.TEST:8443"])
    func anAppURLOfAnAliasOrWithASlashUsesNexus(url: String) {
        let settings = with(["app.url": setting(.text(url), "APP_URL")])

        let plan = self.plan(settings, hosts: ["shop.test", "www.shop.test"])

        #expect(plan.appURL == nil)
        #expect(plan.appURLValue == nil)
    }

    @Test(arguments: ["http://shop.test:8443", "https://shop.test", "https://shop.test:8443/shop", "https://other.test:8443"])
    func anAppURLWithHTTPOrAnotherPortChanges(url: String) {
        let settings = with(["app.url": setting(.text(url), "APP_URL")])

        let plan = self.plan(settings)

        #expect(plan.appURL?.newValue == "https://shop.test:8443")
        #expect(plan.appURLValue == url)
    }

    @Test func aFixedAppURLGivesNoChange() {
        let settings = with(["app.url": setting(.text("http://localhost"), nil)])

        #expect(plan(settings).appURL == nil)
    }

    @Test func redisCountsOnlyWhenTheApplicationUsesIt() {
        let settings = with([
            "cache.default": setting(.text("file"), "CACHE_STORE"),
            "cache.stores.file.driver": ConfigSetting(value: .text("file")),
        ])

        let plan = self.plan(settings)

        #expect(plan.redis.isEmpty)
    }

    @Test func aRedisPasswordBecomesEmpty() {
        let settings = with([
            "database.redis.default.password": setting(.text("secret"), "REDIS_PASSWORD"),
            "database.redis.cache.password": setting(.text("secret"), "REDIS_PASSWORD"),
        ])
        let env = Self.mampEnv.replacing("REDIS_PASSWORD=null", with: "REDIS_PASSWORD=secret")

        #expect(plan(settings, env: env).redis == [
            EnvValueChange(key: "REDIS_PORT", oldValue: "6379", newValue: "16379"),
            EnvValueChange(key: "REDIS_PASSWORD", oldValue: "secret", newValue: ""),
        ])
    }

    @Test func theRunningRedisServerComesFirst() {
        let servers = [
            UseNexusPlan.RedisServer(id: "redis-8.0", port: 26379, running: false),
            UseNexusPlan.RedisServer(id: "redis-7.4", port: 16379, running: true),
            UseNexusPlan.RedisServer(id: "redis-7.2", port: 17379, running: true),
        ]

        let plan = self.plan(mampSettings(), redisServers: servers)

        #expect(plan.redis == [EnvValueChange(key: "REDIS_PORT", oldValue: "6379", newValue: "16379")])
        #expect(plan.redisServer == "redis-7.4")
    }

    @Test func theServerOfTheSameKindWithTheClosestVersionComesFirst() {
        let mysql = [choice("mysql-8.4", version: "8.4.3"), choice("mysql-8.0", version: "8.0.40"), choice("mariadb-11.4", kind: .mariadb, version: "11.4.4")]
        let newer = [choice("mysql-9.1", version: "9.1.0"), choice("mysql-8.4", version: "8.4.3")]
        let mariadb = [choice("mariadb-11.4", kind: .mariadb, version: "11.4.4"), choice("mysql-8.4", version: "8.4.3"), choice("mariadb-10.6", kind: .mariadb, version: "10.6.20")]

        #expect(UseNexusPlan.ordered(mysql, kind: .mysql, oldVersion: "5.7.44").map(\.server.id) == ["mysql-8.0", "mysql-8.4", "mariadb-11.4"])
        #expect(UseNexusPlan.ordered(newer, kind: .mysql, oldVersion: "8.0.35").map(\.server.id) == ["mysql-8.4", "mysql-9.1"])
        #expect(UseNexusPlan.ordered(mariadb, kind: .mysql, oldVersion: "10.11.6-MariaDB").map(\.server.id) == ["mariadb-10.6", "mariadb-11.4", "mysql-8.4"])
        #expect(UseNexusPlan.oldKind(.mysql, version: "10.11.6-MariaDB") == .mariadb)
        #expect(UseNexusPlan.oldKind(.mariadb, version: "8.0.40") == .mysql)
        #expect(UseNexusPlan.oldKind(.mariadb, version: nil) == .mariadb)
    }

    @Test func withoutAVersionMySQL84ComesFirst() {
        let choices = [choice("mariadb-11.4", kind: .mariadb, version: "11.4.4"), choice("mysql-8.0", version: "8.0.40"), choice("mysql-9.1", version: "9.1.0"), choice("mysql-8.4", version: "8.4.3")]

        #expect(UseNexusPlan.ordered(choices, kind: .mysql, oldVersion: nil).map(\.server.id) == ["mysql-8.4", "mysql-9.1", "mysql-8.0", "mariadb-11.4"])
        #expect(UseNexusPlan.ordered(choices, kind: .mariadb, oldVersion: nil).map(\.server.id) == ["mariadb-11.4", "mysql-9.1", "mysql-8.4", "mysql-8.0"])
    }

    @Test func aChoiceGetsTheAccountOfItsServer() {
        let mysql80 = UseNexusPlan.Server(id: "mysql-8.0", name: "MySQL 8.0", kind: .mysql, version: "8.0.40", port: 13307, socket: "/nexus/run/mysql-8.0.sock", account: .standard)
        let mariadb = UseNexusPlan.Server(id: "mariadb-11.4", name: "MariaDB 11.4", kind: .mariadb, version: "11.4.4", port: 13308, socket: "/nexus/run/mariadb-11.4.sock", account: DatabaseAccount(user: "nexus", password: "secret"))

        let choices = plan(mampSettings(), servers: [Self.mysql84, mysql80, mariadb]).database?.choices ?? []
        let changes = Dictionary(uniqueKeysWithValues: choices.map { ($0.server.id, $0.changes.filter { $0.key == "DB_USERNAME" || $0.key == "DB_PASSWORD" }) })

        #expect(choices.map(\.server.id) == ["mysql-8.4", "mysql-8.0", "mariadb-11.4"])
        #expect(changes["mysql-8.4"] == [EnvValueChange(key: "DB_PASSWORD", oldValue: "root", newValue: "")])
        #expect(changes["mysql-8.0"] == [])
        #expect(changes["mariadb-11.4"] == [
            EnvValueChange(key: "DB_USERNAME", oldValue: "root", newValue: "nexus"),
            EnvValueChange(key: "DB_PASSWORD", oldValue: "root", newValue: "secret"),
        ])
    }
}
