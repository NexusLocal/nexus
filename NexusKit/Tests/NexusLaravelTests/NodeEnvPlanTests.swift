import Foundation
import NexusCore
import Testing
@testable import NexusLaravel

struct NodeEnvPlanTests {
    private let request = WorkspaceEnvRequest(
        workspace: "fix",
        mainFolder: "/Sites/shop",
        workspaceFolder: "/w/fix",
        mysqlPorts: [13306],
        postgresqlPorts: [15432],
        redisPorts: [16379]
    )

    private func plan(_ files: [String: String], usesDatabaseClient: Bool = true, usesMongoDB: Bool = false, canUseOnlyMongoDB: Bool = false, ownKeys: [String: String] = [:], mongodbPorts: Set<Int> = []) -> WorkspaceEnvPlan {
        let ordered = NodeEnvFile.names.compactMap { name in files[name].map { NodeEnvFile(name: name, text: $0) } }
        let request = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/Sites/shop", workspaceFolder: "/w/fix", mysqlPorts: [13306], postgresqlPorts: [15432], mongodbPorts: mongodbPorts, redisPorts: [16379], ownKeys: ownKeys)
        return WorkspaceEnvPlan(nodeFiles: ordered, usesDatabaseClient: usesDatabaseClient, usesMongoDB: usesMongoDB, canUseOnlyMongoDB: canUseOnlyMongoDB, request: request)
    }

    @Test func aDatabaseURLOnANexusInstanceGetsTheServerOfTheWorkspace() {
        let plan = plan([".env": "DATABASE_URL=\"postgresql://shop:secret@localhost:15432/shop?schema=public\"\n"])

        #expect(plan.serverURLKeys == ["DATABASE_URL"])
        #expect(plan.serverPorts == [15432])
        #expect(plan.databases == [WorkspaceDatabase(name: "shop", port: 15432, isDefault: true)])
        #expect(plan.database == "shop")
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings.isEmpty)
    }

    @Test func theURLOfTheWorkspaceKeepsTheUserThePasswordAndTheQuery() {
        let url = ConnectionURL.pointing("postgresql://shop:p%40ss@localhost:15432/shop?schema=public", toPort: 20001)

        #expect(url == "postgresql://shop:p%40ss@127.0.0.1:20001/shop?schema=public")
    }

    @Test func aURLWithoutAPortUsesTheStandardPort() {
        let url = ConnectionURL("mysql://root@127.0.0.1/shop")

        #expect(url?.port == 3306)
    }

    @Test func splitKeysOnANexusInstanceGetTheHostAndThePortOfTheWorkspace() {
        let plan = plan([".env": "DB_HOST=localhost\nDB_PORT=13306\nDB_NAME=shop\nDB_SOCKET=/tmp/mysql.sock\nMAIL_HOST=127.0.0.1\nMAIL_PORT=1025\n"])

        #expect(plan.serverPortKeys == [13306: ["DB_PORT"]])
        #expect(plan.keys == ["DB_HOST": "127.0.0.1", "DB_SOCKET": ""])
        #expect(plan.databases == [WorkspaceDatabase(name: "shop", port: 13306, isDefault: true)])
    }

    @Test func theKeysOfLibpqCount() {
        let plan = plan([".env.local": "PGHOST=127.0.0.1\nPGPORT=15432\nPGDATABASE=shop\n"])

        #expect(plan.serverPortKeys == [15432: ["PGPORT"]])
        #expect(plan.keys.isEmpty)
        #expect(plan.database == "shop")
    }

    @Test func aRedisURLGetsAnIndexOfItsOwn() {
        let plan = plan([".env": "REDIS_URL=redis://127.0.0.1:16379/2\n"])

        #expect(plan.redisKeys == ["REDIS_URL"])
        #expect(plan.redisURLKeys == ["REDIS_URL"])
        #expect(plan.redisPorts == [16379])
        #expect(plan.mainRedisIndexes == [2])
        #expect(ConnectionURL.withRedisIndex("redis://:secret@127.0.0.1:16379/2", 17) == "redis://:secret@127.0.0.1:16379/17")
    }

    @Test func aRedisHostWithoutAnIndexKeyIsNotIsolated() {
        let plan = plan([".env": "REDIS_HOST=127.0.0.1\nREDIS_PORT=16379\n"])

        #expect(plan.problems == ["REDIS_HOST names a Nexus Redis instance, but no key holds the index, so this workspace would use the index of the main site. Add REDIS_DB, or use a URL with the index."])
    }

    @Test func aServerOnAnotherComputerGivesAWarning() {
        let plan = plan([".env": "DATABASE_URL=postgresql://shop@db.example.com:5432/shop\n"])

        #expect(plan.serverPorts.isEmpty)
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == ["DATABASE_URL names a server on another computer, so this workspace shares that server with the main site."])
    }

    @Test func aLocalServerThatIsNoNexusInstanceGivesAWarning() {
        let plan = plan([".env": "DATABASE_URL=mysql://root:root@localhost:8889/shop\n"])

        #expect(plan.warnings == ["DATABASE_URL names port 8889, and no Nexus instance of that kind has that port. So this workspace shares that server with the main site."])
    }

    @Test func anAppWithAClientAndNoKeyGivesAWarning() {
        let withClient = plan([".env": "NEXT_PUBLIC_NAME=Shop\n"])
        let withoutClient = plan([".env": "NEXT_PUBLIC_NAME=Shop\n"], usesDatabaseClient: false)

        #expect(withClient.warnings.count == 1)
        #expect(withoutClient.warnings.isEmpty)
    }

    @Test(arguments: [
        ("mongodb://localhost:27017/shop", "DATABASE_URL names port 27017, and no Nexus instance of that kind has that port. So this workspace shares that server with the main site."),
        ("MongoDB://localhost:27017/shop", "DATABASE_URL names port 27017, and no Nexus instance of that kind has that port. So this workspace shares that server with the main site."),
        ("mongodb+srv://shop:secret@cluster.example.net/shop", "DATABASE_URL gets its MongoDB servers from DNS (mongodb+srv), for example from MongoDB Atlas. So this workspace shares that server with the main site."),
        ("mongodb://db1.example.com:27017,db2.example.com:27017/shop?replicaSet=rs0", "DATABASE_URL names a server on another computer, so this workspace shares that server with the main site."),
    ])
    func aMongoDBURLWithoutANexusMongoDBGivesAWarning(url: String, warning: String) {
        let plan = plan([".env": "DATABASE_URL=\(url)\n", ".env.local": "DATABASE_URL=\(url)\n"], canUseOnlyMongoDB: true)

        #expect(plan.serverURLKeys.isEmpty)
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == [warning])
    }

    @Test func aMongoDBURLOnANexusMongoDBGetsTheServerOfTheWorkspace() {
        let plan = plan([".env": "MONGODB_URI=\"mongodb://shop:secret@localhost:27017/shop?replicaSet=nexus\"\n"], usesMongoDB: true, canUseOnlyMongoDB: true, mongodbPorts: [27017])

        #expect(plan.serverURLKeys == ["MONGODB_URI"])
        #expect(plan.serverPorts == [27017])
        #expect(plan.databases == [WorkspaceDatabase(name: "shop", port: 27017, isDefault: true)])
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings.isEmpty)
        #expect(ConnectionURL.pointing("mongodb://shop:secret@localhost:27017/shop?replicaSet=nexus", toPort: 20001) == "mongodb://shop:secret@127.0.0.1:20001/shop?replicaSet=nexus")
    }

    @Test func aKeyWithAnAtlasURLInAnotherFileGivesItsWarning() {
        let plan = plan([".env": "MONGODB_URI=mongodb://localhost:27017/shop\n", ".env.local": "MONGODB_URI=mongodb+srv://cluster.example.net/shop\n"], usesMongoDB: true, canUseOnlyMongoDB: true, mongodbPorts: [27017])

        #expect(plan.serverURLKeys == ["MONGODB_URI"])
        #expect(plan.warnings == ["MONGODB_URI gets its MongoDB servers from DNS (mongodb+srv), for example from MongoDB Atlas. So this workspace shares that server with the main site."])
    }

    @Test func aMongoDBURLWithLocalServersIsNotIsolated() {
        let plan = plan([".env": "MONGODB_URI=mongodb://127.0.0.1:27017,127.0.0.1:27018/shop?replicaSet=rs0\n"], usesMongoDB: true, canUseOnlyMongoDB: true, mongodbPorts: [27017])

        #expect(plan.serverURLKeys.isEmpty)
        #expect(plan.problems == ["MONGODB_URI names more than one MongoDB server, so Nexus cannot change that URL."])
    }

    @Test func aMongoDBHostAndPortOnANexusMongoDBGetThePortOfTheWorkspace() {
        let plan = plan([".env": "MONGODB_HOST=localhost\nMONGODB_PORT=27017\nMONGODB_DATABASE=shop\n"], usesMongoDB: true, canUseOnlyMongoDB: true, mongodbPorts: [27017])

        #expect(plan.serverPortKeys == [27017: ["MONGODB_PORT"]])
        #expect(plan.keys == ["MONGODB_HOST": "127.0.0.1"])
        #expect(plan.databases == [WorkspaceDatabase(name: "shop", port: 27017, isDefault: true)])
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings.isEmpty)
    }

    @Test func aMongoDBHostWithoutAPortOnTheStandardPortIsNotIsolated() {
        let plan = plan([".env": "MONGODB_HOST=127.0.0.1\n"], usesMongoDB: true, canUseOnlyMongoDB: true, mongodbPorts: [27017])

        #expect(plan.problems == ["MONGODB_HOST names a Nexus instance without MONGODB_PORT, so Nexus cannot give this workspace its own server."])
    }

    @Test func aMongoDBURLDoesNotHideTheWarningOfAnotherDatabase() {
        let plan = plan([".env": "MONGODB_URI=mongodb://localhost/logs\n"], usesMongoDB: true)

        #expect(plan.warnings == [
            "Nexus found no database key in the env files of the app. When the app reaches a Nexus database in another way, this workspace uses the database of the main site.",
            "MONGODB_URI names port 27017, and no Nexus instance of that kind has that port. So this workspace shares that server with the main site.",
        ])
    }

    @Test func aNexusMongoDBDoesNotHideTheWarningOfAnotherDatabase() {
        let plan = plan([".env": "MONGODB_URI=mongodb://localhost/logs\n"], usesMongoDB: true, mongodbPorts: [27017])

        #expect(plan.serverURLKeys == ["MONGODB_URI"])
        #expect(plan.warnings == ["Nexus found no database key in the env files of the app. When the app reaches a Nexus database in another way, this workspace uses the database of the main site."])
    }

    @Test func anORMOnMongoDBGivesNoWarningOfAnotherDatabase() {
        let plan = plan([".env": "NEXT_PUBLIC_NAME=Shop\n"], usesMongoDB: true, canUseOnlyMongoDB: true)

        #expect(plan.warnings == ["The app uses MongoDB. Nexus found no MongoDB URL in its env files. So this workspace can share the MongoDB database with the main site."])
    }

    @Test func aWorkspaceKeyWithAnotherMongoDBServerGivesNoWarning() {
        let files = [".env": "MONGODB_URI=mongodb://localhost/shop\n"]
        let own = plan(files, usesMongoDB: true, canUseOnlyMongoDB: true, ownKeys: ["MONGODB_URI": "mongodb://localhost/shop_{workspace}"])
        let same = plan(files, usesMongoDB: true, canUseOnlyMongoDB: true, ownKeys: ["MONGODB_URI": "mongodb://localhost/shop"])
        let withoutURL = plan([:], usesMongoDB: true, canUseOnlyMongoDB: true, ownKeys: ["MONGO_DB": "shop_{workspace}"])

        #expect(own.warnings.isEmpty)
        #expect(same.warnings.count == 1)
        #expect(withoutURL.warnings.isEmpty)
    }

    @Test func aMongoDBURLNextToANexusServerGivesAWarning() {
        let plan = plan([".env": "DATABASE_URL=postgresql://shop@localhost:15432/shop\nMONGODB_URI=mongodb://localhost:27017/logs\n"])

        #expect(plan.serverURLKeys == ["DATABASE_URL"])
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == ["MONGODB_URI names port 27017, and no Nexus instance of that kind has that port. So this workspace shares that server with the main site."])
    }

    @Test func anAppWithAMongoDBClientAndNoURLGivesAWarning() {
        let plan = plan([".env": "DATABASE_URL=postgresql://shop@localhost:15432/shop\nMONGO_HOST=127.0.0.1\nMONGO_PORT=27017\n"], usesMongoDB: true)

        #expect(plan.serverURLKeys == ["DATABASE_URL"])
        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == ["The app uses MongoDB. Nexus found no MongoDB URL in its env files. So this workspace can share the MongoDB database with the main site."])
    }

    @Test func aURLThatFollowsThePortKeyIsIsolated() {
        let plan = plan([".env": "DB_HOST=127.0.0.1\nDB_PORT=15432\nDATABASE_URL=postgresql://shop@${DB_HOST}:${DB_PORT}/shop\n"])

        #expect(plan.problems.isEmpty)
        #expect(plan.serverURLKeys.isEmpty)
        #expect(plan.serverPortKeys == [15432: ["DB_PORT"]])
    }

    @Test func aURLWithAFixedPortAndVariablesIsNotIsolated() {
        let plan = plan([".env": "DB_USER=shop\nDATABASE_URL=postgresql://${DB_USER}@127.0.0.1:15432/shop\n"])

        #expect(plan.problems == ["DATABASE_URL builds its URL from other keys, so Nexus cannot change it."])
    }

    @Test func aSocketInTheURLIsNotIsolated() {
        let plan = plan([".env": "DATABASE_URL=postgresql://shop@localhost:15432/shop?host=/tmp\n"])

        #expect(plan.problems == ["DATABASE_URL names a socket in its URL, and a socket ignores the port."])
    }

    @Test func aHostWithoutAPortOnTheStandardPortIsNotIsolated() {
        let standard = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/Sites/shop", workspaceFolder: "/w/fix", mysqlPorts: [3306], postgresqlPorts: [], redisPorts: [])

        let plan = WorkspaceEnvPlan(nodeFiles: [NodeEnvFile(name: ".env", text: "MYSQL_HOST=localhost\n")], usesDatabaseClient: true, request: standard)

        #expect(plan.problems == ["MYSQL_HOST names a Nexus instance without MYSQL_PORT, so Nexus cannot give this workspace its own server."])
    }

    @Test func aDatabaseHostWithoutAPortOnTheStandardPortOfANexusInstanceIsNotIsolated() {
        let standard = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/Sites/shop", workspaceFolder: "/w/fix", mysqlPorts: [3306], postgresqlPorts: [], redisPorts: [])

        let plan = WorkspaceEnvPlan(nodeFiles: [NodeEnvFile(name: ".env", text: "DB_HOST=127.0.0.1\nAPP_HOST=localhost\n")], usesDatabaseClient: true, request: standard)

        #expect(plan.problems == ["DB_HOST names a Nexus instance without DB_PORT, so Nexus cannot give this workspace its own server."])
    }

    @Test func aDatabaseHostWithoutAPortAndNoNexusInstanceOnTheStandardPortGivesAWarning() {
        let plan = plan([".env": "DB_HOST=127.0.0.1\nAPP_HOST=localhost\n"])

        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == ["DB_HOST names a local server without DB_PORT, and no Nexus instance has the standard port. So this workspace shares that server with the main site."])
    }

    @Test func aHostWithThePortOfANexusInstanceInItIsNotIsolated() {
        let plan = plan([".env": "DB_HOST=127.0.0.1:13306\n"])

        #expect(plan.problems == ["DB_HOST has the port of a Nexus instance in it, so Nexus cannot change it. Use DB_PORT for the port."])
    }

    @Test func aHostSplitsIntoTheHostAndItsPort() {
        #expect(WorkspaceEnvPlan.split(host: "127.0.0.1:13306") == ("127.0.0.1", 13306))
        #expect(WorkspaceEnvPlan.split(host: "[::1]:13306") == ("[::1]", 13306))
        #expect(WorkspaceEnvPlan.split(host: "::1") == ("::1", nil))
        #expect(WorkspaceEnvPlan.split(host: "localhost") == ("localhost", nil))
    }

    @Test func aKeyInTwoFilesCountsOnce() {
        let plan = plan([
            ".env": "DATABASE_URL=postgresql://shop@localhost:15432/shop\n",
            ".env.local": "DATABASE_URL=postgresql://shop@127.0.0.1:15432/shop\n",
        ])

        #expect(plan.databases.count == 1)
        #expect(plan.serverURLKeys == ["DATABASE_URL"])
    }

    @Test func aMySQLURLOnAPostgreSQLPortGivesAWarning() {
        let plan = plan([".env": "DATABASE_URL=mysql://root@127.0.0.1:15432/shop\n"])

        #expect(plan.serverPorts.isEmpty)
        #expect(plan.warnings.count == 1)
    }
}
