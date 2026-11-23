import NexusCore
import Testing
@testable import NexusLaravel

struct MongoDBConnectionTests {
    private static let mongodb80 = UseNexusPlan.Server(id: "mongodb-8.0", name: "MongoDB 8.0", kind: .mongodb, version: "8.0.38", port: 27017, socket: "/nexus/run/mongodb-8.0.sock", account: .newInstance)
    private static let mysql84 = UseNexusPlan.Server(id: "mysql-8.4", name: "MySQL 8.4", kind: .mysql, version: "8.4.3", port: 13306, socket: "/nexus/run/mysql-8.4.sock", account: .newInstance)

    private func setting(_ value: ConfigValue, _ key: String?) -> ConfigSetting {
        ConfigSetting(value: value, keys: key.map { [$0] } ?? [], exact: key != nil)
    }

    // MySQL of Nexus as the default connection and a MongoDB in Docker on port 27018 next to it.
    private func settings(dsn: String = "mongodb://localhost:27018", database: String = "shop") -> [String: ConfigSetting] {
        [
            "database.default": setting(.text("mysql"), "DB_CONNECTION"),
            "database.connections.mysql.driver": ConfigSetting(value: .text("mysql")),
            "database.connections.mysql.host": setting(.text("127.0.0.1"), "DB_HOST"),
            "database.connections.mysql.port": setting(.text("13306"), "DB_PORT"),
            "database.connections.mysql.database": setting(.text("shop"), "DB_DATABASE"),
            "database.connections.mysql.username": setting(.text("root"), "DB_USERNAME"),
            "database.connections.mysql.password": setting(.text(""), "DB_PASSWORD"),
            "database.connections.mongodb.driver": ConfigSetting(value: .text("mongodb")),
            "database.connections.mongodb.dsn": setting(.text(dsn), "MONGODB_URI"),
            "database.connections.mongodb.database": setting(.text(database), "MONGODB_DATABASE"),
        ]
    }

    private func configuration(_ settings: [String: ConfigSetting]) -> LaravelConfiguration {
        LaravelConfiguration(version: "12.0.0", settings: settings, databaseConnections: ["mysql", "mongodb"], redisConnections: [])
    }

    private func plan(_ settings: [String: ConfigSetting], env: String = "MONGODB_URI=mongodb://localhost:27018\n", servers: [UseNexusPlan.Server] = [mysql84, mongodb80]) -> UseNexusPlan {
        let input = UseNexusPlan.Input(envText: env, hosts: ["shop.test"], url: "https://shop.test", httpsPort: 443, databaseServers: servers, redisServers: [])
        return UseNexusPlan(configuration: configuration(settings), input: input)
    }

    @Test(arguments: [
        ("mongodb://127.0.0.1:27017/shop", "127.0.0.1", 27017, "shop"),
        ("mongodb://ann:secret@localhost/logs?authSource=admin", "localhost", 27017, "logs"),
        ("mongodb://[::1]:27018", "[::1]", 27018, ""),
    ])
    func aURLWithOneServerGivesItsHostPortAndDatabase(_ value: String, host: String, port: Int, database: String) throws {
        let url = try #require(MongoDBURL(value))

        #expect(url.host == host)
        #expect(url.port == port)
        #expect(url.database == database)
    }

    @Test(arguments: ["mongodb+srv://ann@cluster0.example.net/shop", "mongodb://a:27017,b:27017/shop?replicaSet=rs0", "mysql://127.0.0.1/shop", ""])
    func aURLWithoutOneServerOnThisMacGivesNoURL(_ value: String) {
        #expect(MongoDBURL(value) == nil)
    }

    @Test func theFirstServerOfAURLLeavesOutTheUserAndThePassword() {
        #expect(MongoDBURL.firstServer("mongodb+srv://ann:secret@cluster0.example.net/shop") == "cluster0.example.net")
        #expect(MongoDBURL.firstServer("mongodb://ann:secret@a:27017,b:27017/shop") == "a:27017")
    }

    @Test func aConnectionWithHostAndPortReadsThePortFromTheHost() throws {
        let settings = [
            "database.connections.mongodb.driver": ConfigSetting(value: .text("mongodb")),
            "database.connections.mongodb.host": setting(.text("127.0.0.1:27019"), "MONGODB_HOST"),
            "database.connections.mongodb.database": setting(.text("shop"), "MONGODB_DATABASE"),
        ]

        let connection = try #require(LaravelMongoDBConnection(path: "database.connections.mongodb", settings: settings))

        #expect(connection.host == "127.0.0.1")
        #expect(connection.port == 27019)
        #expect(connection.database == "shop")
    }

    @Test func theDatabaseOfTheURLCountsWhenTheConnectionNamesNone() throws {
        let connection = try #require(LaravelMongoDBConnection(path: "database.connections.mongodb", settings: settings(dsn: "mongodb://127.0.0.1:27017/crm", database: "")))

        #expect(connection.database == "crm")
        #expect(connection.port == 27017)
    }

    @Test func aMongoDBConnectionOfNexusShowsNextToTheDefaultConnection() {
        let instances = [
            SiteDatabases.Instance(id: "mysql-8.4", kind: .mysql, port: 13306),
            SiteDatabases.Instance(id: "mongodb-8.0", kind: .mongodb, port: 27017),
        ]

        let databases = SiteDatabases.list(configuration(settings(dsn: "mongodb://127.0.0.1:27017")), instances: instances)

        #expect(databases.map(\.connection) == ["mysql", "mongodb"])
        #expect(databases.map(\.instance) == ["mysql-8.4", "mongodb-8.0"])
        #expect(databases.last?.database == "shop")
    }

    @Test func aMongoDBInDockerGetsTheURLOfNexusAndTheCopyOfItsDatabase() throws {
        let plan = plan(settings())
        let database = try #require(plan.database)

        #expect(database.connection == "mongodb")
        #expect(database.name == "shop")
        #expect(database.source == UseNexusPlan.Source(kind: .mongodb, host: "127.0.0.1", port: 27018, socket: nil, account: DatabaseAccount(user: "", password: "")))
        #expect(database.choices.map(\.server.id) == ["mongodb-8.0"])
        #expect(database.choices.first?.changes == [EnvValueChange(key: "MONGODB_URI", oldValue: "mongodb://localhost:27018", newValue: "mongodb://127.0.0.1:27017")])
    }

    @Test func aMongoDBOfNexusWithAPasswordGetsTheUserInTheURL() {
        let account = DatabaseAccount(user: "root", password: "p@ss")

        #expect(UseNexusPlan.mongoDBURL(port: 27017, account: account, database: "shop") == "mongodb://root:p%40ss@127.0.0.1:27017/shop?authSource=admin")
        #expect(UseNexusPlan.mongoDBURL(port: 27017, account: account, database: "") == "mongodb://root:p%40ss@127.0.0.1:27017/?authSource=admin")
        #expect(UseNexusPlan.mongoDBURL(port: 27017, account: .newInstance, database: "shop") == "mongodb://127.0.0.1:27017/shop")
    }

    @Test(arguments: ["mongodb://127.0.0.1:27017", "mongodb+srv://ann@cluster0.example.net"])
    func aMongoDBOfNexusOrOfAtlasNeedsNoChange(_ dsn: String) {
        #expect(plan(settings(dsn: dsn)).database == nil)
    }

    @Test func withoutAMongoDBOfNexusThePlanHasNoMongoDBPart() {
        #expect(plan(settings(), servers: [Self.mysql84]).database == nil)
    }
}
