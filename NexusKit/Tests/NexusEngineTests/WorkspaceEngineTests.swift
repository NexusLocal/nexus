import Foundation
import NexusCore
import NexusIPC
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func workspaceRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func git(_ arguments: String..., in folder: URL) async throws {
        _ = try await CommandRunner.run(Command(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Nexus", "-c", "user.email=nexus@example.test", "-C", folder.path(percentEncoded: false)] + arguments
        ))
    }

    private func repository(in root: URL) async throws -> URL {
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        return shop
    }

    private func settle(_ engine: NexusEngine) async throws {
        await engine.reconcileWorkspaces()

        while await engine.reconcilingWorkspaces {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func workspaces(_ engine: NexusEngine) async -> [Workspace] {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return []
        }

        return sites.flatMap { $0.workspaces ?? [] }
    }

    private func worktreeEngine(root: URL, shop: URL, automatic: Bool? = nil) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", automaticWorkspaces: automatic)]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        return engine
    }

    @Test func gitWorktreeAddGivesAWorkspaceAndGitWorktreeRemoveEndsIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "TICKET-123", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "ticket", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let path = RealPath.of(worktree)
        #expect(await workspaces(engine) == [Workspace(name: "ticket-123", worktree: path, folder: path, branch: "ticket")])

        try await git("worktree", "remove", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aWorktreeThatStaysLockedAfterItsCheckoutGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "claude-test").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "-b", "worktree-claude-test", worktree, in: shop)
        try await git("worktree", "lock", "--reason", "claude agent", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["claude-test"])
    }

    @Test func aLockedWorktreeWithoutACheckoutWaits() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix").path(percentEncoded: false)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree, in: shop)
        try await git("worktree", "lock", worktree, in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aWorktreeThatWasThereBeforeTheSiteGetsNoWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try await git("worktree", "add", "-q", "-b", "old", root.appending(path: "old").path(percentEncoded: false), in: shop)

        let engine = try await worktreeEngine(root: root, shop: shop)

        #expect(await workspaces(engine).isEmpty)
    }

    @Test func aFolderThatGitNoLongerReadsKeepsItsWorkspaces() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let head = shop.appending(path: ".git/HEAD")
        let stored = try Data(contentsOf: head)
        try FileManager.default.removeItem(at: head)

        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        try stored.write(to: head)
    }

    @Test func theSettingOfASiteChangesWithAnEditWithoutANewWebConfiguration() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(automaticWorkspaces: false)))
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        guard case .done = response else {
            Issue.record("No change: \(response)")
            return
        }

        guard case .sites(let sites) = await engine.handle(.sites) else {
            Issue.record("No sites")
            return
        }

        #expect(sites.first?.automaticWorkspaces == false)
        #expect(sites.first?.workspaces == [])
    }

    @Test func aRemovedSiteTakesItsWorkspaceRecordWithIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore

        try await store.update { $0.sites = [] }
        try await settle(engine)

        #expect(await store.current().worktrees.isEmpty)
    }

    @Test func aRemovedSiteTakesItsRecordAlsoWhenAnotherSiteIsInItsFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let backend = shop.appending(path: "backend", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, php: "8.4"),
            Site(host: "backend.test", folder: backend, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        let store = await engine.stateStore

        try await store.update { $0.sites.removeAll { $0.host == "shop.test" } }
        try await settle(engine)

        #expect(await store.current().worktrees.keys.sorted() == [RealPath.of(backend)])
    }

    @Test func theMessageOfTheSettingCountsTheOtherSiteOfTheProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.4"),
            Site(host: "b.test", folder: publicFolder, php: "8.4"),
        ]
        let engine = try makeSiteEngine(root: root, state: state)

        let response = await engine.handle(.editSite(host: "b.test", change: SiteChange(automaticWorkspaces: false)))

        guard case .done(let message) = response else {
            Issue.record("No change: \(response)")
            return
        }

        #expect(message.contains("A new worktree gets a workspace."))
    }

    @Test func aSiteOnAPublicFolderKeepsItsWorkspacesWhileComposerJSONIsGone() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        let composerFile = shop.appending(path: "composer.json")
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: composerFile)
        let engine = try await worktreeEngine(root: root, shop: publicFolder)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)
        let store = await engine.stateStore

        try FileManager.default.removeItem(at: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix")) + "/public"])

        try Data("{}".utf8).write(to: composerFile)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.folder) == [RealPath.of(root.appending(path: "fix"))])
        #expect(await store.current().worktrees.count == 1)
    }

    @Test func aWorktreeAfterALaterGitInitGetsAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)

        try await git("init", "-q", "-b", "main", in: shop)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfASiteFindsAGitInitWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("init", "-q", "-b", "main", in: shop)

        while await engine.watchedRepositories.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("commit", "-q", "--allow-empty", "-m", "first", in: shop)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aFolderThatDoesNotExistKeepsItsWorkspaceRecord() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let store = await engine.stateStore
        let record = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/nexus/no/such/fix", folder: "/nexus/no/such/fix")])

        try await store.update { $0.worktrees["/nexus/no/such/shop"] = record }
        try await settle(engine)

        #expect(await store.current().worktrees["/nexus/no/such/shop"] == record)
    }

    @Test(arguments: [("a.test", "b.test"), ("b.test", "a.test")])
    func twoSitesOfOneProjectGiveAWorkspaceWhenOneHasTheSettingOn(on: String, off: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shop.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [
            Site(host: on, folder: shop, php: "8.4", automaticWorkspaces: true),
            Site(host: off, folder: publicFolder, php: "8.4", automaticWorkspaces: false),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix", "fix"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatchOfTheGitFolderFindsANewWorktreeWithoutARequest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(await workspaces(engine).map(\.name) == ["fix"])

        let moved = root.appending(path: "other/fix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git("worktree", "move", root.appending(path: "fix").path(percentEncoded: false), moved.path(percentEncoded: false), in: shop)

        while await workspaces(engine).first?.worktree != RealPath.of(moved) {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", moved.path(percentEncoded: false), "switch", "-q", "-c", "second", in: shop)

        while await workspaces(engine).first?.branch != "second" {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("worktree", "remove", moved.path(percentEncoded: false), in: shop)

        while await !workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
