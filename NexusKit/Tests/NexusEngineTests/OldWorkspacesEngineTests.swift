import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import NexusWorkspaces
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private static let day: TimeInterval = 86_400

    private func repositoryWithReadme(in root: URL) async throws -> URL {
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try Data("shop\n".utf8).write(to: shop.appending(path: "readme.txt"))
        try await git("init", "-q", "-b", "main", in: shop)
        try await git("add", "readme.txt", in: shop)
        try await git("commit", "-q", "-m", "first", in: shop)
        return shop
    }

    private func worktreeEngine(root: URL, shop: URL) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        return engine
    }

    private func addWorktree(_ name: String, to shop: URL, in root: URL) async throws -> URL {
        let worktree = root.appending(path: name, directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", name, worktree.path(percentEncoded: false), in: shop)
        return worktree
    }

    private func shownActivity(_ engine: NexusEngine) async -> Date? {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return nil
        }

        return sites.flatMap { $0.workspaces ?? [] }.first?.lastActivity
    }

    private func writePage(_ text: String, for host: String, at date: Date, in engine: NexusEngine) async throws {
        let log = await engine.paths.siteLog(host)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: log.path(percentEncoded: false))
    }

    @Test func aNewWorkspaceHasALastActivityInTheSiteList() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)

        let activity = try #require(await shownActivity(engine))
        #expect(abs(activity.timeIntervalSinceNow) < 120)
        #expect(activity == NexusEngine.wholeMinute(of: activity))
    }

    @Test func aPageIsTheLastActivity() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let minute = try #require(NexusEngine.wholeMinute(of: Date.now.addingTimeInterval(3600)))
        let page = minute.addingTimeInterval(30)

        try await writePage("GET / 200\n", for: "shop-fix.test", at: page, in: engine)
        let shown = try #require(await shownActivity(engine))
        let list = try await engine.oldWorkspaces(host: "shop.test", days: 1, now: page.addingTimeInterval(2 * Self.day))

        #expect(shown == minute)
        #expect(list.workspaces.map(\.name) == ["fix"])
        #expect(list.workspaces.first?.activity.source == .page)
        #expect(abs((list.workspaces.first?.activity.date ?? .distantPast).timeIntervalSince(page)) < 1)
    }

    @Test func anEmptyAccessLogIsNoActivity() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let before = await shownActivity(engine)

        try await writePage("", for: "shop-fix.test", at: Date.now.addingTimeInterval(3600), in: engine)

        #expect(before != nil)
        #expect(await shownActivity(engine) == before)
    }

    @Test func aWorkspaceWithoutActivityForTheDaysIsOld() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let later = Date.now.addingTimeInterval(6 * Self.day)

        let old = try await engine.oldWorkspaces(host: "shop.test", days: nil, now: later)
        let notOld = try await engine.oldWorkspaces(host: "shop.test", days: 7, now: later)
        let soon = try await engine.oldWorkspaces(host: "shop.test", days: nil, now: .now)

        #expect(old.days == 5)
        #expect(old.dumpDays == 7)
        #expect(old.workspaces.map(\.name) == ["fix"])
        #expect(old.workspaces.first?.activity.source == .created)
        #expect(old.workspaces.first?.canGo == true)
        #expect(notOld.days == 7)
        #expect(notOld.workspaces.isEmpty)
        #expect(soon.workspaces.isEmpty)
    }

    @Test func theSignsOfGitShowInTheList() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try await git("init", "-q", "--bare", "-b", "main", in: origin)
        try await git("remote", "add", "origin", origin.path(percentEncoded: false), in: shop)
        try await git("push", "-q", "-u", "origin", "main", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)

        _ = try await addWorktree("gone", to: shop, in: root)
        try await git("push", "-q", "-u", "origin", "gone", in: shop)
        try await git("branch", "-D", "gone", in: origin)
        try await git("fetch", "-q", "--prune", in: shop)
        let ahead = try await addWorktree("ahead", to: shop, in: root)
        try await git("push", "-q", "-u", "origin", "ahead", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "one", in: ahead)
        try await git("commit", "-q", "--allow-empty", "-m", "two", in: ahead)
        try Data("new\n".utf8).write(to: ahead.appending(path: "notes.txt"))
        let locked = try await addWorktree("locked", to: shop, in: root)
        try await git("worktree", "lock", "--reason", "claude agent-a1b2", locked.path(percentEncoded: false), in: shop)
        let removed = try await addWorktree("removed", to: shop, in: root)
        try await settle(engine)
        try FileManager.default.removeItem(at: removed)

        let list = try await engine.oldWorkspaces(host: "shop.test", days: nil, now: Date.now.addingTimeInterval(10 * Self.day))
        let rows = Dictionary(uniqueKeysWithValues: list.workspaces.map { ($0.name, $0) })

        #expect(list.mainBranch == "main")
        #expect(Set(rows.keys) == ["gone", "ahead", "locked", "removed"])
        #expect(rows["gone"]?.branchGone == true)
        #expect(rows["gone"]?.merged == true)
        #expect(rows["gone"]?.canGo == true)
        #expect(rows["ahead"]?.commitsNotPushed == 2)
        #expect(rows["ahead"]?.merged == false)
        #expect(rows["ahead"]?.branchGone == false)
        #expect(rows["ahead"]?.changesNotCommitted == 1)
        #expect(rows["ahead"]?.canGo == false)
        #expect(rows["locked"]?.locked == "claude agent-a1b2")
        #expect(rows["locked"]?.canGo == false)
        #expect(rows["removed"]?.folderGone == true)
        #expect(rows["removed"]?.changesNotCommitted == 0)
        #expect(rows["removed"]?.canGo == true)
        #expect(list.workspaces.map(\.activity.date) == list.workspaces.map(\.activity.date).sorted())
    }

    @Test func aWorkspaceWithoutItsFolderKeepsItsGitTimes() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let before = await shownActivity(engine)

        try FileManager.default.removeItem(at: worktree)

        #expect(before != nil)
        #expect(await shownActivity(engine) == before)
    }

    @Test func theListOfOldWorkspacesDoesNotChangeTheirActivity() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let lastChange = try moveTheGitTimesBack(of: worktree)
        let before = try #require(await shownActivity(engine))

        let list = try await engine.oldWorkspaces(host: "shop.test", days: nil, now: Date.now.addingTimeInterval(10 * Self.day))

        #expect(before == NexusEngine.wholeMinute(of: lastChange))
        #expect(list.workspaces.map(\.changesNotCommitted) == [0])
        #expect(list.workspaces.map(\.activity.source) == [.commit])
        #expect(await shownActivity(engine) == before)
    }

    @Test func aRemovalThatGitRefusesKeepsTheLastActivity() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        try Data("new\n".utf8).write(to: worktree.appending(path: "notes.txt"))
        _ = try moveTheGitTimesBack(of: worktree)
        let before = try #require(await shownActivity(engine))

        let answer = await engine.handle(.removeWorkspaces(host: "shop.test", names: ["fix"]))

        #expect(answer == .workspaceRemovals(WorkspaceRemovals(removed: [], kept: [KeptWorkspace(name: "fix", reason: WorkspaceRemovalText.changes("fix"))], warnings: [])))
        #expect(await shownActivity(engine) == before)
    }

    private func moveTheGitTimesBack(of worktree: URL) throws -> Date {
        let admin = try #require(ProjectFolder.adminFolder(ofWorktree: worktree.path(percentEncoded: false)))
        let created = Date.now.addingTimeInterval(-3 * 3600)
        let lastChange = created.addingTimeInterval(3600)

        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: (admin as NSString).appendingPathComponent("commondir"))

        for file in ["index", "logs/HEAD"] {
            try FileManager.default.setAttributes([.modificationDate: lastChange], ofItemAtPath: (admin as NSString).appendingPathComponent(file))
        }

        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: worktree.appending(path: "readme.txt").path(percentEncoded: false))
        return lastChange
    }

    @Test func aNoticeComesOnceUntilNotifyAgain() async throws {
        let root = shortTemporaryRoot()
        let otherRoot = shortTemporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let later = Date.now.addingTimeInterval(6 * Self.day)

        let first = try await engine.dueOldWorkspaceNotices(now: later)
        let again = try await engine.dueOldWorkspaceNotices(now: later)
        var state = await engine.stateStore.current()
        state.ports[NexusEngine.dnsServiceID] = nil
        let restarted = try makeSiteEngine(root: otherRoot, state: state)
        let afterRestart = try await restarted.dueOldWorkspaceNotices(now: later)
        let nextDay = try await restarted.dueOldWorkspaceNotices(now: later.addingTimeInterval(Self.day))

        #expect(first == [OldWorkspacesNotice(host: "shop.test", names: ["fix"], days: 5)])
        #expect(again.isEmpty)
        #expect(afterRestart.isEmpty)
        #expect(nextDay == first)
    }

    @Test func notifyAgainEachWeekWaitsAWeek() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let later = Date.now.addingTimeInterval(6 * Self.day)

        #expect(await engine.handle(.setWorkspaceSettings(WorkspaceSettings(notifyOldEvery: 7))) == .done(message: "The settings of the workspaces are changed."))
        let first = try await engine.dueOldWorkspaceNotices(now: later)
        let nextDay = try await engine.dueOldWorkspaceNotices(now: later.addingTimeInterval(Self.day))
        let nextWeek = try await engine.dueOldWorkspaceNotices(now: later.addingTimeInterval(7 * Self.day))

        #expect(first.map(\.names) == [["fix"]])
        #expect(nextDay.isEmpty)
        #expect(nextWeek.map(\.names) == [["fix"]])
    }

    @Test func aSiteWithoutOldWorkspacesLosesItsRecord() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        _ = try await addWorktree("fix", to: shop, in: root)
        try await settle(engine)
        let later = Date.now.addingTimeInterval(6 * Self.day)

        let first = try await engine.dueOldWorkspaceNotices(now: later)
        let recorded = await engine.stateStore.current().oldWorkspaceNotices
        #expect(await engine.handle(.setWorkspaceSettings(WorkspaceSettings(oldAfterDays: 30))) == .done(message: "The settings of the workspaces are changed."))
        let afterChange = try await engine.dueOldWorkspaceNotices(now: later.addingTimeInterval(Self.day))

        #expect(first.count == 1)
        #expect(recorded.count == 1)
        #expect(afterChange.isEmpty)
        #expect(await engine.stateStore.current().oldWorkspaceNotices.isEmpty)
    }

    @Test func theOldWorkspacesOfAnUnknownSiteOrOfZeroDaysAreRefused() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        #expect(await engine.handle(.oldWorkspaces(host: "shop.test", days: 0)) == .failure(message: "A workspace is old after at least 1 day."))
        #expect(await engine.handle(.oldWorkspaces(host: "nope.test")) == .failure(message: "Nexus has no site nope.test."))
        #expect(await engine.handle(.oldWorkspaces(host: "shop.test")) == .oldWorkspaces(OldWorkspaceList(host: "shop.test", days: 5, dumpDays: 7, mainBranch: nil, workspaces: [])))
    }

    @Test func theSiteListNamesTheLimitOfOldWorkspaces() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repositoryWithReadme(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        let before = await engine.siteList().oldAfterDays
        _ = await engine.handle(.setWorkspaceSettings(WorkspaceSettings(oldAfterDays: 14)))
        let after = await engine.siteList().oldAfterDays

        #expect(before == 5)
        #expect(after == 14)
    }
}
