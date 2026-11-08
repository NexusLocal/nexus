import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

// A new site from a template (Phase 4, 3i). The tools need the network, so these tests check what
// nexusd refuses before a tool runs, and the files that it writes itself.
extension NexusEngineTests {
    @Test func aNewSiteRefusesAFolderThatExistsAndALeftFolder() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent.appending(path: "shop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appending(path: ".nexus-new-blog"), withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root, runtimes: [("node", "24")])
        let path = parent.path(percentEncoded: false)

        let exists = await engine.handle(.createSite(NewSite(template: .vite, name: "shop", parent: path)))
        let left = await engine.handle(.createSite(NewSite(template: .vite, name: "blog", parent: path)))
        let wrongName = await engine.handle(.createSite(NewSite(template: .vite, name: "My Shop", parent: path)))
        let noFolder = await engine.handle(.createSite(NewSite(template: .vite, name: "crm", parent: path + "/gone")))

        #expect(exists == .failure(message: "\(NexusEngine.shortPath(parent.appending(path: "shop"))) exists. Choose another name or another folder."))
        #expect(left == .failure(message: "\(NexusEngine.shortPath(parent.appending(path: ".nexus-new-blog"))) is left from an earlier new site. Move it to the Trash first."))
        #expect(wrongName == .failure(message: NewSiteError.invalidName("My Shop").description))
        #expect(noFolder == .failure(message: "\(path)/gone is not a folder."))
    }

    @Test func aNewSiteNeedsTheVersionsOfItsTemplate() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.2")])
        let path = root.path(percentEncoded: false)

        let laravel = await engine.handle(.createSite(NewSite(template: .laravel, name: "shop", parent: path)))
        let next = await engine.handle(.createSite(NewSite(template: .next, name: "shop", parent: path)))

        #expect(laravel == .failure(message: "Laravel 13 needs PHP 8.3 or newer. Run: nexus install php 8.5"))
        #expect(next == .failure(message: "Next.js needs Node.js. Run: nexus install node 24"))
    }

    @Test func moveToTrashKnowsOnlyTheLeftoversOfAFailedSite() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        let unknown = await engine.handle(.removeSiteLeftovers(id: "nothing"))

        #expect(unknown == .failure(message: "Nexus has nothing left of this new site. It was removed already, or nexusd started again."))
    }

    @Test func theLaravelInstallerCountsOnlyWithTheFixedVersion() throws {
        let folder = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "vendor/bin"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "vendor/bin/laravel"))

        try Data(#"{"require":{"laravel/installer":"5.31.*"}}"#.utf8).write(to: folder.appending(path: "composer.json"))
        #expect(!NexusEngine.hasLaravelInstaller(at: folder))

        try Data(#"{"require":{"laravel/installer":"5.32.*"}}"#.utf8).write(to: folder.appending(path: "composer.json"))
        #expect(NexusEngine.hasLaravelInstaller(at: folder))
    }

    @Test func aNewWordPressRepositoryIgnoresTheConfigurationAndTheUploads() throws {
        let folder = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("node_modules".utf8).write(to: folder.appending(path: ".gitignore"))

        try NexusEngine.addWordPressIgnore(in: folder)

        #expect(try String(contentsOf: folder.appending(path: ".gitignore"), encoding: .utf8) == "node_modules\n/wp-config.php\n/wp-content/uploads/\n.DS_Store\n")
    }

    @Test func theAdminOfWordPressGetsAnAddressOfTheHostAndAStrongPassword() throws {
        #expect(try NexusEngine.validatedAdminEmail("", host: "blog.test") == "admin@blog.test")
        #expect(try NexusEngine.validatedAdminEmail(" tim@example.com ", host: "blog.test") == "tim@example.com")
        #expect(throws: (any Error).self) { try NexusEngine.validatedAdminEmail("tim", host: "blog.test") }
        #expect(throws: (any Error).self) { try NexusEngine.validatedAdminUser("tim smith") }

        let passwords = Set((0..<20).map { _ in NexusEngine.newPassword() })
        #expect(passwords.count == 20)
        #expect(passwords.allSatisfy { $0.count == 24 && !$0.contains("l") && !$0.contains("0") })
    }

    @Test func aDatabaseNameThatIsTakenGetsANumber() {
        #expect(NexusEngine.freeName(base: "shop", taken: ["blog"]) == "shop")
        #expect(NexusEngine.freeName(base: "shop", taken: ["shop", "shop_2"]) == "shop_3")
        #expect(NexusEngine.freeName(base: "shop", taken: Set(["shop"] + (2...99).map { "shop_\($0)" })) == nil)
    }

    @Test func theLogViewHidesThePasswordAndFollowsTheSteps() throws {
        let log = siteTestRoot().appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: log) }
        try Data(" ⠶ Installing...\nadmin_password: Secret+1\n".utf8).write(to: log)
        let progress = TaskProgress()
        progress.update { values in
            values.steps = [TaskStep(title: "Download"), TaskStep(title: "Install")]
            values.logFile = log
            values.secrets = ["Secret+1"]
        }

        progress.start(step: 0)
        progress.start(step: 1)
        let (steps, lines) = progress.stepsAndLog(lines: 5)

        #expect(steps?.map(\.state) == [.done, .running])
        #expect(steps?[0].seconds == 1)
        #expect(lines == [" ⠶ Installing...", "admin_password: …"])
    }

    @Test func thePasswordGoesFromTheLog() throws {
        let log = siteTestRoot().appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: log) }
        try Data("wp core install --admin_password='Secret+1'\nSuccess\n".utf8).write(to: log)

        NexusEngine.removeFromLog("Secret+1", log)

        #expect(try String(contentsOf: log, encoding: .utf8) == "wp core install --admin_password='…'\nSuccess\n")
    }
}
