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

    private func plan(_ files: [String: String], usesDatabaseClient: Bool = true) -> WorkspaceEnvPlan {
        let ordered = NodeEnvFile.names.compactMap { name in files[name].map { NodeEnvFile(name: name, text: $0) } }
        return WorkspaceEnvPlan(nodeFiles: ordered, usesDatabaseClient: usesDatabaseClient, request: request)
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
