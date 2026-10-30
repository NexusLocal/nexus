import Foundation
import NexusCore
import NexusSupervisor
import Testing
@testable import NexusWorkspaces

struct WorkspaceFilesTests {
    @Test func theCloneHoldsTheDependenciesTheBuildOutputAndTheFilesOfTheApplication() {
        let entries = [
            "vendor/",
            "node_modules/",
            "dist/",
            "public/build/",
            "public/css/app.css",
            "public/storage",
            "storage/app/uploads/",
            "storage/app/report.pdf",
        ]

        #expect(WorkspaceFiles.clonable(entries) == entries)
    }

    @Test func theCloneLeavesOutWhatBelongsToTheMainCheckout() {
        let entries = [
            ".env",
            ".env.testing",
            "public/hot",
            "bootstrap/cache/config.php",
            "bootstrap/cache/packages.php",
            "storage/logs/laravel.log",
            "storage/framework/sessions/one",
            "packages/shop/vendor/",
        ]

        #expect(WorkspaceFiles.clonable(entries).isEmpty)
    }

    @Test(arguments: [
        ("/main/storage/app/public", "public/storage", "../storage/app/public"),
        ("/main/storage/app/public", "public/media/storage", "../../storage/app/public"),
        ("/main/storage/app/public", "uploads", "storage/app/public"),
        ("../storage/app/public", "public/storage", "../storage/app/public"),
    ])
    func aLinkStaysInTheWorktree(destination: String, link: String, inWorktree: String) {
        #expect(WorkspaceFiles.linkDestination(destination, of: link, repository: "/main") == inWorktree)
    }

    @Test(arguments: ["/shared/uploads", "/main-two/uploads", "../../shared/uploads"])
    func aLinkOutsideTheProjectGivesNoDestination(destination: String) {
        #expect(WorkspaceFiles.linkDestination(destination, of: "public/storage", repository: "/main") == nil)
    }

    @Test func aLinkFromAnApplicationToAFolderOfItsRepositoryStaysInTheWorktree() {
        #expect(WorkspaceFiles.linkDestination("/main/packages/shop", of: "app/vendor/acme/shop", repository: "/main") == "../../../packages/shop")
        #expect(WorkspaceFiles.linkDestination("../../../packages/shop", of: "app/vendor/acme/shop", repository: "/main") == "../../../packages/shop")
    }

    @Test func aLinkThatNamesTheMainCheckoutThroughAnotherPathStaysInTheWorktree() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "nexus-alias-\(UUID().uuidString)", directoryHint: .isDirectory)
        let main = folder.appending(path: "main", directoryHint: .isDirectory)
        let alias = folder.appending(path: "alias")
        try manager.createDirectory(at: main.appending(path: "storage/app/public"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        try manager.createSymbolicLink(at: alias, withDestinationURL: main)

        let destination = "\(alias.path(percentEncoded: false))/storage/app/public"

        #expect(WorkspaceFiles.linkDestination(destination, of: "public/storage", repository: RealPath.of(main)) == "../storage/app/public")
    }

    @Test func aCloneOfAWholeFolderLosesTheViteFileAndKeepsItsLinksInTheWorktree() throws {
        let manager = FileManager.default
        let clone = manager.temporaryDirectory.appending(path: "nexus-repair-\(UUID().uuidString)", directoryHint: .isDirectory).path(percentEncoded: false)
        try manager.createDirectory(atPath: "\(clone)/css", withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: clone) }
        try Data("http://127.0.0.1:5173".utf8).write(to: URL(filePath: "\(clone)/hot"))
        try manager.createSymbolicLink(atPath: "\(clone)/storage", withDestinationPath: "/main/storage/app/public")
        try manager.createSymbolicLink(atPath: "\(clone)/css/old", withDestinationPath: "../app.css")
        try manager.createSymbolicLink(atPath: "\(clone)/shared", withDestinationPath: "/shared/uploads")
        try manager.createSymbolicLink(atPath: "\(clone)/package", withDestinationPath: "../../package")

        try WorkspaceFiles.repairClone(at: clone, of: "public", mainFolder: "/main", repository: "/main")

        #expect(!manager.fileExists(atPath: "\(clone)/hot"))
        #expect(try manager.destinationOfSymbolicLink(atPath: "\(clone)/storage") == "../storage/app/public")
        #expect(try manager.destinationOfSymbolicLink(atPath: "\(clone)/css/old") == "../app.css")
        #expect(try manager.destinationOfSymbolicLink(atPath: "\(clone)/shared") == "/shared/uploads")
        #expect(try manager.destinationOfSymbolicLink(atPath: "\(clone)/package") == "/package")
    }

    @Test func aFolderAboveAnIgnoredPathIsNoEntry() {
        let entries = ["public/", "public/css/", "public/css/app.css", "storage/", "storage/app/", "storage/app/uploads/"]

        #expect(WorkspaceFiles.clonable(entries) == ["public/css/app.css", "storage/app/uploads/"])
    }

    @Test func thePathsInAFolderWithAStarPatternCount() {
        let entries = ["vendor/", "vendor/autoload.php", "vendor/composer/", "dist/", "dist/app.js", "build/app.js"]

        #expect(WorkspaceFiles.clonable(entries) == ["vendor/autoload.php", "vendor/composer/", "dist/app.js", "build/app.js"])
    }

    private func git(_ arguments: String..., in folder: URL) async throws {
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path(percentEncoded: false)] + arguments))
    }

    @Test func gitListsTheIgnoredFilesInAFolderWithATrackedGitignore() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-entries-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = folder.appending(path: "storage/app/uploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await git("init", "-q", in: folder)
        try Data("vendor\n".utf8).write(to: folder.appending(path: ".gitignore"))
        try Data("*\n!.gitignore\n".utf8).write(to: folder.appending(path: "storage/app/.gitignore"))
        try FileManager.default.createDirectory(at: folder.appending(path: "vendor/one"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "vendor/one/file.php"))
        try Data().write(to: storage.appending(path: "photo één.jpg"))
        try await git("add", ".gitignore", "storage/app/.gitignore", in: folder)

        let entries = try await GitTool.ignoredEntries(in: folder.path(percentEncoded: false), git: URL(filePath: "/usr/bin/git"))

        #expect(Set(entries) == ["vendor/", "storage/app/uploads/"])
    }

    @Test func gitListsTheFilesOfAFolderWithOnlyIgnoredFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-inside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "public/css"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await git("init", "-q", in: folder)
        try Data("/public/css/*.css\n".utf8).write(to: folder.appending(path: ".gitignore"))
        try Data().write(to: folder.appending(path: "public/css/app.css"))
        try await git("add", ".gitignore", in: folder)

        let entries = try await GitTool.ignoredEntries(in: folder.path(percentEncoded: false), git: URL(filePath: "/usr/bin/git"))

        #expect(WorkspaceFiles.clonable(entries) == ["public/css/app.css"])
    }

    @Test func gitTellsWhichOfManyPathsItIgnores() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await git("init", "-q", in: folder)
        try Data("vendor\n*.log\n".utf8).write(to: folder.appending(path: ".gitignore"))
        let paths = ["vendor/", "src/", "a.log", "b.txt"] + (0..<1200).map { "many/\($0).log" }

        let ignored = try await GitTool.ignored(paths, in: folder.path(percentEncoded: false), git: URL(filePath: "/usr/bin/git"))

        #expect(ignored.contains("vendor/"))
        #expect(ignored.contains("a.log"))
        #expect(ignored.contains("many/1199.log"))
        #expect(ignored.count == 1202)
    }

    @Test func gitIgnoresNoPathOfAnEmptyList() async throws {
        let ignored = try await GitTool.ignored([], in: "/nexus-missing", git: URL(filePath: "/usr/bin/git"))

        #expect(ignored.isEmpty)
    }
}
