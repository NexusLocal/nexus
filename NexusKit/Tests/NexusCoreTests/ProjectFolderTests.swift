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
