import Foundation
import Testing
@testable import NexusCore

struct ProjectFolderTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Projects \(UUID().uuidString)", directoryHint: .isDirectory)

    private func folder(_ path: String) throws -> URL {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to path: String) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // The files that git worktree add makes: a .git file in the worktree and a folder with a
    // commondir file in .git/worktrees of the main checkout.
    private func worktree(of repository: String, at path: String) throws {
        let gitDir = try folder("\(repository)/.git/worktrees/\(URL(filePath: path).lastPathComponent)")
        try write("../..\n", to: "\(repository)/.git/worktrees/\(gitDir.lastPathComponent)/commondir")
        try write("gitdir: \(gitDir.path(percentEncoded: false))\n", to: "\(path)/.git")
    }

    private func site(_ host: String, _ folder: URL) -> Site {
        Site(host: host, folder: folder, php: "8.4")
    }

    @Test func theDeepestSiteHoldsTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop")
        let api = try folder("shop/api")
        let deep = try folder("shop/api/app/Http")

        let location = ProjectFolder.locate(deep, in: [site("shop.test", shop), site("api.test", api)])

        #expect(location?.site.host == "api.test")
        #expect(location.map { RealPath.of($0.root) } == RealPath.of(api))
        #expect(ProjectFolder.locate(try folder("other"), in: [site("shop.test", shop)]) == nil)
    }

    @Test func aSiteOnThePublicFolderHoldsTheWholeProject() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop")
        let publicFolder = try folder("shop/public")
        let source = try folder("shop/app")
        try write("{}", to: "shop/composer.json")

        let location = ProjectFolder.locate(source, in: [site("shop.test", publicFolder)])

        #expect(location?.site.host == "shop.test")
        #expect(location.map { RealPath.of($0.root) } == RealPath.of(shop))
    }

    @Test func aPublicFolderWithoutAComposerFileHoldsOnlyItself() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let publicFolder = try folder("sites/public")
        let other = try folder("sites/other")
        try write("{}", to: "sites/package.json")

        #expect(ProjectFolder.locate(other, in: [site("shop.test", publicFolder)]) == nil)
        #expect(ProjectFolder.locate(publicFolder, in: [site("shop.test", publicFolder)])?.site.host == "shop.test")
    }

    @Test func aSiteOnTheProjectAndASiteOnItsPublicFolderKeepTheirOwnFolders() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop")
        let publicFolder = try folder("shop/public")
        let source = try folder("shop/app")
        try write("{}", to: "shop/composer.json")
        let sites = [site("shop.test", shop), site("assets.test", publicFolder)]

        #expect(ProjectFolder.locate(source, in: sites)?.site.host == "shop.test")
        #expect(ProjectFolder.locate(publicFolder, in: sites)?.site.host == "assets.test")
        #expect(ProjectFolder.locate(source, in: sites.reversed())?.site.host == "shop.test")
        #expect(ProjectFolder.locate(publicFolder, in: sites.reversed())?.site.host == "assets.test")
    }

    @Test func aWorktreeOfAPublicFolderThatIsARepositoryBelongsToTheSite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let publicFolder = try folder("shop/public")
        let worktreeFolder = try folder("ticket")
        try write("{}", to: "shop/composer.json")
        try worktree(of: "shop/public", at: "ticket")

        let location = ProjectFolder.locate(worktreeFolder, in: [site("shop.test", publicFolder)])

        #expect(location?.site.host == "shop.test")
        #expect(location.map { RealPath.of($0.root) } == RealPath.of(worktreeFolder))
    }

    @Test func aWorktreeOutsideTheSiteBelongsToTheSite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop")
        _ = try folder("shop/.git")
        try worktree(of: "shop", at: "worktrees/ticket-123")
        let inWorktree = try folder("worktrees/ticket-123/app")

        let location = ProjectFolder.locate(inWorktree, in: [site("shop.test", shop)])

        #expect(location?.site.host == "shop.test")
        #expect(location.map { RealPath.of($0.root) } == RealPath.of(root.appending(path: "worktrees/ticket-123")))
    }

    @Test func aSiteInASubfolderOfTheRepositoryHasTheSameSubfolderInTheWorktree() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try folder("repository/.git")
        let backend = try folder("repository/backend")
        try worktree(of: "repository", at: "worktrees/feature")
        let source = try folder("worktrees/feature/backend/src")
        let frontend = try folder("worktrees/feature/frontend")

        let location = ProjectFolder.locate(source, in: [site("backend.test", backend)])

        #expect(location?.site.host == "backend.test")
        #expect(location.map { RealPath.of($0.root) } == RealPath.of(root.appending(path: "worktrees/feature/backend")))
        #expect(ProjectFolder.locate(frontend, in: [site("backend.test", backend)]) == nil)
    }

    @Test func aSubmoduleIsNotAWorktree() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try folder("shop")
        let module = try folder("shop/.git/modules/theme")
        try write("gitdir: \(module.path(percentEncoded: false))\n", to: "vendor-theme/.git")

        #expect(ProjectFolder.worktree(holding: RealPath.of(try folder("vendor-theme"))) == nil)
        #expect(ProjectFolder.locate(try folder("vendor-theme"), in: [site("shop.test", shop)]) == nil)
    }
}
