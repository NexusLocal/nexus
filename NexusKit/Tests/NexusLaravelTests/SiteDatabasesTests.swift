import NexusCore
import Testing
@testable import NexusLaravel

struct SiteDatabasesTests {
    private let instances = [
        SiteDatabases.Instance(id: "mysql-8.0", usesMySQLProtocol: true, port: 3306),
        SiteDatabases.Instance(id: "postgresql-17", usesMySQLProtocol: false, port: 15432),
    ]

    private func setting(_ value: ConfigValue, _ key: String?) -> ConfigSetting {
        ConfigSetting(value: value, keys: key.map { [$0] } ?? [], exact: key != nil)
    }

    private func connection(_ name: String, driver: String, database: ConfigValue, host: String = "127.0.0.1", port: Int = 3306, keys prefix: String? = "DB") -> [String: ConfigSetting] {
        [
            "database.connections.\(name).driver": ConfigSetting(value: .text(driver)),
            "database.connections.\(name).database": setting(database, prefix.map { "\($0)_DATABASE" }),
            "database.connections.\(name).host": setting(.text(host), prefix.map { "\($0)_HOST" }),
            "database.connections.\(name).port": setting(.text(String(port)), prefix.map { "\($0)_PORT" }),
        ]
    }

    private func list(_ parts: [[String: ConfigSetting]], connections: [String], default name: String = "mysql") -> [SiteDatabase] {
        let settings = parts.reduce(["database.default": ConfigSetting(value: .text(name))]) { $0.merging($1) { own, _ in own } }
        let configuration = LaravelConfiguration(version: "12.0.0", settings: settings, databaseConnections: connections, redisConnections: [])

        return SiteDatabases.list(configuration, instances: instances)
    }

    @Test func aNewApplicationShowsOnlyItsDefaultConnection() {
        let databases = list([
            connection("sqlite", driver: "sqlite", database: .text("/work/shop/database/database.sqlite")),
            connection("mysql", driver: "mysql", database: .text("shop")),
            connection("mariadb", driver: "mariadb", database: .text("shop")),
            connection("pgsql", driver: "pgsql", database: .text("shop")),
        ], connections: ["sqlite", "mysql", "mariadb", "pgsql"])

        #expect(databases == [SiteDatabase(connection: "mysql", database: "shop", host: "127.0.0.1", port: 3306, instance: "mysql-8.0")])
    }

    @Test func aSQLiteApplicationShowsNoStockConnectionOnTheStandardPort() {
        let databases = list([
            connection("sqlite", driver: "sqlite", database: .text("/work/shop/database/database.sqlite")),
            connection("mysql", driver: "mysql", database: .text("laravel"), keys: nil),
            connection("pgsql", driver: "pgsql", database: .text("laravel"), port: 15432, keys: nil),
        ], connections: ["sqlite", "mysql", "pgsql"], default: "sqlite")

        #expect(databases.isEmpty)
    }

    @Test func aSecondConnectionWithItsOwnKeysShowsToo() {
        let databases = list([
            connection("mysql", driver: "mysql", database: .text("shop")),
            connection("cms", driver: "mysql", database: .text("shop_cms"), keys: "CMS_DB"),
        ], connections: ["cms", "mysql"])

        #expect(databases.map(\.connection) == ["mysql", "cms"])
        #expect(databases.map(\.instance) == ["mysql-8.0", "mysql-8.0"])
    }

    @Test func theDefaultConnectionToAnotherServerShowsWithoutAnInstance() {
        let databases = list([
            connection("mysql", driver: "mysql", database: .text("shop"), port: 8889),
            connection("pgsql", driver: "pgsql", database: .text("shop"), port: 8889),
        ], connections: ["mysql", "pgsql"])

        #expect(databases == [SiteDatabase(connection: "mysql", database: "shop", host: "127.0.0.1", port: 8889, instance: nil)])
    }

    @Test func aRemoteHostIsNeverANexusInstance() {
        let databases = list([connection("mysql", driver: "mysql", database: .text("shop"), host: "db.example.com")], connections: ["mysql"])

        #expect(databases.first?.instance == nil)
        #expect(databases.first?.host == "db.example.com")
    }

    @Test func aPostgreSQLConnectionFindsThePostgreSQLInstance() {
        let databases = list([connection("pgsql", driver: "pgsql", database: .text("shop"), port: 15432)], connections: ["pgsql"], default: "pgsql")

        #expect(databases.first?.instance == "postgresql-17")
    }

    @Test func theDefaultConnectionWithoutADatabaseNameStillShowsItsServer() {
        let databases = list([connection("mysql", driver: "mysql", database: .null)], connections: ["mysql"])

        #expect(databases == [SiteDatabase(connection: "mysql", database: "", host: "127.0.0.1", port: 3306, instance: "mysql-8.0")])
    }

    @Test func theDatabaseOfTheWriteSettingsComesFirst() {
        let settings = connection("mysql", driver: "mysql", database: .null).merging([
            "database.connections.mysql.write.database": ConfigSetting(value: .text("shop_write")),
        ]) { own, _ in own }

        #expect(list([settings], connections: ["mysql"]).first?.database == "shop_write")
    }
}
