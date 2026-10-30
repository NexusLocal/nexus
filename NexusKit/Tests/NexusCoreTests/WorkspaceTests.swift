import Foundation
import Testing
@testable import NexusCore

struct WorkspaceTests {
    @Test(arguments: [
        ("TICKET-123", "ticket-123"),
        ("feature_new login", "feature-new-login"),
        ("v1.2", "v1-2"),
        ("één", "n"),
        ("b\u{301}x", "x"),
        ("fix_", "fix"),
        ("_private", "private"),
        ("1\u{20E3}", "workspace"),
    ])
    func aFolderNameGivesTheWorkspaceName(folder: String, name: String) {
        #expect(Workspace.name(forFolder: folder, taken: []) == name)
    }

    @Test func aLongFolderNameFitsInAHost() {
        let name = Workspace.name(forFolder: String(repeating: "a", count: 39) + "_b" + String(repeating: "c", count: 30), taken: [])

        #expect(name == String(repeating: "a", count: 39))
    }

    @Test(arguments: [
        ("my.shop.test", "my.shop-ticket-123.test"),
        ("shop.test", "shop-ticket-123.test"),
        ("blog.local", "blog-ticket-123.test"),
        ("my.roodfruit.local", "my.roodfruit-ticket-123.test"),
        ("x.home.arpa", "x-ticket-123.test"),
    ])
    func aHostGetsTheWorkspaceNameBeforeTheTLD(host: String, expected: String) throws {
        let result = HostName.workspaceHost(host, workspace: "ticket-123", tld: "test")

        #expect(result == expected)
        #expect(try HostName.validated(result) == expected)
    }

    @Test func aHostUsesTheCurrentDevTLD() {
        #expect(HostName.workspaceHost("shop.internal", workspace: "fix", tld: "internal") == "shop-fix.internal")
        #expect(HostName.workspaceHost("shop.test", workspace: "fix", tld: "internal") == "shop-fix.internal")
    }

    @Test func aHostOutsideThePrivateNamesKeepsAllItsLetters() {
        #expect(HostName.workspaceHost("shop.com", workspace: "fix", tld: "test") == "shop.com-fix.test")
    }

    @Test func aLongLabelGivesWayToTheWorkspaceName() throws {
        let label = String(repeating: "a", count: 60)
        let workspace = String(repeating: "b", count: 40)

        let result = HostName.workspaceHost("\(label).test", workspace: workspace, tld: "test")

        #expect(try HostName.validated(result) == result)
        #expect(result.hasSuffix("-\(workspace).test"))
    }

    @Test func eachHostOfASiteGetsAWorkspaceHostOnce() {
        let site = Site(host: "shop.test", folder: URL(filePath: "/shop"), aliases: ["shop.local", "www.shop.test"], php: "8.4")
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")

        #expect(workspace.hosts(of: [site], tld: "test") == ["shop-fix.test", "www.shop-fix.test"])
    }

    @Test func aDatabaseNameHasNoHyphen() {
        #expect(Workspace.databaseName("shop", workspace: "ticket-123") == "shop_ticket_123")
    }

    @Test func aLongDatabaseNameGivesWayToTheWorkspaceName() {
        let name = Workspace.databaseName(String(repeating: "a", count: 60), workspace: "fix")

        #expect(name.utf8.count == 63)
        #expect(name.hasSuffix("_fix"))
    }

    @Test func twoLongDatabaseNamesWithTheSameStartStayDifferent() {
        let start = String(repeating: "a", count: 62)

        #expect(Workspace.databaseName("\(start)b", workspace: "fix") != Workspace.databaseName("\(start)c", workspace: "fix"))
    }

    @Test func aLongDatabaseNameWithOtherLettersStaysInsideTheLimitInBytes() {
        #expect(Workspace.databaseName(String(repeating: "é", count: 40), workspace: "fix").utf8.count <= 63)
    }

    @Test func aHostPairCoversTheParentDomainWithALeadingDot() {
        let site = Site(host: "my.shop.test", folder: URL(filePath: "/shop"), aliases: ["blog.local"], php: "8.4")

        let pairs = Workspace.hostPairs(of: [site], workspace: "fix", tld: "test")

        #expect(pairs.map(\.from) == ["my.shop.test", ".shop.test", "blog.local"])
        #expect(pairs.map(\.to) == ["my.shop-fix.test", ".shop-fix.test", "blog-fix.test"])
    }

    @Test func aRecordWithoutAStateNeedsItsSetup() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix"}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(workspace.state == .preparing)
        #expect(workspace.redisIndexes.isEmpty)
        #expect(workspace.redisInstances.isEmpty)
    }

    @Test func aRecordWithRedisIndexesWithoutInstancesNeedsItsSetup() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}},"redisIndexes":{"REDIS_DB":16}}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(workspace.state == .preparing)
        #expect(workspace.redisIndexes == ["REDIS_DB": 16])
    }

    @Test func aRecordWithRedisIndexesAndInstancesKeepsItsState() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}},"redisIndexes":{"REDIS_DB":16},"redisInstances":["redis-8.2"]}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(workspace.state == .ready)
    }

    @Test func aReadyRecordFromBeforeTheCommandsHasNoPendingCommands() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}}}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(workspace.commandsEnded)
    }

    @Test func aReadyRecordThatNeedsItsRedisInstancesHasNoPendingCommands() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"ready":{}},"redisIndexes":{"REDIS_DB":16}}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(workspace.state == .preparing)
        #expect(workspace.commandsEnded)
    }

    @Test func aRecordInItsSetupStillGetsTheCommandsOfItsSite() throws {
        let stored = #"{"name":"fix","worktree":"/w/fix","folder":"/w/fix","state":{"preparing":{}}}"#

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(stored.utf8))

        #expect(!workspace.commandsEnded)
    }

    @Test func eachRedisIndexIsOnEachInstanceOfTheWorkspace() {
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix", redisIndexes: ["REDIS_DB": 16, "REDIS_CACHE_DB": 17], redisInstances: ["redis-8.2", "redis-7.2"])

        #expect(workspace.redisIndexesOnInstances == [
            WorkspaceRedisIndex(instance: "redis-8.2", index: 16),
            WorkspaceRedisIndex(instance: "redis-8.2", index: 17),
            WorkspaceRedisIndex(instance: "redis-7.2", index: 16),
            WorkspaceRedisIndex(instance: "redis-7.2", index: 17),
        ])
    }

    @Test(arguments: ["SCOUT_PORT", "_KEY", "app.name"])
    func anEnvKeyWithAGoodName(key: String) {
        #expect(WorkspaceEnvKey(key: key, value: "").hasValidName)
    }

    @Test(arguments: ["TWO WORDS", "A=B", "1KEY", "A\nB", ""])
    func anEnvKeyWithAWrongName(key: String) {
        #expect(!WorkspaceEnvKey(key: key, value: "").hasValidName)
    }

    @Test func aTakenNameGetsTheFirstFreeNumber() {
        #expect(Workspace.name(forFolder: "fix", taken: ["fix", "fix-2"]) == "fix-3")
    }

    @Test func aSiteWithoutTheSettingCreatesWorkspaces() throws {
        let stored = #"{"host":"shop.test","folder":"file:///shop/","aliases":[],"php":"8.4","server":"nginx"}"#

        let site = try JSONDecoder().decode(Site.self, from: Data(stored.utf8))

        #expect(site.createsWorkspaces)
        #expect(!Site(host: "shop.test", folder: URL(filePath: "/shop"), php: "8.4", automaticWorkspaces: false).createsWorkspaces)
    }
}

struct WorkspaceHostPairTests {
    @Test func aHostInAnotherDevTLDGoesToTheCurrentTLD() {
        let pairs = Workspace.pairsFromOtherTLDs([(from: "shop.test", to: "shop-fix.internal")], tld: "internal")

        #expect(pairs.map(\.from) == ["shop-fix.localhost", "shop-fix.test"])
        #expect(pairs.allSatisfy { $0.to == "shop-fix.internal" })
    }
}
