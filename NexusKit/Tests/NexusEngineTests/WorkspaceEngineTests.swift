import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces
import Synchronization
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

        while await engine.workspaceWorkRuns {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func workspaces(_ engine: NexusEngine) async -> [WorkspaceInfo] {
        guard case .sites(let sites) = await engine.handle(.sites) else {
            return []
        }

        return sites.flatMap { $0.workspaces ?? [] }
    }

    private func worktreeEngine(root: URL, shop: URL, automatic: Bool? = nil, runtimes: [(name: String, line: String)] = []) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", automaticWorkspaces: automatic)]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: runtimes)
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
        #expect(await workspaces(engine) == [WorkspaceInfo(name: "ticket-123", worktree: path, folder: path, branch: "ticket", hosts: ["shop-ticket-123.test"], problem: "Every site needs nginx, and nginx is not installed. Run: nexus install nginx 1.30", state: .ready, warnings: [], databases: [], redisIndexes: [:], ports: [:])])

        try await git("worktree", "remove", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).isEmpty)
    }

    // A site that is no Laravel application, with the ignored files of a real application.
    private func applicationWithFiles(in root: URL) async throws -> URL {
        let shop = try await repository(in: root)
        try writeFile("vendor\nnode_modules\n/public/build\n/public/hot\n/public/storage\n/bootstrap/cache/*\n.env\n", to: ".gitignore", in: shop)
        try writeFile("*\n!.gitignore\n", to: "storage/app/.gitignore", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "files", in: shop)
        try writeFile("<?php", to: "vendor/autoload.php", in: shop)
        try writeFile("module.exports = 1", to: "node_modules/a/index.js", in: shop)
        try writeFile("built", to: "public/build/app.js", in: shop)
        try writeFile("http://127.0.0.1:5173", to: "public/hot", in: shop)
        try writeFile("cached", to: "bootstrap/cache/packages.php", in: shop)
        try writeFile("uploaded", to: "storage/app/uploads/a.txt", in: shop)
        try writeFile("MAIN=1\n", to: ".env", in: shop)
        try FileManager.default.createSymbolicLink(
            atPath: shop.appending(path: "public/storage").path(percentEncoded: false),
            withDestinationPath: "\(RealPath.of(shop))/storage/app/public"
        )
        return shop
    }

    private func gitOutput(_ arguments: String..., in folder: URL) async throws -> String {
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path(percentEncoded: false)] + arguments)).trimmed
    }

    @Test func aWorkspaceGetsTheFilesThatGitIgnoresAndGitSeesNoChange() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let exists = { (path: String) in FileManager.default.fileExists(atPath: worktree.appending(path: path).path(percentEncoded: false)) }
        let warnings = await workspaces(engine).first?.warnings

        #expect(try String(contentsOf: worktree.appending(path: "vendor/autoload.php"), encoding: .utf8) == "<?php")
        #expect(exists("node_modules/a/index.js"))
        #expect(exists("public/build/app.js"))
        #expect(exists("storage/app/uploads/a.txt"))
        #expect(!exists("public/hot"))
        #expect(!exists("bootstrap/cache/packages.php"))
        #expect(!exists(".env"))
        #expect(try await gitOutput("status", "--porcelain", in: worktree).isEmpty)
        #expect(warnings == [])
    }

    @Test func manyPathsThatGitSeesGiveOneWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let older = try await gitOutput("rev-parse", "HEAD", in: shop)
        try writeFile("/public/js/*.js\n", to: ".gitignore", in: shop)
        try writeFile("kept", to: "public/js/.gitkeep", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "assets", in: shop)
        try writeFile("one", to: "public/js/a.js", in: shop)
        try writeFile("two", to: "public/js/b.js", in: shop)
        try writeFile("three", to: "public/js/c.js", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), older, in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(warnings == ["git does not ignore public/js/a.js and 2 more paths in this worktree, so Nexus does not clone them."])
    }

    @Test func aFolderThatGitIgnoresAsAWholeLosesTheViteFileAndItsLinkToTheMainCheckout() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try writeFile("public\n", to: ".gitignore", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "ignore", in: shop)
        try writeFile("built", to: "public/app.js", in: shop)
        try writeFile("http://127.0.0.1:5173", to: "public/hot", in: shop)
        try FileManager.default.createSymbolicLink(
            atPath: shop.appending(path: "public/storage").path(percentEncoded: false),
            withDestinationPath: "\(RealPath.of(shop))/storage/app/public"
        )
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let folder = worktree.appending(path: "public").path(percentEncoded: false)

        #expect(FileManager.default.fileExists(atPath: "\(folder)/app.js"))
        #expect(!FileManager.default.fileExists(atPath: "\(folder)/hot"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(folder)/storage") == "../storage/app/public")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRepositoryInThePublicFolderGetsTheFilesThatItIgnores() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("{}", to: "composer.json", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile(Self.bootstrappers, to: "vendor/autoload.php", in: shop)
        try writeFile("<?php return ['default' => 'main', 'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]]];", to: "config/database.php", in: shop)
        try writeFile("APP_NAME=Shop\n", to: ".env", in: shop)
        try writeFile(".env\nvendor\n", to: ".gitignore", in: publicFolder)
        try await git("init", "-q", "-b", "main", in: publicFolder)
        try await git("add", "-A", in: publicFolder)
        try await git("commit", "-q", "-m", "first", in: publicFolder)
        try writeFile("<?php", to: "vendor/autoload.php", in: publicFolder)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: publicFolder, php: "8.5", workspaceCommands: [])]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: publicFolder)
            try await settle(engine)

            let workspace = await workspaces(engine).first

            #expect(workspace?.warnings == [])
            #expect(workspace?.state == .ready)
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "vendor/autoload.php").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealStopOfNexusdEndsARunningInstall() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let composer = #"{"name":"shop/app","version":"1.0.0","scripts":{"post-install-cmd":"sleep 37"}}"#
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("composer", "2"), lockFile: "composer.lock", main: Self.composerLock, branch: Self.composerLock + "\n", composer: composer)
        let start = ContinuousClock.now

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)

            let setup = Task { await engine.reconcileWorkspaces() }

            while await engine.runningCommand == nil {
                try await Task.sleep(for: .milliseconds(10))
            }

            await engine.stopWatchingWorktrees()
            await setup.value

            while await engine.workspaceWorkRuns {
                try await Task.sleep(for: .milliseconds(10))
            }

            let processes = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/ps"), arguments: ["-eo", "command"])).standardOutput

            #expect(ContinuousClock.now - start < .seconds(30))
            #expect(!processes.contains("sleep 37"))
            #expect(try await record(engine, of: shop).state == .preparing)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalDuringAnInstallLeavesNoFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let composer = #"{"name":"shop/app","version":"1.0.0","scripts":{"post-install-cmd":"sleep 38"}}"#
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("composer", "2"), lockFile: "composer.lock", main: Self.composerLock, branch: Self.composerLock + "\n", composer: composer)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)

            let setup = Task { await engine.reconcileWorkspaces() }

            while await engine.runningCommand == nil {
                try await Task.sleep(for: .milliseconds(10))
            }

            await setup.value
            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try writeFile("from the install", to: "vendor/part", in: worktree)
            try await settle(engine)

            #expect(!FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false)))
        }
    }

    private func engineWithCommands(_ commands: [String], root: URL, shop: URL) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", workspaceCommands: commands)]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        return engine
    }

    @Test func aNewWorkspaceRunsTheCommandsOfItsSiteOneTimeInItsWorktree() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo {workspace} {host} >> ran.txt", "pwd"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        let log = try String(contentsOf: await engine.paths.log("workspace-shop-fix.test"), encoding: .utf8)
        let workspace = try await record(engine, of: shop)

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "fix shop-fix.test\n")
        #expect(log.contains("$ pwd\n\(RealPath.of(worktree))\n"))
        #expect(workspace.commandsEnded)
        #expect(workspace.state == .ready)
    }

    @Test func aCorrectionOfACommandThatFailedReachesTheNextSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo first >> ran.txt", "wrong-program"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceCommands: ["echo first >> ran.txt", "echo right >> ran.txt"])))
        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        let workspace = try await record(engine, of: shop)

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "first\nright\n")
        #expect(workspace.warnings.isEmpty)
        #expect(workspace.commandsEnded)
    }

    @Test func theLogHoldsTheWholeOutputOfACommandThatFails() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo progress; echo problem >&2; exit 3"], root: root, shop: shop)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        let log = try String(contentsOf: await engine.paths.log("workspace-shop-fix.test"), encoding: .utf8)

        #expect(log.contains("progress\nproblem\n"))
        #expect(log.contains("exit status 3"))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealStartDuringAStopOfNexusdRunsNoCommand() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["touch ran.txt"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        var workspace = Workspace(name: "fix", worktree: RealPath.of(worktree), folder: RealPath.of(worktree))

        await engine.stopWatchingWorktrees()
        await engine.runCommands(of: &workspace, database: nil, key: RealPath.of(shop))

        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "ran.txt").path(percentEncoded: false)))
        #expect(!workspace.commandsEnded)
    }

    @Test func aCommandThatFailsStopsTheListAndARetryGoesOnFromThere() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo first >> ran.txt", "test -f allowed", "echo last >> ran.txt"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let failed = try await record(engine, of: shop)

        #expect(failed.state == .ready)
        #expect(failed.finishedCommands == ["echo first >> ran.txt"])
        #expect(!failed.commandsEnded)
        #expect(failed.warnings.first?.hasPrefix("The command test -f allowed failed.") == true)

        try writeFile("", to: "allowed", in: worktree)
        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        let retried = try await record(engine, of: shop)

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "first\nlast\n")
        #expect(retried.warnings.isEmpty)
    }

    @Test func aCommandThatASiteGetsLaterDoesNotRunInAWorkspaceThatExists() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands([], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceCommands: ["touch ran.txt"])))
        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "ran.txt").path(percentEncoded: false)))
    }

    @Test func aSiteThatIsNoLaravelApplicationGetsThePortsOfItsCommands() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo {port:scout} > ran.txt"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let port = try #require(try await record(engine, of: shop).ports["scout"])

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "\(port)\n")
    }

    @Test func aCommandThatChangedDuringTheSetupGetsItsPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", automaticWorkspaces: false, workspaceCommands: ["echo {port:scout} > ran.txt"])]
        let engine = try makeSiteEngine(root: root, state: state)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        var workspace = Workspace(name: "fix", worktree: RealPath.of(worktree), folder: RealPath.of(worktree))

        await engine.runCommands(of: &workspace, database: nil, key: RealPath.of(shop))

        let port = try #require(workspace.ports["scout"])

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "\(port)\n")
    }

    @Test func aCommandThatNeedsADatabaseDoesNotRunWithoutOne() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo {database} > ran.txt"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let workspace = try await record(engine, of: shop)

        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "ran.txt").path(percentEncoded: false)))
        #expect(workspace.warnings.first?.hasPrefix("The command echo {database} > ran.txt needs a database") == true)
        #expect(!workspace.commandsEnded)
    }

    @Test func aCommandWithoutThePHPOfItsSiteStillGetsTheLinksOfNexus() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["echo $PATH > ran.txt"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let path = try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8)
        let log = try String(contentsOf: await engine.paths.log("workspace-shop-fix.test"), encoding: .utf8)

        #expect(path.hasPrefix(RealPath.trimmed(await engine.paths.bin.path(percentEncoded: false))))
        #expect(log.contains("PHP 8.4 is not installed"))
    }

    @Test func aFolderThatIsGoneGivesAWarningAndRunsNoCommand() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands(["touch ran.txt"], root: root, shop: shop)
        let gone = root.appending(path: "gone").path(percentEncoded: false)
        var workspace = Workspace(name: "gone", worktree: gone, folder: gone)

        await engine.runCommands(of: &workspace, database: nil, key: RealPath.of(shop))

        #expect(workspace.warnings.first?.hasPrefix("Nexus did not run the command touch ran.txt") == true)
        #expect(!workspace.commandsEnded)
    }

    @Test func twoSitesWithTheSameCommandRunItOneTime() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: shop, php: "8.4", workspaceCommands: ["echo once >> ran.txt"]),
            Site(host: "store.test", folder: shop, php: "8.4", workspaceCommands: ["echo once >> ran.txt"]),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(try String(contentsOf: worktree.appending(path: "ran.txt"), encoding: .utf8) == "once\n")
    }

    @Test func anEmptyCommandIsNoCommandOfTheSite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithCommands([], root: root, shop: shop)

        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceCommands: ["  ", "php artisan cache:clear", "php artisan cache:clear"])))

        guard case .sites(let sites) = await engine.handle(.sites) else {
            Issue.record("No sites")
            return
        }

        #expect(sites.first?.workspaceCommands == ["php artisan cache:clear"])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealCommandUsesThePHPOfTheSiteAndThePlaceholdersOfTheWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n*.txt\n")
        let scout = #"php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION."\n";' > version.txt; echo {database} {port:scout} > values.txt"#
        try await engine.stateStore.update { $0.sites[0].workspaceCommands = [scout] }
        try writeFile("", to: "database/database.sqlite", in: shop)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let workspace = try await record(engine, of: shop)
        let port = try #require(workspace.ports["scout"])
        let values = try String(contentsOf: worktree.appending(path: "values.txt"), encoding: .utf8)

        #expect(try String(contentsOf: worktree.appending(path: "version.txt"), encoding: .utf8) == "8.5\n")
        #expect(values == "\(RealPath.of(worktree))/database/database.sqlite \(port)\n")
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceThatIsNotIsolatedRunsNoCommands() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("DB_PORT=1\nDB_DATABASE=shop\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceCommands: ["touch ran.txt"])]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            #expect(workspace.warnings == ["Nexus runs no commands in a workspace that is not isolated."])
            #expect(!workspace.commandsEnded)
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "ran.txt").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealApplicationWithAFixedPortIsNotIsolatedAndRunsNoProcessUntilTheFix() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        let config = databaseConfig(driver: "mysql")
        try writeFile(config.replacingOccurrences(of: Self.portOfTheConnectionCMS, with: "'cms' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '\(port)'"), to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "fixed port", in: shop)
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        try await engine.stateStore.update { $0.sites[0].backgroundCommands = ["echo started > started.txt; exec sleep 300"] }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let started = worktree.appending(path: "started.txt")

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            await engine.syncBackgroundProcesses().value

            #expect(try await record(engine, of: shop).state == .notIsolated("The connection cms has a fixed port in config/database.php."))
            #expect(await workspaces(engine).first?.isolationMessage == "fix is not isolated: the connection cms has a fixed port in config/database.php. Nexus starts no background process for it.")
            #expect(await runningProcesses(engine).isEmpty)
            #expect(text(of: started) == nil)

            try writeFile(config, to: "config/database.php", in: shop)

            let branchIsTheCause = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection cms has a fixed port in config/database.php.")
            }

            #expect(branchIsTheCause)
            #expect(await runningProcesses(engine).isEmpty)

            try writeFile(config, to: "config/database.php", in: worktree)

            let isReady = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == .ready
            }

            #expect(isReady)
            #expect(await eventually { text(of: started) == "started\n" })
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: [
        (name: "'{port}'", reason: "The connection cms has a fixed port in config/database.php."),
        (name: "env('CMS_PORT', '3306')", reason: "The key CMS_PORT is not in the configuration of the main checkout. So Nexus does not change it."),
    ])
    func aRealBranchWithAnotherConfigurationIsNotIsolatedAndRunsNothing(name: String, reason: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        let config = databaseConfig(driver: "mysql")
        let portOfBranch = name.replacingOccurrences(of: "{port}", with: String(port))
        try writeFile(config, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "connections", in: shop)
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try writeFile(config.replacingOccurrences(of: Self.portOfTheConnectionCMS, with: "'cms' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => \(portOfBranch)"), to: "config/database.php", in: shop)
        try await git("commit", "-q", "-am", "branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try writeFile("DB_PORT=\(port)\nCMS_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        try await engine.stateStore.update { state in
            state.sites[0].backgroundCommands = ["touch started.txt; exec sleep 300"]
            state.sites[0].workspaceCommands = ["touch ran.txt"]
        }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")

            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)
            await engine.syncBackgroundProcesses().value

            #expect(try await record(engine, of: shop).state == .notIsolated("The configuration of this worktree is different from the main checkout. \(reason)"))
            #expect(await runningProcesses(engine).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "started.txt").path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "ran.txt").path(percentEncoded: false)))
        }
    }

    @Test func theConfigurationDigestFollowsTheFilesThatTheProbeReads() throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("DB_DATABASE=shop\n", to: ".env", in: root)
        try writeFile("<?php return [];", to: "config/database.php", in: root)
        let digest = { NexusEngine.configurationDigest(of: root.path(percentEncoded: false), in: root.path(percentEncoded: false)) }
        let first = digest()

        try writeFile("a log line", to: "storage/logs/laravel.log", in: root)
        #expect(digest() == first)

        try writeFile("<?php return ['x' => 1];", to: "config/database.php", in: root)
        let second = digest()
        #expect(second != first)

        try writeFile("<?php return [];", to: "config/packages/mail.php", in: root)
        let third = digest()
        #expect(third != second)

        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: root)
        #expect(digest() != third)
    }

    @Test func theConfigurationDigestOfASubfolderFollowsTheGitignoreOfTheWorktree() throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appending(path: "backend", directoryHint: .isDirectory)
        try writeFile(".env\n", to: ".gitignore", in: root)
        try writeFile("<?php return [];", to: "config/database.php", in: application)
        let digest = { NexusEngine.configurationDigest(of: application.path(percentEncoded: false), in: root.path(percentEncoded: false)) }
        let first = digest()

        try writeFile("vendor\n", to: ".gitignore", in: root)

        #expect(digest() != first)
    }

    @Test func theConfigurationDigestFollowsTheGitignoreOfEachFolderAboveTheApplication() throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appending(path: "apps/backend", directoryHint: .isDirectory)
        try writeFile(".env\n", to: "apps/.gitignore", in: root)
        try writeFile("<?php return [];", to: "config/database.php", in: application)
        let digest = { NexusEngine.configurationDigest(of: application.path(percentEncoded: false), in: root.path(percentEncoded: false)) }
        let first = digest()

        try writeFile("vendor\n", to: "apps/.gitignore", in: root)

        #expect(digest() != first)
    }

    private func readyApplication(in root: URL, commands: [String]) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        try await engine.stateStore.update { $0.sites[0].backgroundCommands = commands }
        try writeFile("", to: "database/database.sqlite", in: shop)
        return (shop, engine, worktree)
    }

    private static let fixedNameConfig = #"<?php return ['default' => 'main', 'connections' => ['main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => 1, 'database' => 'shop']]];"#

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealChangeInAReadyWorktreeStopsTheProcessesAndARevertStartsThem() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)

            let clean = try #require(text(of: worktree.appending(path: "config/database.php")))
            try writeFile(Self.fixedNameConfig, to: "config/database.php", in: worktree)

            let notIsolated = WorkspaceState.notIsolated("The configuration of this worktree is different from the main checkout. The connection main does not use a Nexus database instance.")
            let hasStopped = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == notIsolated
            }

            #expect(hasStopped)
            #expect(await runningProcesses(engine).isEmpty)

            try writeFile(clean, to: "config/database.php", in: worktree)

            let isReady = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == .ready
            }

            #expect(isReady)
            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealFixInTheMainCheckoutStartsTheProcessesWithoutARetry() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])
        let clean = try #require(text(of: shop.appending(path: "config/database.php")))
        try writeFile(Self.fixedNameConfig, to: "config/database.php", in: shop)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("The connection main does not use a Nexus database instance."))
            #expect(await runningProcesses(engine).isEmpty)

            try writeFile(clean, to: "config/database.php", in: shop)

            let isReady = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == .ready
            }

            #expect(isReady)
            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test func aRepositoryInThePublicFolderHasNoMigrateCommand() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try writeFile("", to: "artisan", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile("hello", to: "index.html", in: publicFolder)
        try await git("init", "-q", "-b", "main", in: publicFolder)

        #expect(NexusEngine.commands(of: [Site(host: "shop.test", folder: publicFolder, php: "8.5")]).isEmpty)
        #expect(NexusEngine.commands(of: [Site(host: "shop.test", folder: shop, php: "8.5")]) == [NexusEngine.migrateCommand])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealFixAboveARepositoryInThePublicFolderNeedsNoRetry() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("{}", to: "composer.json", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile(Self.bootstrappers, to: "vendor/autoload.php", in: shop)
        try writeFile(Self.fixedNameConfig, to: "config/database.php", in: shop)
        try writeFile("APP_NAME=Shop\n", to: ".env", in: shop)
        try writeFile(".env\nvendor\n", to: ".gitignore", in: publicFolder)
        try await git("init", "-q", "-b", "main", in: publicFolder)
        try await git("add", "-A", in: publicFolder)
        try await git("commit", "-q", "-m", "first", in: publicFolder)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: publicFolder, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: publicFolder)
            try await settle(engine)

            #expect(await workspaces(engine).first?.state == .notIsolated("The connection main does not use a Nexus database instance."))

            try writeFile("<?php return ['default' => 'main', 'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]]];", to: "config/database.php", in: shop)

            #expect(await eventually { await workspaces(engine).first?.state == .ready })
        }
    }

    private static let noApplication = WorkspaceState.notIsolated("The main checkout holds no Laravel application now. Restore it. When this site is no Laravel application any more, use Retry.")

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealMainCheckoutWithoutItsApplicationKeepsTheCheckOfAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try FileManager.default.removeItem(at: shop.appending(path: "artisan"))
            try writeFile(Self.fixedNameConfig, to: "config/database.php", in: worktree)

            let hasNoApplication = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == Self.noApplication
            }

            #expect(hasNoApplication)
            #expect(await runningProcesses(engine).isEmpty)

            try writeFile("", to: "artisan", in: shop)

            let branchIsTheCause = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection main does not use a Nexus database instance.")
            }

            #expect(branchIsTheCause)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRetryAcceptsASiteThatIsNoLaravelApplicationAnyMore() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try FileManager.default.removeItem(at: shop.appending(path: "artisan"))
            try writeFile("changed", to: ".env", in: worktree)

            let hasNoApplication = try await eventually {
                let state = try await record(engine, of: shop).state
                return state == Self.noApplication
            }

            #expect(hasNoApplication)

            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            #expect(workspace.state == .ready)
            #expect(workspace.configurationDigest == nil)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealChangeInTheMainCheckoutLeavesAReadyWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let first = try #require(await processNumber(engine))
            try writeFile(Self.fixedNameConfig, to: "config/database.php", in: shop)
            try await Task.sleep(for: .seconds(3))
            try await settle(engine)

            #expect(await processNumber(engine) == first)
            #expect(try await record(engine, of: shop).state == .ready)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealEditOfTheEnvFileGetsTheValueOfTheWorkspaceBack() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])
        let env = worktree.appending(path: ".env")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let isolated = try #require(text(of: env))
            try writeFile(try #require(text(of: shop.appending(path: ".env"))), to: ".env", in: worktree)

            #expect(await eventually { text(of: env) == isolated })
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealSetupGivesNoSecondSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let first = try #require(await processNumber(engine))
            try await Task.sleep(for: .seconds(3))

            #expect(await processNumber(engine) == first)
            #expect(try await record(engine, of: shop).state == .ready)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRecordWithoutADigestGetsNoNewSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.configurationDigest = nil }

            try writeFile(Self.fixedNameConfig, to: "config/database.php", in: worktree)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aChangeInAWorktreeThatGitRemovesGetsNoNewSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            await engine.useWorktreeRemovalCheck { true }

            try FileManager.default.removeItem(at: worktree.appending(path: "config/database.php"))
            try FileManager.default.removeItem(at: worktree.appending(path: ".env"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(text(of: worktree.appending(path: ".env")) == nil)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aFailedCommandThatChangesTheEnvFileRunsOneTime() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])
        try await engine.stateStore.update { $0.sites[0].workspaceCommands = ["echo run >> runs.txt; echo X$$=1 >> .env; exit 1"] }
        let runs = worktree.appending(path: "runs.txt")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await Task.sleep(for: .seconds(3))
            try await settle(engine)

            #expect(text(of: runs) == "run\n")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aFailedCommandThatReplacesTheEnvFileGivesTheValueOfTheWorkspaceBack() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])
        let mainEnv = shop.appending(path: ".env")
        try await engine.stateStore.update { [path = RealPath.of(mainEnv)] in $0.sites[0].workspaceCommands = ["cp \(path) .env; exit 1"] }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(text(of: worktree.appending(path: ".env")) != text(of: mainEnv))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aChangeStopsTheProcessesDuringTheSetupOfAnotherWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: ["exec sleep 300"])
        try await engine.stateStore.update { $0.sites[0].workspaceCommands = [#"[ "$(basename "$PWD")" != slow ] || sleep 30"#] }
        let slow = root.appending(path: "slow", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)

            try await git("worktree", "add", "-q", "-b", "other", slow.path(percentEncoded: false), in: shop)
            await engine.reconcileWorkspaces()
            try writeFile(Self.fixedNameConfig, to: "config/database.php", in: worktree)

            #expect(await eventually { await runningProcesses(engine).isEmpty })
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aChangeInAWorktreeWithoutItsGitFileGetsNoNewSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await readyApplication(in: root, commands: [])

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try FileManager.default.removeItem(at: worktree.appending(path: ".git"))
            try FileManager.default.removeItem(at: worktree.appending(path: ".env"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(text(of: worktree.appending(path: ".env")) == nil)
        }
    }

    private func databaseApplication(in root: URL, driver: String, runtime: (name: String, line: String)) async throws -> (shop: URL, engine: NexusEngine, worktree: URL, port: Int) {
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(databaseConfig(driver: driver), to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "connections", in: shop)
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: runtime, port: port)
        return (shop, engine, root.appending(path: "fix", directoryHint: .isDirectory), port)
    }

    private func mainDatabase(_ client: DatabaseClient, options: String = "") async throws {
        try await client.query("CREATE DATABASE shop\(options)")
        try await client.query("CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(20))", database: "shop")
        try await client.query("INSERT INTO items VALUES (1, 'one')", database: "shop")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: [("mysql", "8.4", "mysql"), ("mariadb", "11.4", "mariadb"), ("postgresql", "17", "pgsql")])
    func aRealRemovalKeepsADumpRemovesTheCloneAndTheDumpRestores(name: String, line: String, driver: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: driver, runtime: (name, line))
        let id = "\(name)-\(line)"
        let isPostgreSQL = name == "postgresql"

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            let client = try await databaseClient(engine, id: id, port: port)
            try await mainDatabase(client, options: isPostgreSQL ? "" : " CHARACTER SET latin1 COLLATE latin1_bin")

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let own = try await workspaceClient(engine, id: id, of: shop)
            let folder = try await record(engine, of: shop).servers[0].folder

            try await own.query("INSERT INTO items VALUES (2, 'workspace')", database: "shop")
            let copy = try await digest(own, "shop")
            let main = try await digest(client, "shop")

            #expect(copy != main)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            await engine.startDatabaseRemovals().value

            let dumps = await engine.dumps()
            let dump = try #require(dumps.first)
            let trash = await engine.paths.trash.path(percentEncoded: false)

            #expect(dumps.count == 1)
            #expect(dump.name.hasSuffix("-\(id)-shop_fix.\(isPostgreSQL ? "dump.gz" : "sql.gz")"))
            #expect(!FileManager.default.fileExists(atPath: folder))
            #expect(!PortInspector.acceptsConnections(own.endpoint.port))
            #expect(try await digest(client, "shop") == main)
            #expect(await engine.stateStore.current().databaseRemovals.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash) == [dump.name])

            let restored = await engine.handle(.restoreDump(file: dump.name, instance: id, name: "restored"))

            #expect(restored == .done(message: "\(dump.name) is restored into \(id) as restored."))
            #expect(try await digest(client, "restored") == copy)

            if !isPostgreSQL {
                #expect(try await client.query("SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'restored'") == "latin1_bin")
            }
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealNewWorktreeWithTheNameOfARemovedOneGetsANewCopy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await mainDatabase(client)
            let main = try await digest(client, "shop")

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await workspaceClient(engine, id: "mysql-8.4", of: shop).query("INSERT INTO items VALUES (2, 'workspace')", database: "shop")

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(try await digest(try await workspaceClient(engine, id: "mysql-8.4", of: shop), "shop") == main)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealDatabaseWithoutADumpStaysAndTheSiteShowsWhy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))
        let trash = await engine.paths.trash.path(percentEncoded: false)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await mainDatabase(client)

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let folder = try await record(engine, of: shop).servers[0].folder

            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: trash)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash) }

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            await engine.startDatabaseRemovals().value

            guard case .sites(let sites) = await engine.handle(.sites) else {
                Issue.record("No sites")
                return
            }

            #expect(FileManager.default.fileExists(atPath: folder))
            #expect(await engine.stateStore.current().databaseRemovals.count == 1)
            #expect(sites.first?.workspaceProblem?.contains("Nexus did not remove the database server of the removed workspace fix") == true)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash)
            await engine.forgetRemovalProblems()
            await engine.startDatabaseRemovals().value

            #expect(!FileManager.default.fileExists(atPath: folder))
            #expect(await engine.dumps().count == 1)
        }
    }

    @Test func aCloneThatDidNotEndGoesWithoutADump() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: 20000, account: .standard)

        try await engine.stateStore.update { $0.databaseRemovals = [DatabaseRemoval(server: server, databases: ["shop"], workspace: "fix", site: "/w")] }
        await engine.startDatabaseRemovals().value

        #expect(!FileManager.default.fileExists(atPath: clone.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(await engine.dumps().isEmpty)
        #expect(await engine.stateStore.current().databaseRemovals.isEmpty)
    }

    @Test func aPackageWithTheServerOfAWorkspaceStays() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: "/clones/one/mysql-8.4", port: 20000, account: .standard, isComplete: true)
        var state = EngineState()
        state.worktrees["/w"] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix", servers: [server])])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])

        let package = await engine.paths.runtime("mysql", line: "8.4").path(percentEncoded: false)

        #expect(await engine.handle(.remove(name: "mysql", line: "8.4")) == .failure(message: "The workspace fix has a database server of mysql-8.4. Remove that workspace first."))
        #expect(FileManager.default.fileExists(atPath: package))
    }

    @Test func aPackageThatARemovalNeedsStays() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: "/clones/one/mysql-8.4", port: 20000, account: .standard, isComplete: true)
        var state = EngineState()
        state.databaseRemovals = [DatabaseRemoval(server: server, databases: ["shop"], workspace: "fix", site: "/w")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])

        let package = await engine.paths.runtime("mysql", line: "8.4").path(percentEncoded: false)

        #expect(await engine.handle(.remove(name: "mysql", line: "8.4")) == .failure(message: "Nexus still removes the database server of the workspace fix. Try again when that is complete."))
        #expect(FileManager.default.fileExists(atPath: package))
    }

    @Test func aRemovalFromBeforeTheClonesDoesNotMakeTheStateUnreadable() throws {
        let text = #"{"tld": "dev", "databaseRemovals": [{"copy": {"instance": "mysql-8.4", "name": "shop_fix"}, "site": "/w", "keepsDump": true}]}"#
        let state = try JSONDecoder().decode(EngineState.self, from: Data(text.utf8))

        #expect(state.tld == "dev")
        #expect(state.databaseRemovals.isEmpty)
    }

    @Test func aRemovedWorkspaceNamesItsServersInTheStateAtOnce() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: "/clones/one/mysql-8.4", port: 20000, account: .standard, isComplete: true)
        let half = WorkspaceDatabaseServer(instance: "postgresql-17", folder: "/clones/two/postgresql-17", port: 20001, account: .standard)
        let database = WorkspaceDatabaseCopy(instance: "mysql-8.4", name: "shop")
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix", servers: [finished, half], databases: [database])
        let engine = try makeSiteEngine(root: root)
        _ = try await engine.stateStore.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [workspace])] }

        _ = try await engine.stateStore.updateWorktrees { _ in ["/w": SiteWorktrees()] }

        #expect(await engine.stateStore.current().databaseRemovals == [
            DatabaseRemoval(server: finished, databases: ["shop"], workspace: "fix", site: "/w"),
            DatabaseRemoval(server: half, databases: [], workspace: "fix", site: "/w"),
        ])
    }

    @Test func createMakesAWorkspaceWhenTheSwitchOfTheSiteIsOff() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop, automatic: false)
        let worktree = root.appending(path: "Ticket-1", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        #expect(await workspaces(engine).isEmpty)

        let folder = worktree.appending(path: "app/Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(await engine.handle(.createWorkspace(folder: folder.path(percentEncoded: false))) == .done(message: "Nexus makes the workspace ticket-1."))
        try await settle(engine)
        #expect(await workspaces(engine).map(\.name) == ["ticket-1"])
        #expect(await engine.handle(.createWorkspace(folder: folder.path(percentEncoded: false))) == .done(message: "The workspace ticket-1 exists already."))
    }

    @Test func createDirectlyAfterAMoveKeepsTheWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let moved = root.appending(path: "moved/fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git("worktree", "move", worktree.path(percentEncoded: false), moved.path(percentEncoded: false), in: shop)

        _ = await engine.handle(.createWorkspace(folder: moved.path(percentEncoded: false)))
        try await settle(engine)

        #expect(await workspaces(engine).map(\.name) == ["fix"])
        #expect(await workspaces(engine).map(\.worktree) == [RealPath.of(moved)])
    }

    @Test func createExplainsAFolderWithoutAWorktreeOrASite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: other)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: other)
        let foreign = root.appending(path: "foreign", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", foreign.path(percentEncoded: false), in: other)
        let engine = try await worktreeEngine(root: root, shop: shop)

        guard case .failure(let inMain) = await engine.handle(.createWorkspace(folder: shop.path(percentEncoded: false))),
              case .failure(let inForeign) = await engine.handle(.createWorkspace(folder: foreign.path(percentEncoded: false))) else {
            Issue.record("A request worked")
            return
        }

        #expect(inMain.hasSuffix("is in no git worktree. Make one with git worktree add."))
        #expect(inForeign.hasPrefix("No site of Nexus holds"))
    }

    @Test func createInANewSiteLeavesItsOtherWorktreesAlone() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = root.appending(path: "second", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "first", first.path(percentEncoded: false), in: shop)
        try await git("worktree", "add", "-q", "-b", "second", second.path(percentEncoded: false), in: shop)

        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state)

        #expect(await engine.handle(.createWorkspace(folder: first.path(percentEncoded: false))) == .done(message: "Nexus makes the workspace first."))
        try await settle(engine)
        #expect(await workspaces(engine).map(\.name) == ["first"])
    }

    @Test func createRefusesAWorktreeOfAnotherRepositoryInTheFolderOfASite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: other)
        try await git("commit", "-q", "--allow-empty", "-m", "first", in: other)
        let foreign = shop.appending(path: "foreign", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", foreign.path(percentEncoded: false), in: other)
        let engine = try await worktreeEngine(root: root, shop: shop)

        guard case .failure(let message) = await engine.handle(.createWorkspace(folder: foreign.path(percentEncoded: false))) else {
            Issue.record("A worktree of another repository got a workspace")
            return
        }

        #expect(message.hasSuffix("is no worktree of \(RealPath.of(shop))."))
        #expect(await workspaces(engine).isEmpty)
    }

    @Test func removeAsksGitAndKeepsAWorktreeWithChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        try writeFile("work", to: "new.txt", in: worktree)

        guard case .failure(let refused) = await engine.handle(.removeWorkspace(host: "shop.test", name: "fix", force: false)) else {
            Issue.record("git removed a worktree with changes")
            return
        }

        #expect(refused.hasPrefix("git did not remove the worktree. So the workspace stays."))
        #expect(await workspaces(engine).map(\.name) == ["fix"])
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "new.txt").path(percentEncoded: false)))

        #expect(await engine.handle(.removeWorkspace(host: "shop.test", name: "fix", force: true)) == .done(message: "The workspace fix is removed."))
        #expect(await workspaces(engine).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false)))
    }

    @Test func removeNamesAnUnknownWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)

        #expect(await engine.handle(.removeWorkspace(host: "shop.test", name: "none", force: false)) == .failure(message: "shop.test has no workspace none."))
        #expect(await engine.handle(.removeWorkspace(host: "none.test", name: "fix", force: false)) == .failure(message: "Nexus has no site none.test."))
    }

    @Test func aRemovedSiteAlsoRemovesTheServerOfAWorktreeThatStillExists() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try writeFile("gitdir: /w/.git/worktrees/fix\n", to: ".git", in: worktree)
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: "/clones/one/mysql-8.4", port: 20000, account: .standard, isComplete: true)
        let workspace = Workspace(name: "fix", worktree: RealPath.of(worktree), folder: RealPath.of(worktree), servers: [server])
        let engine = try makeSiteEngine(root: root)
        _ = try await engine.stateStore.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [workspace])] }

        _ = try await engine.stateStore.updateWorktrees { _ in [:] }

        #expect(await engine.stateStore.current().databaseRemovals.map(\.server) == [server])
    }

    @Test func aRemovalWaitsForThePackageWhileItsCloneExists() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let clone = root.appending(path: "clones/one/mysql-8.4", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let server = WorkspaceDatabaseServer(instance: "mysql-8.4", folder: clone.path(percentEncoded: false), port: 20000, account: .standard, isComplete: true)
        try await engine.stateStore.update { $0.databaseRemovals = [DatabaseRemoval(server: server, databases: ["shop"], workspace: "fix", site: "/w")] }

        await engine.startDatabaseRemovals().value

        #expect(await engine.stateStore.current().databaseRemovals.count == 1)

        try FileManager.default.removeItem(at: clone)
        await engine.forgetRemovalProblems()
        await engine.startDatabaseRemovals().value

        #expect(await engine.stateStore.current().databaseRemovals.isEmpty)
    }

    @Test func oldDumpsLeaveTheTrashWithoutAChangeInNexus() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let trash = await engine.paths.trash
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let old = trash.appending(path: "old.sql.gz")
        try Data("a".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path(percentEncoded: false))

        await engine.useTrashCheckWait(.milliseconds(10))
        await engine.startTrashChecks()

        #expect(await eventually { await engine.dumps().isEmpty })
        await engine.stopDumps()
    }

    @Test func oldDumpsLeaveTheTrashAndEmptyTrashRemovesTheRest() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let trash = await engine.paths.trash
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let old = trash.appending(path: "old.sql.gz")
        let new = trash.appending(path: "new.dump.gz")
        let partial = trash.appending(path: "half.sql.gz.partial")
        try Data("a".utf8).write(to: old)
        try Data("b".utf8).write(to: new)
        try Data("c".utf8).write(to: partial)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path(percentEncoded: false))

        await engine.removeOldDumps(after: 7)

        #expect(await engine.dumps().map(\.name) == ["new.dump.gz"])
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(await engine.handle(.emptyTrash) == .done(message: "Nexus removed 1 dump from the trash."))
        #expect(await engine.dumps().isEmpty)
    }

    @Test func aRunOfTheRemovalsRemovesAHalfDumpOfACrash() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let trash = await engine.paths.trash
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let partial = trash.appending(path: "half.sql.gz.partial")
        try Data("c".utf8).write(to: partial)

        await engine.startDatabaseRemovals().value

        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
    }

    @Test func aProblemWithoutARemovalLeavesTheList() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        await engine.addDatabaseRemovalProblem(for: "/clones/one/mysql-8.4")
        await engine.startDatabaseRemovals().value

        #expect(await engine.databaseRemovalProblems.isEmpty)
        #expect(await engine.databaseRemovalRetry == nil)
    }

    @Test func theTrashKeepsADumpForAtLeastOneDay() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        #expect(await engine.handle(.setWorkspaceSettings(WorkspaceSettings(dumpDays: 0))) == .failure(message: "The trash keeps a dump for at least 1 day."))
        #expect(await engine.handle(.setWorkspaceSettings(WorkspaceSettings(dumpDays: 30))) == .done(message: "The settings of the workspaces are changed."))
        #expect(await engine.handle(.workspaceSettings) == .workspaceSettings(WorkspaceSettings(dumpDays: 30)))
    }

    @Test func aGoneHostLeavesItsLogsAndCertificates() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let paths = await engine.paths

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let gone = [paths.log("workspace-shop-fix.test"), paths.siteLog("shop-fix.test"), paths.certs.appending(path: "shop-fix.test.crt"), paths.certs.appending(path: "shop-fix.test.key")]
        let kept = [paths.log("main-shop.test"), paths.siteLog("shop.test"), paths.certs.appending(path: "shop.test.crt"), paths.certs.appending(path: "other.test.key")]

        for file in gone + kept {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(gone.allSatisfy { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
    }

    private func worktreeOfBranch(in root: URL, env: String = "", change: (URL) throws -> Void) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try change(shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try writeFile("", to: "database/database.sqlite", in: shop)
        try writeFile(try #require(text(of: shop.appending(path: ".env"))) + env, to: ".env", in: shop)
        return (shop, engine, worktree)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealBranchWithAConnectionToASQLiteFileOfTheMainCheckoutIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = RealPath.of(root) + "/shop/database/analytics.sqlite"
        let (shop, engine, worktree) = try await worktreeOfBranch(in: root, env: "ANALYTICS_DB=\(shared)\n") { shop in
            try writeFile(#"""
            <?php
            return ['default' => 'main', 'connections' => [
                'main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')],
                'analytics' => ['driver' => 'sqlite', 'database' => env('ANALYTICS_DB')],
            ]];
            """#, to: "config/database.php", in: shop)
        }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let state = try await record(engine, of: shop).state

            #expect(state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection analytics uses a SQLite file of the main checkout."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealBranchWithoutArtisanStillGetsTheCheckOfItsConfiguration() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await worktreeOfBranch(in: root) { shop in
            try FileManager.default.removeItem(at: shop.appending(path: "artisan"))
            try writeFile(#"<?php return ['default' => 'main', 'connections' => ['main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => 1, 'database' => 'shop']]];"#, to: "config/database.php", in: shop)
        }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection main does not use a Nexus database instance."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealBranchWithAnotherConfigurationAndANewLockFileRunsNoInstallScript() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        try writeFile(#"{"name":"shop/app","version":"1.0.0","scripts":{"post-install-cmd":"touch script.txt"}}"#, to: "composer.json", in: shop)
        try writeFile(Self.composerLock, to: "composer.lock", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "composer", in: shop)
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try writeFile(Self.composerLock + "\n", to: "composer.lock", in: shop)
        try writeFile(#"<?php return ['default' => 'main', 'connections' => ['main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => 1, 'database' => 'shop']]];"#, to: "config/database.php", in: shop)
        try await git("commit", "-q", "-am", "branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try await link(("composer", "2"), in: engine)
        try writeFile("", to: "database/database.sqlite", in: shop)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            #expect(workspace.state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection main does not use a Nexus database instance."))
            #expect(workspace.warnings == ["vendor does not fit composer.lock, and Nexus runs no install in a workspace that is not isolated.", "Nexus runs no commands in a workspace that is not isolated."])
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "script.txt").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealBranchThatLoadsOnlyAfterComposerRunsNoScriptOfNpm() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\nnode_modules\n*.sqlite\n")
        try writeFile(#"{"name":"shop/app","version":"1.0.0","autoload":{"files":["bootstrappers.php"]},"scripts":{"post-install-cmd":"echo '<?php' > from-composer.php"}}"#, to: "composer.json", in: shop)
        try writeFile(Self.composerLock, to: "composer.lock", in: shop)
        try writeFile(Self.bootstrappers, to: "bootstrappers.php", in: shop)
        try writeFile(#"{"name":"app","version":"1.0.0","scripts":{"postinstall":"touch from-npm.txt"}}"#, to: "package.json", in: shop)
        try writeFile(Self.npmLock, to: "package-lock.json", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "tools", in: shop)
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try writeFile(Self.composerLock + "\n", to: "composer.lock", in: shop)
        try writeFile(Self.npmLock + "\n", to: "package-lock.json", in: shop)
        try writeFile(#"<?php require __DIR__.'/../from-composer.php'; return ['default' => 'main', 'connections' => ['main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => 1, 'database' => 'shop']]];"#, to: "config/database.php", in: shop)
        try await git("commit", "-q", "-am", "branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try await link(("composer", "2"), in: engine)
        try await link(("node", "24"), in: engine)
        try writeFile("", to: "database/database.sqlite", in: shop)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "from-composer.php").path(percentEncoded: false)))
            #expect(workspace.state == .notIsolated("The configuration of this worktree is different from the main checkout. The connection main does not use a Nexus database instance."))
            #expect(workspace.warnings == ["node_modules does not fit package-lock.json, and Nexus runs no install in a workspace that is not isolated.", "Nexus runs no commands in a workspace that is not isolated."])
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "from-npm.txt").path(percentEncoded: false)))
        }
    }

    private func engineWithProcesses(_ commands: [String], root: URL, shop: URL, supervisor: ProcessSupervisor = ProcessSupervisor()) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", backgroundCommands: commands)]
        let engine = try makeSiteEngine(root: root, state: state, processSupervisor: supervisor)
        try await settle(engine)
        return engine
    }

    private func runningProcesses(_ engine: NexusEngine) async -> [String] {
        await engine.processSupervisor.status()
            .filter { $0.state.isActive && !$0.displayName.hasSuffix("of a workspace") }
            .map(\.displayName)
            .sorted()
    }

    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)

        while ContinuousClock.now < deadline {
            if try await condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    private func text(of file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    private func processNumber(_ engine: NexusEngine) async -> Int32? {
        for status in await engine.processSupervisor.status() {
            if case .running(let pid, _) = status.state {
                return pid
            }
        }

        return nil
    }

    @Test func aWorkspaceRunsItsOwnProcessAndARemovalEndsIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["echo {workspace} {host} {port:web} > started.txt; exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let started = worktree.appending(path: "started.txt")

        try await whileRunning(engine) {
            #expect(await runningProcesses(engine).isEmpty)

            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let port = try #require(try await record(engine, of: shop).ports["web"])

            #expect(await eventually { text(of: started) == "fix shop-fix.test \(port)\n" })
            #expect(await runningProcesses(engine).count == 1)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func twoWorkspacesRunTheSameCommandOnTwoPorts() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["echo {port:vite} > port.txt; exec sleep 300"], root: root, shop: shop)
        let first = root.appending(path: "one", directoryHint: .isDirectory)
        let second = root.appending(path: "two", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "one", first.path(percentEncoded: false), in: shop)
            try await git("worktree", "add", "-q", "-b", "two", second.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let hasBothPorts = await eventually {
                text(of: first.appending(path: "port.txt")) != nil && text(of: second.appending(path: "port.txt")) != nil
            }

            #expect(hasBothPorts)
            #expect(text(of: first.appending(path: "port.txt")) != text(of: second.appending(path: "port.txt")))
            #expect(await runningProcesses(engine).count == 2)
        }
    }

    @Test func aWorkspaceThatIsNotIsolatedRunsNoProcess() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.state = .notIsolated("The connection main is fixed.") }
            await engine.syncBackgroundProcesses().value

            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func theSwitchOfASiteStopsAndStartsTheProcessesOfItsWorkspaces() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceProcesses: false)))
            try await settle(engine)
            #expect(await runningProcesses(engine).isEmpty)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceProcesses: true)))
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aRetryStartsAProcessAgain() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let first = try #require(await processNumber(engine))

            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(await processNumber(engine) != nil)
            #expect(await processNumber(engine) != first)
        }
    }

    @Test func aNewListStartsItsCommandsAndGivesANewPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let list = ["  ", "echo {port:scout} > port.txt; exec sleep 301", "echo {port:scout} > port.txt; exec sleep 301"]
            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(backgroundCommands: list)))
            try await settle(engine)

            let port = try #require(try await record(engine, of: shop).ports["scout"])

            #expect(await runningProcesses(engine) == ["echo \(port) > port.txt; exec sleep 301"])
            #expect(await eventually { text(of: worktree.appending(path: "port.txt")) == "\(port)\n" })
        }
    }

    @Test func aRemovalEndsTheProcessesAtOnceAndARefusedRemovalStartsThemAgain() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let removalRuns = Mutex(false)

        await engine.useWorktreeRemovalCheck { removalRuns.withLock { $0 } }

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let first = try #require(await processNumber(engine))

            removalRuns.withLock { $0 = true }
            try writeFile("", to: "deleted.txt", in: worktree)

            #expect(await eventually { await runningProcesses(engine).isEmpty })
            #expect(await eventually { kill(first, 0) != 0 })

            await engine.syncBackgroundProcesses().value
            #expect(await runningProcesses(engine).isEmpty)

            removalRuns.withLock { $0 = false }

            #expect(await eventually { await runningProcesses(engine).count == 1 })
        }
    }

    @Test func aChangeInAWorktreeWithoutARemovalKeepsItsProcesses() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let checks = Mutex(0)

        await engine.useWorktreeRemovalCheck {
            checks.withLock { $0 += 1 }
            return false
        }

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let first = await processNumber(engine)

            try writeFile("", to: "new.txt", in: worktree)

            #expect(await eventually { checks.withLock { $0 } > 0 })
            #expect(first != nil)
            #expect(await processNumber(engine) == first)
        }
    }

    @Test func aRemovalThatDeletedTheGitFileStartsNoProcessesAgain() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let removalRuns = Mutex(false)

        await engine.useWorktreeRemovalCheck { removalRuns.withLock { $0 } }

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            removalRuns.withLock { $0 = true }
            try writeFile("", to: "deleted.txt", in: worktree)

            #expect(await eventually { await runningProcesses(engine).isEmpty })

            try FileManager.default.removeItem(at: worktree.appending(path: ".git"))
            removalRuns.withLock { $0 = false }

            #expect(await eventually { await engine.removingWorktrees.isEmpty })
            try await settle(engine)
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aChangeDeepInAWorktreeGivesACheck() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let checks = Mutex(0)

        try FileManager.default.createDirectory(at: root.appending(path: "shop/storage/logs"), withIntermediateDirectories: true)
        try writeFile("", to: "storage/logs/.keep", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "logs", in: shop)

        await engine.useWorktreeRemovalCheck {
            checks.withLock { $0 += 1 }
            return false
        }

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await Task.sleep(for: .milliseconds(300))

            checks.withLock { $0 = 0 }
            try writeFile("line", to: "storage/logs/laravel.log", in: worktree)

            #expect(await eventually { checks.withLock { $0 } > 0 })
        }
    }

    @Test func aStopOfTheProcessesEndsTheWatchOfTheirWorktrees() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            #expect(await engine.worktreeWatchers.count == 1)

            await engine.stopBackgroundProcesses()

            #expect(await engine.worktreeWatchers.isEmpty)
        }
    }

    @Test func aMainCheckoutOfASiteInALinkedWorktreeGetsAWatch() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let linked = root.appending(path: "linked", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "linked", linked.path(percentEncoded: false), in: shop)

        var state = EngineState()
        state.sites = [Site(host: "linked.test", folder: linked, php: "8.4", backgroundCommands: ["exec sleep 300"], mainProcesses: true)]
        let engine = try makeSiteEngine(root: root, state: state, processSupervisor: ProcessSupervisor())

        try await whileRunning(engine) {
            try await settle(engine)

            #expect(await engine.worktreeWatchers.keys.sorted() == [RealPath.of(linked)])
        }
    }

    @Test func aRefusedRemovalLeavesNoRecheck() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let removalRuns = Mutex(true)

        await engine.useWorktreeRemovalCheck { removalRuns.withLock { $0 } }

        try await whileRunning(engine) {
            let removal = Task { await engine.worktreeChanged("/work/fix") }

            #expect(await eventually { await engine.removingWorktrees.contains("/work/fix") })

            await engine.worktreeChanged("/work/fix")
            removalRuns.withLock { $0 = false }
            await removal.value

            #expect(await engine.recheckWorktrees.isEmpty)
        }
    }

    @Test func aChangeDuringTheSyncAfterARemovalGetsItsOwnCheck() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let removalRuns = Mutex(true)
        let (release, releaseSync) = AsyncStream<Void>.makeStream()

        await engine.useWorktreeRemovalCheck { removalRuns.withLock { $0 } }
        await engine.holdProcessSync(until: release)

        try await whileRunning(engine) {
            let removal = Task { await engine.worktreeChanged("/work/fix") }

            #expect(await eventually { await engine.removingWorktrees.contains("/work/fix") })

            removalRuns.withLock { $0 = false }

            #expect(await eventually { await engine.removingWorktrees.isEmpty })
            #expect(await engine.checkingWorktrees.isEmpty)

            releaseSync.finish()
            await removal.value
        }
    }

    private func removes(_ worktree: String, _ arguments: String...) -> Bool {
        NexusEngine.removes(worktree, arguments: arguments)
    }

    @Test func eachOptionOfGitBeforeItsSubcommandCounts() {
        #expect(removes("/work/fix", "git", "-P", "worktree", "remove", "fix"))
        #expect(removes("/work/fix", "git", "--paginate", "--literal-pathspecs", "worktree", "remove", "fix"))
        #expect(removes("/work/fix", "/usr/bin/git", "-C", "/Users/me/My Work/shop", "worktree", "remove", "fix"))
        #expect(removes("/work/fix", "git", "-c", "core.quotepath=false", "--git-dir=/work/.git", "worktree", "remove", "fix"))
        #expect(removes("/work/fix", "git", "--git-dir", "/work/.git", "worktree", "remove", "fix"))
        #expect(removes("/work/fix", "/Applications/Some App.app/Contents/bin/git", "worktree", "remove", "fix"))
    }

    @Test func onlyTheOptionsOfARemovalAreNoPartOfItsPath() {
        #expect(removes("/work/fix", "git", "worktree", "remove", "fix", "--force"))
        #expect(removes("/work/fix", "git", "worktree", "remove", "-f", "-f", "--", "fix"))
        #expect(removes("/work/fix -2", "git", "worktree", "remove", "--force", "/work/fix -2"))
        #expect(!removes("/work/fix", "git", "worktree", "remove", "../fix -2"))
    }

    @Test func aShortFormOfAnOptionIsNoPartOfThePath() {
        #expect(removes("/work/fix", "git", "worktree", "remove", "fix", "--forc"))
        #expect(removes("/work/fix", "git", "worktree", "remove", "fix", "-fff"))
        #expect(removes("/work/fix", "git", "worktree", "remove", "fix", "--"))
        #expect(removes("/work/-fix", "git", "worktree", "remove", "--", "-fix"))
    }

    @Test func aNameOfARemovalIgnoresUpperAndLowerCase() {
        #expect(removes("/work/Fix", "git", "worktree", "remove", "../fix"))
        #expect(!removes("/work/Fix", "git", "worktree", "remove", "../other"))
    }

    @Test func aFullPathOfARemovalCountsOnlyForThatWorktree() {
        #expect(removes("/work/shop/fix", "git", "worktree", "remove", "/work/shop/fix/"))
        #expect(!removes("/work/shop/fix", "git", "worktree", "remove", "--force", "/work/blog/fix"))
    }

    @Test func onlyAWorktreeRemovalOfGitCounts() {
        let worktree = "/work/fix"

        #expect(removes(worktree, "git", "worktree", "remove", "--force", "/work/fix"))
        #expect(!removes(worktree, "git", "worktree", "list", "--porcelain"))
        #expect(!removes(worktree, "git", "worktree", "removed", "fix"))
        #expect(!removes(worktree, "git", "worktree", "remove"))
        #expect(!removes(worktree, "git", "commit", "-m", "worktree remove fix"))
        #expect(!removes(worktree, "git", "-C", "/work/shop", "grep", "worktree remove fix"))
        #expect(!removes(worktree, "git", "-C"))
        #expect(!removes(worktree))
    }

    @Test func aWorktreeRemovalCountsOnlyForTheWorktreeOfThatCommand() {
        #expect(removes("/work/fix", "git", "worktree", "remove", "../fix/"))
        #expect(removes("/Users/me/My Work/fix  one", "git", "worktree", "remove", "--force", "/Users/me/My Work/fix  one"))
        #expect(!removes("/work/other", "git", "worktree", "remove", "--force", "/work/fix"))
        #expect(removes("/work/fix", "git", "worktree", "remove", "."))
        #expect(removes("/work/fix", "git", "worktree", "remove", "../.."))
    }

    @Test func aRemovalDeletesTheCacheThatViteWroteDuringTheDeleteOfGit() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try writeFile("{}", to: ".vite/deps/_metadata.json", in: worktree)
            try await settle(engine)

            #expect(!FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false)))
        }
    }

    @Test func aRemovalKeepsAFolderWithAFileOfTheUser() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try writeFile("{}", to: ".vite/deps/_metadata.json", in: worktree)
            try writeFile("notes", to: "notes.txt", in: worktree)
            try await settle(engine)

            #expect(text(of: worktree.appending(path: "notes.txt")) == "notes")
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".vite").path(percentEncoded: false)))
        }
    }

    @Test func aWorktreeOfARemovedSiteKeepsItsViteCache() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try writeFile("{}", to: ".vite/deps/_metadata.json", in: worktree)

            _ = await engine.handle(.removeSite(host: "shop.test"))
            try await settle(engine)

            #expect(text(of: worktree.appending(path: ".vite/deps/_metadata.json")) == "{}")
        }
    }

    @Test func aWorkspaceKeepsAPortThatItsListLost() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["echo {port:reverb}; exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let port = try #require(try await record(engine, of: shop).ports["reverb"])

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(backgroundCommands: [])))
            try await settle(engine)

            #expect(try await record(engine, of: shop).ports["reverb"] == port)
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func stopAllServicesWithNoServiceThatRunsStopsTheProcessesUntilAServiceStarts() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)

            #expect(await engine.handle(.stopAll) == .done(message: "No service runs."))
            try await settle(engine)
            #expect(await runningProcesses(engine).isEmpty)

            _ = await engine.handle(.start(service: NexusEngine.dnsServiceID))
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aProcessThatKeepsStoppingShowsAWarningUntilItsListChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let policy = RestartPolicy(firstDelay: .milliseconds(10), maximumDelay: .milliseconds(20), stableAfter: .seconds(60), maximumQuickRestarts: 2, stopTimeout: .seconds(2))
        let engine = try await engineWithProcesses(["exit 3"], root: root, shop: shop, supervisor: ProcessSupervisor(policy: policy))
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let warned = await eventually {
                await workspaces(engine).first?.warnings?.contains { $0.contains("The background process exit 3 does not run.") } == true
            }

            #expect(warned)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(backgroundCommands: ["exec sleep 300"])))
            try await settle(engine)

            #expect(await eventually { await workspaces(engine).first?.warnings == [] })
            #expect(await runningProcesses(engine) == ["exec sleep 300"])
        }
    }

    @Test func aStartOfAServiceStartsAProcessAgainThatFailed() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let policy = RestartPolicy(firstDelay: .milliseconds(10), maximumDelay: .milliseconds(20), stableAfter: .seconds(60), maximumQuickRestarts: 2, stopTimeout: .seconds(2))
        let engine = try await engineWithProcesses(["test -f database.txt && exec sleep 300"], root: root, shop: shop, supervisor: ProcessSupervisor(policy: policy))
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(await eventually { await workspaces(engine).first?.warnings?.isEmpty == false })

            try writeFile("", to: "database.txt", in: worktree)
            _ = await engine.handle(.start(service: NexusEngine.dnsServiceID))
            try await settle(engine)

            #expect(await eventually { await runningProcesses(engine).count == 1 })
            #expect(await eventually { await workspaces(engine).first?.warnings == [] })
        }
    }

    @Test func aFailedProbeOfTheMainCheckoutWaitsUntilItsSwitchChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("<?php", to: "bootstrap/app.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4", mainProcesses: true)]
        let engine = try makeSiteEngine(root: root, state: state)
        let key = RealPath.of(shop)

        try await whileRunning(engine) {
            try await settle(engine)
            let first = try #require(await engine.mainProbeFailures[key]?.nextProbe)

            await engine.syncBackgroundProcesses().value

            let sites = await engine.handle(.sites)

            guard case .sites(let list) = sites else {
                Issue.record("No sites: \(sites)")
                return
            }

            #expect(await engine.mainProbeFailures[key]?.nextProbe == first)
            #expect(list.first?.processProblems?.first?.contains("PHP 8.4 is not installed") == true)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: true)))
            try await settle(engine)

            #expect(try #require(await engine.mainProbeFailures[key]?.nextProbe) > first)
        }
    }

    @Test func aProcessThatNeedsADatabaseGetsAWarningInAWorkspaceWithoutOne() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["dump {database}", "exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(await workspaces(engine).first?.warnings == ["The background process dump {database} needs a database, and fix has none."])
            #expect(await runningProcesses(engine) == ["exec sleep 300"])
        }
    }

    @Test func aRecordFromBeforeThisPartStartsNoProcessUntilItsNextSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try await engine.updateRecord(of: "fix", key: RealPath.of(shop)) { $0.backgroundPreset = nil }
            await engine.syncBackgroundProcesses().value
            #expect(await runningProcesses(engine).isEmpty)

            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func theMainCheckoutRunsTheListOnlyWithItsSwitchAndWithItsOwnPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["echo {workspace} {host} {port:web} > started.txt; exec sleep 300"], root: root, shop: shop)
        let started = shop.appending(path: "started.txt")

        try await whileRunning(engine) {
            #expect(await runningProcesses(engine).isEmpty)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: true)))
            try await settle(engine)

            #expect(await eventually { text(of: started)?.hasPrefix("main shop.test 20") == true })
            #expect(await runningProcesses(engine).count == 1)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: false)))
            try await settle(engine)

            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func theMainCheckoutKeepsItsProcessAndItsPortAfterAChangeOfTheOtherSwitch() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let listener = "echo {port:web} > port.txt; exec /usr/bin/nc -l 127.0.0.1 {port:web}"
        let engine = try await engineWithProcesses([listener], root: root, shop: shop)
        let portFile = shop.appending(path: "port.txt")

        try await whileRunning(engine) {
            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: true)))
            try await settle(engine)

            let first = try #require(await processNumber(engine))
            let listens = await eventually {
                text(of: portFile).flatMap { Int($0.trimmingCharacters(in: .newlines)) }.map { !PortInspector.isFree($0) } == true
            }

            #expect(listens)

            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceProcesses: false)))
            try await settle(engine)

            #expect(await processNumber(engine) == first)
        }
    }

    @Test func aProcessThatDoesNotStartShowsItsReason() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        try await FileManager.default.createDirectory(at: engine.paths.log("main-shop.test"), withIntermediateDirectories: true)

        try await whileRunning(engine) {
            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: true)))
            try await settle(engine)

            guard case .sites(let sites) = await engine.handle(.sites) else {
                Issue.record("no site list")
                return
            }

            #expect(sites.first?.processProblems?.first?.hasPrefix("The background process exec sleep 300 does not run.") == true)
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aProcessGetsTheHostOfTheSetupWhenTheFirstSiteHasItsSwitchOff() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [
            Site(host: "alpha.test", folder: shop, php: "8.4", workspaceProcesses: false),
            Site(host: "beta.test", folder: shop, php: "8.4", backgroundCommands: ["echo {host} > host.txt; exec sleep 300"]),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(await eventually { text(of: worktree.appending(path: "host.txt")) == "alpha-fix.test\n" })
        }
    }

    @Test func stopAllServicesStopsTheProcessesUntilTheServicesStartAgain() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            try await engine.stateStore.update { $0.stoppedByStopAll = [NexusEngine.dnsServiceID] }
            await engine.syncBackgroundProcesses().value
            #expect(await runningProcesses(engine).isEmpty)

            try await engine.stateStore.update { $0.stoppedByStopAll = [] }
            await engine.syncBackgroundProcesses().value
            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aRememberedServiceThatRunsOrThatIsGoneDoesNotHoldBackTheProcesses() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            _ = await engine.handle(.start(service: NexusEngine.dnsServiceID))
            try await settle(engine)

            try await engine.stateStore.update { $0.stoppedByStopAll = [NexusEngine.dnsServiceID, "redis-8.2"] }
            await engine.syncBackgroundProcesses().value

            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aStopOfNexusdEndsTheProcesses() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        let process = await processNumber(engine)

        await engine.shutdown()
        await engine.syncBackgroundProcesses().value

        #expect(process != nil)
        #expect(await runningProcesses(engine).isEmpty)
    }

    @Test func aNewStartEndsTheProcessesThatACrashLeft() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let sleeper = root.appending(path: "sleeper")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: sleeper)
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/codesign"), arguments: ["-f", "-s", "-", sleeper.path(percentEncoded: false)]))
        let crashed = try await engineWithProcesses(["exec \(sleeper.path(percentEncoded: false)) 300"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(crashed) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(crashed)
            let orphan = try #require(await processNumber(crashed))

            await crashed.endProcessesOfEarlierRun()

            #expect(await eventually { await processNumber(crashed) != orphan })
            #expect(kill(orphan, 0) != 0)
        }
    }

    @Test func aRunOfAnotherRootKeepsItsProcesses() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let running = try await engineWithProcesses(["exec sleep 300"], root: root, shop: shop)
        let other = try makeSiteEngine(root: root.appending(path: "other", directoryHint: .isDirectory))
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(running) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(running)
            let process = try #require(await processNumber(running))

            await other.endProcessesOfEarlierRun()

            #expect(kill(process, 0) == 0)
        }
    }

    @Test func twoSitesOfAProjectRunACommandOneTime() {
        let folder = URL(filePath: "/work/shop", directoryHint: .isDirectory)
        let sites = [
            Site(host: "shop.test", folder: folder, php: "8.4"),
            Site(host: "store.test", folder: folder, php: "8.4", backgroundCommands: ["php artisan queue:work", "npm run dev"]),
        ]

        #expect(NexusEngine.backgroundCommands(of: sites, preset: ["php artisan queue:work"]) == ["php artisan queue:work", "npm run dev"])
    }

    private func reverbApplication(in root: URL, ignoring ignored: String) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ignored)
        try writeFile(#"<?php return ['default' => env('QUEUE_CONNECTION', 'sync'), 'connections' => ['sync' => ['driver' => 'sync'], 'database' => ['driver' => 'database']]];"#, to: "config/queue.php", in: shop)
        try writeFile(#"<?php return ['default' => env('BROADCAST_CONNECTION', 'null'), 'connections' => ['reverb' => ['driver' => 'reverb', 'options' => ['port' => env('REVERB_PORT', 443)]]]];"#, to: "config/broadcasting.php", in: shop)
        try writeFile(#"<?php return ['default' => 'reverb', 'servers' => ['reverb' => ['port' => env('REVERB_SERVER_PORT', 8080)]], 'apps' => ['apps' => [['options' => ['port' => env('REVERB_PORT', 443)]]]]];"#, to: "config/reverb.php", in: shop)
        try writeFile("export default {};\n", to: "vite.config.js", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "processes", in: shop)
        try writeFile("", to: "database/database.sqlite", in: shop)

        let database = "DB_DATABASE=\(RealPath.of(shop.appending(path: "database")))/database.sqlite\n"
        try writeFile("\(database)QUEUE_CONNECTION=database\nBROADCAST_CONNECTION=reverb\nREVERB_PORT=8080\nVITE_REVERB_PORT=8080\n", to: ".env", in: shop)
        try await engine.stateStore.update { $0.sites[0].workspaceProcesses = false }
        return (shop, engine, worktree)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsThePresetOfItsApplicationAndAPortForReverb() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await reverbApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n/public/build/\n/public/hot\n")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let preset = ["php artisan queue:work", "php artisan schedule:work", "php artisan reverb:start --port={port:reverb}", "npm run dev -- --port {port:vite} --strictPort"]
            let workspace = try await record(engine, of: shop)
            let port = try #require(workspace.ports["reverb"])
            let env = try #require(text(of: worktree.appending(path: ".env")))
            let preview = await engine.handle(.workspaceEnv(host: "shop.test"))

            #expect(workspace.state == .ready)
            #expect(workspace.backgroundPreset == preset)
            #expect(workspace.ports["vite"] != nil)
            #expect(await engine.handle(.backgroundPreset(host: "shop.test")) == .backgroundPreset(preset))
            #expect(env.contains("REVERB_PORT=\(port)\n"))
            #expect(env.contains("REVERB_SERVER_PORT=\(port)\n"))
            #expect(env.contains("VITE_REVERB_PORT=\(port)\n"))
            #expect(text(of: shop.appending(path: ".env"))?.contains("REVERB_PORT=8080\n") == true)

            guard case .workspaceEnv(let keys) = preview else {
                Issue.record("No keys: \(preview)")
                return
            }

            #expect(keys.contains(WorkspaceEnvKey(key: "REVERB_PORT", value: "{port:reverb}")))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealPresetLeavesOutViteWhenGitSeesWhatItWrites() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, engine, _) = try await reverbApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n/public/hot\n")

        try await whileRunning(engine) {
            try await settle(engine)

            let preset = await engine.handle(.backgroundPreset(host: "shop.test"))

            #expect(preset == .backgroundPreset(["php artisan queue:work", "php artisan schedule:work", "php artisan reverb:start --port={port:reverb}"]))
        }
    }

    @Test func aDifferentYarnLockFileGivesAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try writeFile("one", to: "yarn.lock", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "lock", in: shop)
        try await git("branch", "fix", in: shop)
        try await git("checkout", "-q", "fix", in: shop)
        try writeFile("two", to: "yarn.lock", in: shop)
        try await git("commit", "-q", "-am", "other lock", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)

        try await git("worktree", "add", "-q", root.appending(path: "fix").path(percentEncoded: false), "fix", in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(warnings == ["yarn.lock is different from the main checkout, so node_modules can be out of date. Run the install in the worktree."])
    }

    @Test func aCloneChangesAloneFromTheMainCheckout() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        try writeFile("changed", to: "storage/app/uploads/a.txt", in: worktree)

        #expect(try String(contentsOf: shop.appending(path: "storage/app/uploads/a.txt"), encoding: .utf8) == "uploaded")
    }

    @Test func theStorageLinkOfAWorkspaceDoesNotLeadToTheMainCheckout() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let link = worktree.appending(path: "public/storage").path(percentEncoded: false)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "../storage/app/public")
    }

    @Test func aPathBehindALinkOfTheWorktreeLeavesTheOtherClones() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try writeFile("vendor\n/public/assets/*.js\n", to: ".gitignore", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shop.appending(path: "public/assets").path(percentEncoded: false), withDestinationPath: "../shared")
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "link", in: shop)
        let older = try await gitOutput("rev-parse", "HEAD", in: shop)
        try FileManager.default.removeItem(at: shop.appending(path: "public/assets"))
        try writeFile("kept", to: "public/assets/.gitkeep", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "folder", in: shop)
        try writeFile("one", to: "public/assets/a.js", in: shop)
        try writeFile("<?php", to: "vendor/autoload.php", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), older, in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "vendor/autoload.php").path(percentEncoded: false)))
        #expect(warnings == ["git does not ignore public/assets/a.js in this worktree, so Nexus does not clone it."])
    }

    @Test func aLockFileGivesNoInstallWhenGitDoesNotIgnoreItsFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let older = try await gitOutput("rev-parse", "HEAD", in: shop)
        try await git("checkout", "-q", "-b", "fix", older, in: shop)
        try writeFile("branch", to: "composer.lock", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "lock of the branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try writeFile("vendor\n", to: ".gitignore", in: shop)
        try writeFile("main", to: "composer.lock", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "lock of main", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)

        try await git("worktree", "add", "-q", root.appending(path: "fix").path(percentEncoded: false), "fix", in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(warnings == ["vendor does not fit composer.lock, and git does not ignore vendor/ in this worktree. So Nexus runs no install."])
    }

    @Test func aLinkToAFolderOutsideTheProjectGivesAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let link = shop.appending(path: "public/storage").path(percentEncoded: false)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nexus-shared/uploads")
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let workspace = await workspaces(engine).first

        #expect(workspace?.warnings == ["public/storage is a link to a folder outside the project, so Nexus does not clone it."])
        #expect(workspace?.state == .ready)
    }

    @Test func aSecondSetupKeepsWhatAWorkspaceChanged() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        try writeFile("changed", to: "vendor/autoload.php", in: worktree)

        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(try String(contentsOf: worktree.appending(path: "vendor/autoload.php"), encoding: .utf8) == "changed")
    }

    @Test func aFolderWithAStarPatternGetsItsFiles() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try writeFile("/vendor/*\n/dist/*\n!/dist/.gitkeep\n", to: ".gitignore", in: shop)
        try writeFile("kept", to: "dist/.gitkeep", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "ignore", in: shop)
        try writeFile("<?php", to: "vendor/acme/file.php", in: shop)
        try writeFile("built", to: "dist/app.js", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "vendor/acme/file.php").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "dist/app.js").path(percentEncoded: false)))
        #expect(warnings == [])
        #expect(try await gitOutput("status", "--porcelain", in: worktree).isEmpty)
    }

    @Test func aPathThatTheBranchOfTheWorktreeDoesNotIgnoreGivesAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await applicationWithFiles(in: root)
        let older = try await gitOutput("rev-parse", "HEAD", in: shop)
        try writeFile("vendor\nnode_modules\n/public/build\n/public/hot\n/public/storage\n/bootstrap/cache/*\n.env\ndist\n", to: ".gitignore", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "dist", in: shop)
        try writeFile("built", to: "dist/app.js", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), older, in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(warnings == ["git does not ignore dist/ in this worktree, so Nexus does not clone it."])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "dist").path(percentEncoded: false)))
        #expect(try await gitOutput("status", "--porcelain", in: worktree).isEmpty)
    }

    private func applicationWithLockFiles(in root: URL, tool: (name: String, line: String), lockFile: String, main: String, branch: String, composer: String = #"{"name":"shop/app","version":"1.0.0"}"#) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let shop = try await repository(in: root)
        try writeFile("vendor\nnode_modules\n", to: ".gitignore", in: shop)
        try writeFile(composer, to: "composer.json", in: shop)
        try writeFile(#"{"name":"app","version":"1.0.0"}"#, to: "package.json", in: shop)
        try writeFile(main, to: lockFile, in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "locks", in: shop)
        try await git("branch", "fix", in: shop)
        try await git("checkout", "-q", "fix", in: shop)
        try writeFile(branch, to: lockFile, in: shop)
        try await git("commit", "-q", "--allow-empty", "-am", "other lock", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try writeFile("from the main checkout", to: "vendor/marker", in: shop)
        try writeFile("from the main checkout", to: "node_modules/marker", in: shop)

        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await link(tool, in: engine)
        return (shop, engine, root.appending(path: "fix", directoryHint: .isDirectory))
    }

    private static let composerLock = #"{"content-hash":"none","packages":[],"packages-dev":[],"aliases":[],"minimum-stability":"stable","stability-flags":{},"prefer-stable":false,"prefer-lowest":false,"platform":{},"platform-dev":{},"plugin-api-version":"2.6.0"}"#
    private static let npmLock = #"{"name":"app","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"app","version":"1.0.0"}}}"#

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceRunsComposerOneTimeWhenItsLockFileIsDifferent() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("composer", "2"), lockFile: "composer.lock", main: Self.composerLock, branch: Self.composerLock + "\n")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let autoload = worktree.appending(path: "vendor/autoload.php").path(percentEncoded: false)

            #expect(await workspaces(engine).first?.warnings == [])
            #expect(FileManager.default.fileExists(atPath: autoload))

            try FileManager.default.removeItem(atPath: autoload)
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(!FileManager.default.fileExists(atPath: autoload))

            try FileManager.default.removeItem(at: worktree.appending(path: "vendor"))
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(FileManager.default.fileExists(atPath: autoload))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceRunsComposerWhenItsLockFileGoesBackToTheOneOfTheMainCheckout() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("composer", "2"), lockFile: "composer.lock", main: Self.composerLock, branch: Self.composerLock + "\n")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let autoload = worktree.appending(path: "vendor/autoload.php").path(percentEncoded: false)

            try FileManager.default.removeItem(atPath: autoload)
            try writeFile(Self.composerLock, to: "composer.lock", in: worktree)
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(FileManager.default.fileExists(atPath: autoload))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceRunsNpmCiWhenItsLockFileIsDifferent() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("node", "24"), lockFile: "package-lock.json", main: Self.npmLock, branch: Self.npmLock + "\n")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            #expect(await workspaces(engine).first?.warnings == [])
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "node_modules/marker").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWithTheSameLockFileRunsNoInstall() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("composer", "2"), lockFile: "composer.lock", main: Self.composerLock, branch: Self.composerLock)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "vendor/marker").path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "vendor/autoload.php").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealInstallThatFailsGivesAWarningAndAWorkspaceThatStaysReady() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await applicationWithLockFiles(in: root, tool: ("node", "24"), lockFile: "package-lock.json", main: Self.npmLock, branch: "no json")

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)

            #expect(workspace.state == .ready)
            #expect(workspace.warnings?.first?.hasPrefix("node_modules does not fit package-lock.json, and the install failed") == true)
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "node_modules/marker").path(percentEncoded: false)))
        }
    }

    private func writeFile(_ text: String, to path: String, in folder: URL) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func committedLaravelApplication(in root: URL, ignoring ignored: String) async throws -> URL {
        let shop = try await repository(in: root)
        try writeFile("", to: "artisan", in: shop)
        try writeFile("{}", to: "composer.json", in: shop)
        try writeFile(ignored, to: ".gitignore", in: shop)
        try writeFile(Self.bootstrapApp, to: "bootstrap/app.php", in: shop)
        try writeFile(#"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE', 'forge')],
            ],
            'redis' => [
                'default' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_DB', 0)],
            ],
        ];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "application", in: shop)
        try writeFile(Self.bootstrappers, to: "vendor/autoload.php", in: shop)
        return shop
    }

    private static let portOfTheConnectionCMS = "'cms' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306')"

    private func databaseConfig(driver: String) -> String {
        #"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE', 'forge')],
                'cms' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE_CMS', 'forge_cms')],
                'old' => ['driver' => '\#(driver)', 'host' => '127.0.0.1', 'port' => env('DB_PORT', '3306'), 'database' => env('DB_DATABASE_OLD', 'forge_old')],
            ],
        ];
        """#
    }

    private func engineWithDatabase(
        root: URL,
        shop: URL,
        runtime: (name: String, line: String),
        port: Int,
        host: String = "shop.test",
        keys: [WorkspaceEnvKey]? = nil,
        redisPort: Int? = nil
    ) async throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: host, folder: shop, php: "8.5", workspaceKeys: keys)]
        state.ports["\(runtime.name)-\(runtime.line)"] = port
        state.ports["redis-8.2"] = redisPort
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await link(runtime, in: engine)

        if redisPort != nil {
            try await link(("redis", "8.2"), in: engine)
        }

        return engine
    }

    private func link(_ runtime: (name: String, line: String), in engine: NexusEngine) async throws {
        let link = await engine.paths.runtime(runtime.name, line: runtime.line)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: "\(runtime.name)/\(runtime.line)"))
    }

    private func redisApplication(in root: URL, port: Int, env: String = "", installed: Bool = true) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(#"""
        <?php
        return [
            'default' => 'main',
            'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]],
            'redis' => [
                'default' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_DB', 0)],
                'cache' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_CACHE_DB', 1)],
            ],
        ];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "redis", in: shop)
        try writeFile("SESSION_DRIVER=redis\nREDIS_PORT=\(port)\n\(env)", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        state.ports[installed ? "redis-8.2" : "redis-8"] = port
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)

        if installed {
            try await link(("redis", "8.2"), in: engine)
        }

        return (shop, engine, root.appending(path: "fix", directoryHint: .isDirectory))
    }

    @discardableResult
    private func redis(_ engine: NexusEngine, index: Int, _ arguments: String...) async throws -> String {
        let instance = try #require(await engine.redisInstances().first)
        let command = Command(executable: instance.client, arguments: ["-p", String(instance.port), "-n", String(index)] + arguments)
        return try await CommandRunner.run(command).trimmed
    }

    private func record(_ engine: NexusEngine, of shop: URL) async throws -> Workspace {
        try #require(await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealCacheWriteInAWorkspaceIsNotInTheMainSiteAndTheRemovalEmptiesItsIndexes() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await redis(engine, index: 1, "SET", "price", "main")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)
            let cache = try #require(workspace.redisIndexes["REDIS_CACHE_DB"])
            let env = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

            #expect(workspace.state == .ready)
            #expect(workspace.redisInstances == ["redis-8.2"])
            #expect(workspace.redisIndexes == ["REDIS_CACHE_DB": 16, "REDIS_DB": 17])
            #expect(env.contains("REDIS_CACHE_DB=16\n"))

            try await redis(engine, index: cache, "SET", "price", "workspace")

            #expect(try await redis(engine, index: 1, "GET", "price") == "main")
            #expect(try await redis(engine, index: cache, "GET", "price") == "workspace")

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await redis(engine, index: cache, "DBSIZE") == "0")
            #expect(try await redis(engine, index: 1, "GET", "price") == "main")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceSkipsAnIndexWithKeysAndTheIndexesOfTheMainSite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort(), env: "REDIS_DB=16\n")

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await redis(engine, index: 17, "SET", "owner", "someone else")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 18, "REDIS_DB": 19])
            #expect(try await redis(engine, index: 17, "GET", "owner") == "someone else")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceStaysOffAnIndexInTheEnvFileOfAnotherSiteAndItsRemovalKeepsThatIndex() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        try writeFile("", to: "artisan", in: blog)
        try writeFile("", to: "bootstrap/app.php", in: blog)
        try writeFile("REDIS_CACHE_DB=16\n", to: ".env", in: blog)
        try await engine.stateStore.update { $0.sites.append(Site(host: "blog.test", folder: blog, php: "8.5")) }

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 17, "REDIS_DB": 18])

            try await redis(engine, index: 17, "SET", "price", "blog")
            try writeFile("REDIS_CACHE_DB=16\nREDIS_DB=17\n", to: ".env", in: blog)
            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await redis(engine, index: 17, "GET", "price") == "blog")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalKeepsAnIndexThatTheConfigurationOfTheMainSiteFixesNow() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await redis(engine, index: 16, "SET", "price", "main")
            try await redis(engine, index: 17, "SET", "price", "workspace")
            try writeFile(#"""
            <?php
            return [
                'default' => 'main',
                'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]],
                'redis' => [
                    'default' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => (int) env('REDIS_DB', 0)],
                    'cache' => ['port' => (int) env('REDIS_PORT', 6379), 'database' => 16],
                ],
            ];
            """#, to: "config/database.php", in: shop)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await redis(engine, index: 16, "GET", "price") == "main")
            #expect(try await redis(engine, index: 17, "DBSIZE") == "0")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalWithoutAProbeKeepsTheIndexesAndSaysWhy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await redis(engine, index: 16, "SET", "price", "workspace")
            try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let log = try String(contentsOf: await engine.paths.log("redis-8.2"), encoding: .utf8)

            #expect(try await redis(engine, index: 16, "GET", "price") == "workspace")
            #expect(log.contains("because it cannot read the configuration of the main site"))
            #expect(await engine.emptyingRedisIndexes.isEmpty)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceDoesNotGetAWriteThatACrashEnded() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n*.sqlite-wal\n*.sqlite-shm\n")
        let main = shop.appending(path: "database/database.sqlite").path(percentEncoded: false)
        try await sqlite(main, "CREATE TABLE orders(id);", "INSERT INTO orders VALUES (1);")
        let sizeBeforeTheCrash = fileSize(main)
        await crashDuringAWrite(to: main)
        #expect(fileSize(main) > sizeBeforeTheCrash)
        #expect(FileManager.default.fileExists(atPath: "\(main)-journal"))
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)

        #expect(await workspaces(engine).map(\.state) == [.ready])
        #expect(try await sqlite(clone, "SELECT COUNT(*) FROM orders;") == "1")
        #expect(try await sqlite(clone, "PRAGMA integrity_check;") == "ok")
        #expect(fileSize(clone) == sizeBeforeTheCrash)
        await engine.shutdown()
    }

    private func fileSize(_ file: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
    }

    // A small page cache with cache_spill makes sqlite3 write to the main file before the commit.
    // The last command kills sqlite3, so the commit does not come.
    private func crashDuringAWrite(to file: String) async {
        _ = try? await sqlite(
            file,
            "PRAGMA cache_spill=1;",
            "PRAGMA cache_size=1;",
            "BEGIN;",
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000) INSERT INTO orders SELECT i FROM n;",
            ".shell kill -9 $PPID"
        )
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceStaysOffAFixedIndexInTheConfigurationOfAnotherSite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        try writeFile("", to: "artisan", in: blog)
        try writeFile("", to: "bootstrap/app.php", in: blog)
        try writeFile("<?php return ['redis' => ['cache' => ['database' => 16]]];", to: "config/database.php", in: blog)
        try await engine.stateStore.update { $0.sites.append(Site(host: "blog.test", folder: blog, php: "8.5")) }

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 17, "REDIS_DB": 18])
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealSetupDoesNotChooseAnIndexThatNexusEmptiesNow() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            await engine.markAsEmptying([WorkspaceRedisIndex(instance: "redis-8.2", index: 16)])
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 17, "REDIS_DB": 18])
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalChangesTheServerBlocksBeforeRedisAnswers() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())
        let httpPort = freePort()
        let httpsPort = freePort()
        try await engine.stateStore.update { state in
            state.ports[ServiceCatalog.httpPortKey] = httpPort
            state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        }

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            let hasServerBlock = { await engine.appliedSites?.contains { $0.contains("shop-fix.test") } == true }
            #expect(await hasServerBlock())

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await redis(engine, index: 0, "CLIENT", "PAUSE", "5000", "ALL")
            let removal = Task { await engine.reconcileWorkspaces() }

            while await hasServerBlock() {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(await !engine.emptyingRedisIndexes.isEmpty)
            await removal.value
            try await settle(engine)
            #expect(await engine.emptyingRedisIndexes.isEmpty)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealSetupDuringAnUpdateOfItsInstanceIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            await engine.markAsUpdating("redis-8.2")
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("Nexus updates redis-8.2 now. Retry after the update."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealStopOfNexusdDuringASetupKeepsTheWorkspaceInPreparing() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try Data("APP_NAME=Caf".utf8 + [0xE9]).write(to: worktree.appending(path: ".env"))

            let setup = Task { await engine.reconcileWorkspaces() }

            while await engine.runningSetupKey == nil {
                try await Task.sleep(for: .milliseconds(1))
            }

            await engine.stopWatchingWorktrees()
            await setup.value

            while await engine.workspaceWorkRuns {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(try await record(engine, of: shop).state == .preparing)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealPostgreSQLThatTakesNoQueriesEndsTheWaitWithAnError() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        try await link(("postgresql", "17"), in: engine)
        let definition = ServiceDefinition(
            id: "postgresql-17",
            displayName: "PostgreSQL 17",
            executable: URL(filePath: "/usr/bin/true"),
            ports: [freePort()],
            logFile: await engine.paths.log("postgresql-17"),
            startTimeout: .milliseconds(200)
        )

        await #expect(throws: SupervisorError.self) {
            try await engine.waitForQueries("postgresql-17", definition)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealCloneUsesThePortOfTheRunningInstanceAfterAChangeOfThePort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let runningPort = freePort()
        let nextPort = freePort()
        try writeFile("DB_PORT=\(nextPort)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: runningPort)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: runningPort)
            try await client.query("CREATE DATABASE shop")
            _ = await engine.handle(.setPort(service: "mysql-8.4", port: nextPort))
            try await settle(engine)

            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(try await workspaceClient(engine, id: "mysql-8.4", of: shop).exists("shop"))
        }
    }

    @Test func aChangeOfTheWorktreesKeepsWhatASetupWroteDuringTheRunOfGit() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStateStore(paths: NexusPaths(root: root))
        let copy = WorkspaceDatabaseCopy(instance: "mysql-8.4", name: "shop_fix")
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")
        _ = try await store.updateWorktrees { _ in ["/w": SiteWorktrees(listed: ["/w/fix"], workspaces: [workspace])] }
        let listed = [Worktree(path: "/w/fix", branch: "fix")]

        try await store.update { $0.worktrees["/w"]?.workspaces[0].databases = [copy] }
        _ = try await store.updateWorktrees { known in
            ["/w": WorkspacePlanner.update(known["/w"], listed: listed, automatic: true, subfolder: "", excluded: [])]
        }

        let stored = await store.current().worktrees["/w"]?.workspaces.first

        #expect(stored?.databases == [copy])
        #expect(stored?.branch == "fix")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalRunsAStoppedRedisOnlyForTheEmptyStep() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await redis(engine, index: 16, "SET", "price", "workspace")
            _ = await engine.handle(.stop(service: "redis-8.2"))
            let before = await engine.stateStore.current()

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let after = await engine.stateStore.current()

            #expect(await engine.supervisor.state(of: "redis-8.2")?.isActive != true)
            #expect(after.enabledServices == before.enabledServices)
            #expect(after.stoppedByStopAll == before.stoppedByStopAll)

            _ = await engine.handle(.start(service: "redis-8.2"))

            #expect(try await redis(engine, index: 16, "DBSIZE") == "0")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRemovalWithABusyPortKeepsTheIndexAndShowsNoPortConflict() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let (shop, engine, worktree) = try await redisApplication(in: root, port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            _ = await engine.handle(.stop(service: "redis-8.2"))
            let listener = try listen(on: port)
            defer { close(listener) }

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(await engine.portConflicts["redis-8.2"] == nil)
            #expect(await engine.supervisor.state(of: "redis-8.2")?.isActive != true)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealSetupAfterStopAllKeepsTheServiceInTheStopAllList() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            _ = await engine.handle(.stopAll)
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(await engine.supervisor.state(of: "redis-8.2")?.isActive == true)
            #expect(await engine.stateStore.current().stoppedByStopAll.contains("redis-8.2"))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWithoutAFreeRedisIndexIsNotIsolatedAndHasNoEnvFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())
        let indexes = Dictionary(uniqueKeysWithValues: (16..<ServiceCatalog.redisDatabaseCount).map { ("KEY_\($0)", $0) })
        let other = Workspace(name: "other", worktree: "/nexus-missing/other", folder: "/nexus-missing/other", state: .ready, redisIndexes: indexes)
        try await engine.stateStore.update { $0.worktrees["/nexus-missing"] = SiteWorktrees(workspaces: [other]) }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            #expect(workspace.state == .notIsolated("Redis has no free index for this workspace. Remove a workspace, and then retry."))
            #expect(workspace.redisIndexes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRedisThatNexusCannotStartGivesAWorkspaceThatIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let (shop, engine, worktree) = try await redisApplication(in: root, port: port)
        let listener = try listen(on: port)
        defer { close(listener) }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try await record(engine, of: shop)

            guard case .notIsolated = workspace.state else {
                Issue.record("The workspace is \(workspace.state).")
                return
            }

            #expect(workspace.redisIndexes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealPortOfARemovedRedisIsNoNexusInstance() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort(), installed: false)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("The Redis connection default does not use a Nexus Redis instance. The Redis connection cache does not use a Nexus Redis instance."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRetryEmptiesAnIndexThatTheWorkspaceNoLongerUses() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try await redis(engine, index: 16, "SET", "price", "workspace")
            try await redis(engine, index: 30, "SET", "price", "old")
            try await engine.stateStore.update { state in
                state.worktrees[RealPath.of(shop)]?.workspaces[0].redisIndexes["OLD_KEY"] = 30
            }

            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 16, "REDIS_DB": 17])
            #expect(try await redis(engine, index: 30, "DBSIZE") == "0")
            #expect(try await redis(engine, index: 16, "GET", "price") == "workspace")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRetryGivesUpAnIndexThatTheMainSiteUsesNowAndKeepsItsKeys() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let (shop, engine, worktree) = try await redisApplication(in: root, port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            try writeFile("SESSION_DRIVER=redis\nREDIS_PORT=\(port)\nREDIS_CACHE_DB=16\n", to: ".env", in: shop)
            try await redis(engine, index: 16, "SET", "price", "main")

            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).redisIndexes == ["REDIS_CACHE_DB": 18, "REDIS_DB": 17])
            #expect(try await redis(engine, index: 16, "GET", "price") == "main")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealRunningRedisKeepsItsPortUntilARestart() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let (_, engine, _) = try await redisApplication(in: root, port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await engine.stateStore.update { $0.ports["redis-8.2"] = port + 1 }

            #expect(try await engine.redisInstances().map(\.port) == [port])
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealCloneOfASQLiteFileRemovesAnOldWriteAheadFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n*.sqlite-wal\n*.sqlite-shm\n")
        try await sqlite(shop.appending(path: "database/database.sqlite").path(percentEncoded: false), "CREATE TABLE orders(id);")
        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite")
        let oldWriteAheadFile = worktree.appending(path: "database/database.sqlite-wal")
        try FileManager.default.removeItem(at: clone)
        try Data("old".utf8).write(to: oldWriteAheadFile)

        _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: oldWriteAheadFile.path(percentEncoded: false)))
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealIndexThatDoesNotExistLeavesTheIndexOfTheMainSite() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, engine, _) = try await redisApplication(in: root, port: freePort())

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "redis-8.2"))
            try await redis(engine, index: 0, "SET", "price", "main")

            await engine.emptyRedisIndexes([WorkspaceRedisIndex(instance: "redis-8.2", index: ServiceCatalog.redisDatabaseCount)])

            let log = try String(contentsOf: await engine.paths.log("redis-8.2"), encoding: .utf8)

            #expect(try await redis(engine, index: 0, "GET", "price") == "main")
            #expect(log.contains("Nexus could not empty the Redis indexes [256]."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsTheLastChangesOfASQLiteFileInWriteAheadMode() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n*.sqlite-wal\n*.sqlite-shm\n")
        let main = shop.appending(path: "database/database.sqlite").path(percentEncoded: false)
        try await sqlite(main, ".dbconfig no_ckpt_on_close on", "PRAGMA journal_mode=WAL;", "CREATE TABLE orders(id);", "INSERT INTO orders VALUES (1);")
        let writeAheadFile = try Data(contentsOf: URL(filePath: "\(main)-wal"))
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)

        #expect(await workspaces(engine).map(\.state) == [.ready])
        #expect(try await sqlite(clone, "SELECT COUNT(*) FROM orders;") == "1")
        #expect(try Data(contentsOf: URL(filePath: "\(main)-wal")) == writeAheadFile)
        await engine.shutdown()
    }

    @discardableResult
    private func sqlite(_ file: String, _ commands: String...) async throws -> String {
        try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/sqlite3"), arguments: [file] + commands)).trimmed
    }

    @Test func theKeyspaceOfRedisGivesTheIndexesWithKeys() {
        let text = "# Keyspace\r\ndb0:keys=4,expires=0,avg_ttl=0,subexpiry=0\r\ndb17:keys=1,expires=1,avg_ttl=9,subexpiry=0\r\n"

        #expect(NexusEngine.indexes(inKeyspace: text) == [0, 17])
    }

    @Test func aChangeOfTheWorktreesNamesTheWorkspacesThatWentAway() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStateStore(paths: NexusPaths(root: root))
        let staying = Workspace(name: "staying", worktree: "/w/staying", folder: "/w/staying")
        let leaving = Workspace(name: "leaving", worktree: "/w/leaving", folder: "/w/leaving")
        let otherSite = Workspace(name: "other", worktree: "/o/other", folder: "/o/other")
        _ = try await store.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [staying, leaving]), "/o": SiteWorktrees(workspaces: [otherSite])] }

        let change = try await store.updateWorktrees { _ in ["/w": SiteWorktrees(workspaces: [staying])] }

        #expect(change.changed)
        #expect(change.removed == ["/w": [leaving], "/o": [otherSite]])
    }

    private func databaseClient(_ engine: NexusEngine, id: String, port: Int) async throws -> DatabaseClient {
        let tools = try #require(await engine.databaseRuntime(id))
        let work = await engine.paths.run.appending(path: "test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let client = DatabaseClient(tools: tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: port, account: .newInstance), options: work.appending(path: "client-\(port).cnf"))
        try client.prepare()
        return client
    }

    private func workspaceClient(_ engine: NexusEngine, id: String, of shop: URL) async throws -> DatabaseClient {
        let server = try #require(try await record(engine, of: shop).servers.first { $0.instance == id })

        return try await databaseClient(engine, id: id, port: server.port)
    }

    private func digest(_ client: DatabaseClient, _ database: String) async throws -> String {
        let sql = client.tools.kind.usesMySQLProtocol
            ? "SELECT GROUP_CONCAT(id, name ORDER BY id) FROM items"
            : "SELECT string_agg(id::text || name, ',' ORDER BY id) FROM items"

        return try await client.query(sql, database: database)
    }

    static let everyDatabaseVersion: [(String, String, String)] = [
        ("mysql", "8.0", "mysql"), ("mysql", "8.4", "mysql"), ("mysql", "9.7", "mysql"),
        ("mariadb", "10.11", "mariadb"), ("mariadb", "11.4", "mariadb"), ("mariadb", "11.8", "mariadb"), ("mariadb", "12.3", "mariadb"),
        ("postgresql", "14", "pgsql"), ("postgresql", "15", "pgsql"), ("postgresql", "16", "pgsql"), ("postgresql", "17", "pgsql"), ("postgresql", "18", "pgsql"),
    ]

    // A Mac or a CI run has only some of these versions.
    private func isInstalled(_ name: String, _ line: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(Self.realRuntimes ?? "")/\(name)/\(line)")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: everyDatabaseVersion)
    func aRealWorkspaceGetsAServerWithEachDatabaseAndTheMainDatabasesStayTheSame(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(databaseConfig(driver: driver), to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "connections", in: shop)
        let id = "\(name)-\(line)"
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\nDB_DATABASE_CMS=shop_cms\nDB_DATABASE_OLD=not_here\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: (name, line), port: port)
        var mainBefore: [String] = []
        var mainAfter: [String] = []
        var copies: [String] = []
        var rowAfterRetry: String?
        var rowsOnMain: String?
        var workspace: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            let client = try await databaseClient(engine, id: id, port: port)

            for database in ["shop", "shop_cms"] {
                try await client.query("CREATE DATABASE \(database)")
                try await client.query("CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(20))", database: database)
                try await client.query("INSERT INTO items VALUES (1, 'one'), (2, '\(database)')", database: database)
                mainBefore.append(try await digest(client, database))
            }

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            let own = try await workspaceClient(engine, id: id, of: shop)

            for database in ["shop", "shop_cms"] {
                copies.append(try await digest(own, database))
                mainAfter.append(try await digest(client, database))
            }

            try await own.query("INSERT INTO items VALUES (3, 'workspace')", database: "shop")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            rowAfterRetry = try await own.query("SELECT name FROM items WHERE id = 3", database: "shop")
            rowsOnMain = try await client.query("SELECT COUNT(*) FROM items WHERE id = 3", database: "shop")
            workspace = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first
        }

        #expect(workspace?.state == .ready)
        #expect(workspace?.databases.map(\.name) == ["shop", "shop_cms", "not_here"])
        #expect(workspace?.servers.map(\.instance) == [id])
        #expect(copies == mainBefore)
        #expect(rowsOnMain?.hasSuffix("0") == true)
        #expect(mainAfter == mainBefore)
        #expect(rowAfterRetry == "workspace")
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealRetryMakesACloneAgainThatDidNotEnd() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        let key = RealPath.of(shop)
        var first, second: WorkspaceDatabaseServer?
        var finished: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            let store = await engine.stateStore

            first = try await record(engine, of: shop).servers.first
            try await store.update { state in
                state.worktrees[key]?.workspaces[0].servers[0].isComplete = false
            }
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            finished = await store.current().worktrees[key]?.workspaces.first
            second = finished?.servers.first
        }

        #expect(finished?.state == .ready)
        #expect(second?.isComplete == true)
        #expect(second?.folder != first?.folder)
        #expect(first.map { FileManager.default.fileExists(atPath: $0.folder) } == false)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealInstanceOfAnotherConnectionWithoutDataGetsNoServer() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile(#"""
        <?php
        return [
            'default' => 'main',
            'connections' => [
                'main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')],
                'reports' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => env('REPORTS_PORT'), 'database' => env('REPORTS_DATABASE', 'reports')],
            ],
        ];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "reports", in: shop)
        let port = freePort()
        try writeFile("REPORTS_PORT=\(port)\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        let listener = try listen(on: port)
        defer { close(listener) }

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
            #expect(await engine.supervisor.state(of: "mysql-8.4")?.isActive != true)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealCopyOntoADatabaseThatExistsGivesAnErrorThatTheSetupCanRecognize() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await client.query("CREATE DATABASE shop")
            try await client.query("CREATE DATABASE shop_fix")
            let source = DatabaseServer(host: "127.0.0.1", port: port, account: .newInstance)

            await #expect(throws: DatabaseTargetExists.self) {
                try await engine.copyDatabase(DatabaseCopy(source: source, database: "shop", instance: "mysql-8.4", name: "shop_fix", replace: false))
            }
        }
    }

    @Test func aCloneDoesNotMakeTheFolderOfAWorktreeThatWentAway() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let source = root.appending(path: "main.sqlite")
        try Data("the data".utf8).write(to: source)
        let gone = root.appending(path: "gone").path(percentEncoded: false)
        var workspace = Workspace(name: "fix", worktree: gone, folder: gone)

        try await engine.clone(
            WorkspaceFile(from: source.path(percentEncoded: false), to: "\(gone)/database/main.sqlite"),
            in: gone,
            git: URL(filePath: "/usr/bin/git"),
            into: &workspace
        )

        #expect(!FileManager.default.fileExists(atPath: gone))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealStartForASetupDuringAStopOfNexusdStartsNothing() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, engine, _) = try await redisApplication(in: root, port: freePort())

        await engine.stopWatchingWorktrees()

        await #expect(throws: RuntimeError.self) {
            try await engine.startForSetup("redis-8.2")
        }

        #expect(await engine.supervisor.state(of: "redis-8.2")?.isActive != true)
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealSecondSetupKeepsAFinishedCloneWithoutTheDefaultDatabase() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await mainDatabase(try await databaseClient(engine, id: "mysql-8.4", port: port))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let folder = try await record(engine, of: shop).servers[0].folder

            try await workspaceClient(engine, id: "mysql-8.4", of: shop).query("DROP DATABASE shop")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("The database server of this workspace has no database shop. Create it on that server, or remove the workspace."))
            #expect(FileManager.default.fileExists(atPath: folder))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealRetryAfterAnImportMakesANewCloneOfTheInstance() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        var withoutMain: [WorkspaceState?] = []
        var afterImport: [WorkspaceState?] = []

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            withoutMain = await workspaces(engine).map(\.state)

            try await client.query("CREATE DATABASE shop")
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)
            afterImport = await workspaces(engine).map(\.state)
        }

        #expect(withoutMain == [.notIsolated("mysql-8.4 has no database shop. Import it, and then retry.")])
        #expect(afterImport == [.ready])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: everyDatabaseVersion.filter { $0.0 != "postgresql" })
    func aRealFreezeLetsAWriterWaitAndGoOn(name: String, line: String, driver: String) async throws {
        guard isInstalled(name, line) else {
            return
        }

        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: driver, runtime: (name, line))
        let id = "\(name)-\(line)"

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            let client = try await databaseClient(engine, id: id, port: port)
            try await mainDatabase(client)

            let writer = try DatabaseSession(client)
            defer { writer.close() }

            let writes = Task {
                for row in 2...2000 {
                    try writer.send("INSERT INTO shop.items VALUES (\(row), 'row'); SELECT 'written';")

                    guard await writer.lines(until: "written", within: .seconds(20)) != nil else {
                        return false
                    }
                }

                return true
            }

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)

            let own = try await workspaceClient(engine, id: id, of: shop)
            let rows = try await own.query("SELECT COUNT(*), MAX(id) FROM items", database: "shop")
            let columns = rows.split(separator: "\t")

            #expect(columns.count == 2 && columns[0] == columns[1])
            #expect(try await writes.value)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealFreezeThatTheServerRefusesNamesTheError() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, engine, _, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let valid = try await databaseClient(engine, id: "mysql-8.4", port: port)
            let refused = DatabaseClient(tools: valid.tools, endpoint: DatabaseEndpoint(host: "127.0.0.1", port: port, account: DatabaseAccount(user: "root", password: "wrong")), options: valid.options)
            try refused.prepare()
            let target = root.appending(path: "clone").path(percentEncoded: false)

            await #expect {
                try await DatabaseSnapshot(tools: valid.tools, client: refused, source: root.path(percentEncoded: false), target: target).take()
            } throws: { error in
                String(describing: error).contains("gave an error at the freeze") && String(describing: error).contains("Access denied")
            }
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealCommandGetsThePortOfTheServerOfTheWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))

        try await engine.stateStore.update { $0.sites[0].workspaceCommands = ["echo {port:database} > port.txt"] }

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await mainDatabase(try await databaseClient(engine, id: "mysql-8.4", port: port))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let server = try #require(try await record(engine, of: shop).servers.first)

            #expect(text(of: worktree.appending(path: "port.txt")) == "\(server.port)\n")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealLongStatementGivesAWarningAndARetryWorksAfterIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree, port) = try await databaseApplication(in: root, driver: "mysql", runtime: ("mysql", "8.4"))

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            let client = try await databaseClient(engine, id: "mysql-8.4", port: port)
            try await mainDatabase(client)

            let holder = try DatabaseSession(client)
            defer { holder.close() }

            try holder.send("LOCK TABLES shop.items WRITE; SELECT 'locked';")
            _ = await holder.lines(until: "locked", within: .seconds(5))

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .notIsolated("A long statement on mysql-8.4 blocks the freeze, so Nexus made no clone. Retry when that statement ended."))

            holder.close()
            _ = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
            try await settle(engine)

            #expect(try await record(engine, of: shop).state == .ready)
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealBranchWithAFixedPortOfTheMainServerIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        let config = try #require(String(data: try Data(contentsOf: shop.appending(path: "config/database.php")), encoding: .utf8))
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try writeFile(config.replacingOccurrences(of: "env('DB_PORT', '3306')", with: "'\(port)'"), to: "config/database.php", in: shop)
        try await git("commit", "-q", "-am", "branch", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await databaseClient(engine, id: "mysql-8.4", port: port).query("CREATE DATABASE shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", root.appending(path: "fix").path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)

            guard case .notIsolated(let reason) = try await record(engine, of: shop).state else {
                Issue.record("The workspace must not be isolated.")
                return
            }

            #expect(reason.contains("The connection main has a fixed port in config/database.php."))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)))
    func aRealWorkspaceClonesAStoppedInstanceAndLeavesItStopped() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let port = freePort()
        try writeFile("DB_PORT=\(port)\nDB_DATABASE=shop\n", to: ".env", in: shop)
        let engine = try await engineWithDatabase(root: root, shop: shop, runtime: ("mysql", "8.4"), port: port)
        var workspace: Workspace?

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await databaseClient(engine, id: "mysql-8.4", port: port).query("CREATE DATABASE shop")
            _ = await engine.handle(.stop(service: "mysql-8.4"))
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            workspace = await engine.stateStore.current().worktrees[RealPath.of(shop)]?.workspaces.first
        }

        #expect(workspace?.state == .ready)
        #expect(workspace?.databases == [WorkspaceDatabaseCopy(instance: "mysql-8.4", name: "shop")])
        #expect(await engine.supervisor.state(of: "mysql-8.4")?.isActive != true)
        #expect(await engine.stateStore.current().enabledServices.contains("mysql-8.4") == false)
    }

    private func sqliteApplication(in root: URL, ignoring: String) async throws -> (shop: URL, engine: NexusEngine, worktree: URL) {
        let shop = try await committedLaravelApplication(in: root, ignoring: ignoring)
        try writeFile(#"""
        <?php
        return ['default' => 'main', 'connections' => ['main' => ['driver' => 'sqlite', 'database' => env('DB_DATABASE')]]];
        """#, to: "config/database.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "sqlite", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "database"), withIntermediateDirectories: true)
        try writeFile("DB_DATABASE=\(RealPath.of(shop.appending(path: "database")))/database.sqlite\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        return (shop, engine, root.appending(path: "fix", directoryHint: .isDirectory))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceClonesTheFileBehindASymbolicLink() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        let shared = root.appending(path: "shared.sqlite")
        try Data("the data".utf8).write(to: shared)
        try FileManager.default.createSymbolicLink(at: shop.appending(path: "database/database.sqlite"), withDestinationURL: shared)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)
        let type = try FileManager.default.attributesOfItem(atPath: clone)[.type] as? FileAttributeType

        #expect(type == .typeRegular)
        #expect(try String(contentsOfFile: clone, encoding: .utf8) == "the data")
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceClonesNoSQLiteFileWhenGitSeesItsWriteAheadFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ".env\nvendor\n*.sqlite\n")
        try writeFile("the data", to: "database/database.sqlite", in: shop)
        try writeFile("the last changes", to: "database/database.sqlite-wal", in: shop)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite").path(percentEncoded: false)

        #expect(!FileManager.default.fileExists(atPath: clone))
        #expect(!FileManager.default.fileExists(atPath: "\(clone)-wal"))
        #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore database/database.sqlite-wal, so Nexus does not clone that file.")])
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)), arguments: [true, false])
    func aRealWorkspaceGetsACloneOfASQLiteFileThatGitIgnores(ignored: Bool) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (shop, engine, worktree) = try await sqliteApplication(in: root, ignoring: ignored ? ".env\nvendor\n*.sqlite\n" : ".env\nvendor\n")
        try writeFile("the data", to: "database/database.sqlite", in: shop)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let clone = worktree.appending(path: "database/database.sqlite")
        let env = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(env == "DB_DATABASE=\(RealPath.of(worktree))/database/database.sqlite\n")

        if ignored {
            #expect(try String(contentsOf: clone, encoding: .utf8) == "the data")
            #expect(await workspaces(engine).map(\.state) == [.ready])
        } else {
            #expect(!FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)))
            #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore database/database.sqlite, so Nexus does not clone that file.")])
        }

        await engine.shutdown()
    }

    @Test func aSiteThatIsNoLaravelApplicationIsReadyWithoutAnEnvFile() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
    }

    @Test func aWorkspaceThatWaitsFromBeforeARestartGetsItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        let path = RealPath.of(worktree)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(listed: [RealPath.of(shop), path], workspaces: [Workspace(name: "fix", worktree: path, folder: path, branch: "fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.ready])
    }

    @Test func aWorkspaceWithoutItsFoldersWaitsForItsSetup() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shop = root.appending(path: "disk/shop", directoryHint: .isDirectory)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        state.worktrees[RealPath.of(shop)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/disk/fix", folder: "/disk/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.preparing])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWithItsOwnCachedConfigurationIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: worktree)
        try await settle(engine)

        #expect(await workspaces(engine).first?.isolationProblem?.contains("The worktree has bootstrap/cache/config.php") == true)
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealKeyOfTheSiteThatReplacesThePortOfTheServerIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("DB_PORT=13999\nDB_DATABASE=shop\n", to: ".env", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "DB_PORT", value: "13999")])]
        state.ports["mysql-8.4"] = 13999
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mysql", "8.4")])
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).first?.isolationProblem?.contains("The key DB_PORT of the site replaces the value that isolates this workspace.") == true)
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNewKeyOfASiteReachesAWorkspaceThatExistsAndKeepsItsPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")])]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let store = await engine.stateStore
        let port = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first?.ports["scout"])
        let keys = [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}"), WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]

        _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: keys)))
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SCOUT_PORT=\(port)\n"))
        #expect(text.contains("SECOND=fix\n"))
        await engine.shutdown()
    }

    @Test func aWrongEnvKeyNameGivesAnErrorAndChangesNothing() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceKeys: [WorkspaceEnvKey(key: "TWO WORDS", value: "1")])))

        #expect(response == .failure(message: "TWO WORDS is not a valid env key. Use letters, digits and underscores, for example SCOUT_PORT."))
        let store = await engine.stateStore
        #expect(await store.current().sites.first?.workspaceKeys == nil)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceKeepsAnEnvFileThatNexusCannotRead() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        let unreadable = Data("APP_NAME=Caf".utf8) + [0xE9]

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try unreadable.write(to: worktree.appending(path: ".env"))
        try await settle(engine)

        #expect(try Data(contentsOf: worktree.appending(path: ".env")) == unreadable)
        #expect(await workspaces(engine).map(\.state) == [.notIsolated("Nexus cannot read \(RealPath.of(worktree))/.env as UTF-8 text. So Nexus does not use its lines and does not change it.")])
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsTheKeysOfEverySiteOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        try writeFile("<?php", to: "public/index.php", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        var state = EngineState()
        state.sites = [
            Site(host: "a.test", folder: shop, php: "8.5"),
            Site(host: "b.test", folder: shop.appending(path: "public", directoryHint: .isDirectory), php: "8.5", workspaceKeys: [WorkspaceEnvKey(key: "SECOND", value: "{workspace}")]),
        ]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(text.contains("SECOND=fix\n"))
        await engine.shutdown()
    }

    @Test func aRetryAfterTheFixOfTheCauseClearsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        let unknown = await engine.handle(.retryWorkspace(host: "shop.test", name: "other"))
        let retried = await engine.handle(.retryWorkspace(host: "shop.test", name: "fix"))
        try await settle(engine)

        #expect(unknown == .failure(message: "shop.test has no workspace other."))
        #expect(retried == .done(message: "Nexus sets up the workspace fix again."))
        #expect(await workspaces(engine).first?.state != .preparing)
    }

    @Test func aCachedConfigurationOfTheMainCheckoutGivesAWorkspaceThatIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\nbootstrap/cache\n")
        try writeFile("<?php return [];", to: "bootstrap/cache/config.php", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4")])
        try await settle(engine)

        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated(ProbeError.cachedConfiguration.description)])
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceGetsAnEnvFileWithOnlyTheExpectedChanges() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: ".env\nvendor\n")
        let databasePort = freePort()
        try writeFile("""
        APP_NAME=Shop
        APP_URL=https://my.shop.test
        SESSION_DOMAIN=.shop.test
        SESSION_DRIVER=redis
        DB_PORT=\(databasePort)
        DB_DATABASE=shop
        REDIS_PORT=16999

        """, to: ".env", in: shop)
        let engine = try await engineWithDatabase(
            root: root,
            shop: shop,
            runtime: ("mysql", "8.4"),
            port: databasePort,
            host: "my.shop.test",
            keys: [WorkspaceEnvKey(key: "SCOUT_PORT", value: "{port:scout}")],
            redisPort: 16999
        )
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: "mysql-8.4"))
            try await databaseClient(engine, id: "mysql-8.4", port: databasePort).query("CREATE DATABASE shop")
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
        }

        let store = await engine.stateStore
        let workspace = try #require(await store.current().worktrees[RealPath.of(shop)]?.workspaces.first)
        let port = try #require(workspace.ports["scout"])
        let text = try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8)

        #expect(workspace.state == .ready)
        #expect(workspace.redisIndexes == ["REDIS_DB": 16])
        #expect(text == """
        APP_NAME=Shop
        APP_URL=https://my.shop-fix.test
        SESSION_DOMAIN=.shop-fix.test
        SESSION_DRIVER=redis
        DB_PORT=\(try #require(workspace.ports["mysql-8.4"]))
        DB_DATABASE=shop
        REDIS_PORT=16999
        REDIS_DB=16
        SCOUT_PORT=\(port)

        """)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceWritesNoEnvFileThatGitSees() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: "vendor\n")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)

        #expect(await workspaces(engine).map(\.state) == [.notIsolated("git does not ignore .env, so Nexus does not write that file.")])
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".env").path(percentEncoded: false)))
        await engine.shutdown()
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceThatIsNotIsolatedRunsNoInstall() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await committedLaravelApplication(in: root, ignoring: "vendor\n")
        try writeFile("main", to: "composer.lock", in: shop)
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "lock", in: shop)
        try await git("checkout", "-q", "-b", "fix", in: shop)
        try writeFile("branch", to: "composer.lock", in: shop)
        try await git("commit", "-q", "-am", "other lock", in: shop)
        try await git("checkout", "-q", "main", in: shop)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        try await settle(engine)

        try await git("worktree", "add", "-q", root.appending(path: "fix").path(percentEncoded: false), "fix", in: shop)
        try await settle(engine)

        let warnings = await workspaces(engine).first?.warnings

        #expect(warnings == ["vendor does not fit composer.lock, and Nexus runs no install in a workspace that is not isolated.", "Nexus runs no commands in a workspace that is not isolated."])
        await engine.shutdown()
    }

    @Test func aFailedAutomaticChangeShowsAtTheWorkspaceThatItLeftOut() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop, runtimes: [("php", "8.4"), ("nginx", "1.30")])
        try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
        try await settle(engine)

        await engine.recordAutomaticFailure("nginx refused the file.")

        #expect(await workspaces(engine).first?.problem == "The web configuration did not change. nginx refused the file.")
        #expect(await workspaces(engine).first?.url == nil)
    }

    @Test func aWorkspaceThatCanRunHasAURL() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.problem == nil)
        #expect(workspace?.url == "https://shop-fix.test")
    }

    @Test func aWorkspaceWithoutItsPHPVersionHasNoURLAndSaysWhy() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("nginx", "1.30")])

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "PHP 8.4 is not installed. Run: nexus install php 8.4")
    }

    @Test func aWorkspaceRunsAsASiteWithThePHPAndTheServerOfItsProject() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "my.shop.test", folder: root, aliases: ["blog.local"], php: "8.4", server: .apache)]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "ticket-1", worktree: "/w/ticket-1", folder: "/w/ticket-1")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.conflicts.isEmpty)
        #expect(workspaces.sites == [Site(host: "my.shop-ticket-1.test", folder: URL(filePath: "/w/ticket-1", directoryHint: .isDirectory), aliases: ["blog-ticket-1.test"], php: "8.4", server: .apache)])
    }

    @Test func aWorkspaceWhoseHostIsTakenIsLeftOutWithAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, php: "8.4"),
            Site(host: "shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.isEmpty)
        #expect(Array(workspaces.conflicts.values) == ["The workspace fix does not run, because another site has the host shop-fix.test already."])
    }

    @Test func aWorkspaceThatDoesNotRunHasNoURLAndNamesTheHostThatIsTaken() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [
            Site(host: "shop.test", folder: root, aliases: ["www.shop.test"], php: "8.4"),
            Site(host: "www.shop-fix.test", folder: root.appending(path: "other"), php: "8.4"),
        ]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])
        let engine = try makeSiteEngine(root: root, state: state)

        let workspace = await workspaces(engine).first

        #expect(workspace?.url == nil)
        #expect(workspace?.problem == "The workspace fix does not run, because another site has the host www.shop-fix.test already.")
    }

    @Test func aHostThatIsTooLongStopsOnlyItsOwnSite() throws {
        let runtime = InstalledRuntime(name: "php", line: "8.4", version: "8.4.0", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/php"))
        let site = Site(host: "\(String(repeating: "a.", count: 130))test", folder: URL(filePath: "/shop"), php: "8.4")

        let problem = NexusEngine.problem(of: site, installed: [runtime], checksNginx: false)

        #expect(problem?.contains("is not a valid host name") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCheckoutInAnEmptyWorktreeGivesADocumentRootInItsPublicFolder() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "--no-checkout", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("-C", worktree.path(percentEncoded: false), "reset", "-q", "--hard", in: shop)
        let documentRoot = "\(RealPath.of(worktree))/public/"

        while await !(engine.appliedSites ?? []).contains(where: { $0.contains(documentRoot) }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func twoSitesOfOneProjectShareOneBlockForAWorkspace() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publicFolder = root.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root)
        var state = EngineState()
        state.sites = [Site(host: "a.test", folder: root, php: "8.4"), Site(host: "b.test", folder: publicFolder, php: "8.4")]
        state.worktrees[RealPath.of(root)] = SiteWorktrees(workspaces: [Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")])

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.map(\.hosts) == [["a-fix.test", "b-fix.test"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func aMergeInAWorktreeThatAddsThePublicFolderChangesTheDocumentRoot() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await worktreeEngine(root: root, shop: shop)
        await engine.workspaceSitesChanged()
        defer { Task { await engine.stopWatchingWorktrees() } }
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)

        while await workspaces(engine).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await git("switch", "-q", "-c", "with-public", in: shop)
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: shop.appending(path: "public/index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "public", in: shop)
        try await git("-C", worktree.path(percentEncoded: false), "merge", "-q", "with-public", in: shop)

        while await engine.appliedSites?.contains(where: { $0.contains("/fix/public") }) != true {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceDoesNotStartAWebServerThatTheUserStopped() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = freePort()
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)
        var whileStopped, afterStart: Bool?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)
            _ = await engine.handle(.stop(service: ServiceCatalog.nginxID))
            try await git("worktree", "add", "-q", "-b", "fix", root.appending(path: "fix").path(percentEncoded: false), in: shop)
            try await settle(engine)
            whileStopped = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
            _ = await engine.handle(.start(service: ServiceCatalog.nginxID))
            afterStart = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
        }

        #expect(whileStopped != true)
        #expect(afterStart == true)
        #expect(await engine.stateStore.current().stoppedByStopAll.isEmpty)
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealWorkspaceOpensOverHTTPSWithTheFilesOfItsWorktree() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let publicFolder = shop.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("<?php echo 'main';".utf8).write(to: publicFolder.appending(path: "index.php"))
        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "page", in: shop)

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        let engine = try makeSiteEngine(root: root, state: state)
        try await linkRealRuntimes(in: engine.paths)

        var main, workspace, gone: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: "my.shop.test", aliases: [], php: "8.5", server: nil, group: nil))
            try await settle(engine)

            let worktree = root.appending(path: "test-1", directoryHint: .isDirectory)
            try await git("worktree", "add", "-q", "-b", "test-1", worktree.path(percentEncoded: false), in: shop)
            try Data("<?php echo 'workspace';".utf8).write(to: worktree.appending(path: "public/index.php"))
            try await settle(engine)

            main = await page("my.shop.test", port: httpsPort, expecting: "main")
            workspace = await page("my.shop-test-1.test", port: httpsPort, expecting: "workspace")

            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            gone = await page("my.shop-test-1.test", port: httpsPort, expecting: "main")
        }

        #expect(main == "main")
        #expect(workspace == "workspace")
        #expect(gone != "workspace")
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

        while await workspaces(engine).first?.folder != RealPath.of(moved) {
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

    private func nodeAppEngine(root: URL, shop: URL, command: String) async throws -> (engine: NexusEngine, port: Int) {
        let port = freePort()
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "", runsAs: .node, command: command)]
        state.appPorts[RealPath.of(shop)] = port
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("node", "24")])
        try await settle(engine)
        return (engine, port)
    }

    private func appPID(_ engine: NexusEngine, workspace: String?, shop: URL) async -> Int32? {
        let id = NexusEngine.appProcessID(owner: NexusEngine.processOwner(key: RealPath.of(shop), workspace: workspace))

        if case .running(let pid, _) = await engine.processSupervisor.state(of: id) {
            return pid
        }

        return nil
    }

    @Test func aNodeAppRunsInTheMainCheckoutAndInEachWorkspaceOnItsOwnPort() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let (engine, port) = try await nodeAppEngine(root: root, shop: shop, command: "echo {workspace} $PORT {port:app} $__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS > started.txt; exec sleep 300")
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspacePort = try #require(await workspaces(engine).first?.ports?[NodeAppLaunch.portName])

            #expect(await eventually { text(of: shop.appending(path: "started.txt")) == "main \(port) \(port) .test\n" })
            #expect(await eventually { text(of: worktree.appending(path: "started.txt")) == "fix \(workspacePort) \(workspacePort) .test\n" })
            #expect(workspacePort != port)
            #expect(await workspaces(engine).first?.app?.port == workspacePort)
        }
    }

    @Test func aNodeAppStartsAgainAfterACrashAndAfterARestart() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let (engine, port) = try await nodeAppEngine(root: root, shop: shop, command: "exec sleep 300")

        try await whileRunning(engine) {
            await engine.syncBackgroundProcesses().value
            let first = try #require(await appPID(engine, workspace: nil, shop: shop))

            kill(first, SIGKILL)

            #expect(await eventually { await appPID(engine, workspace: nil, shop: shop).map { $0 != first } == true })

            let second = try #require(await appPID(engine, workspace: nil, shop: shop))
            let restarted = await engine.handle(.restartApp(host: "shop.test", workspace: nil))
            let third = await appPID(engine, workspace: nil, shop: shop)
            let shown = await engine.siteInfo().first?.app

            #expect(restarted == .done(message: "Nexus starts the Node.js app of shop.test again."))
            #expect(third != nil && third != second)
            #expect(shown?.port == port)
            #expect(shown?.command == "exec sleep 300")
            #expect(shown?.log.hasSuffix("logs/app-shop.test.log") == true)
        }
    }

    @Test func aNodeAppWithoutAScriptOrACommandGetsAProblem() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try Data(#"{"scripts":{"build":"vite build"}}"#.utf8).write(to: shop.appending(path: "package.json"))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "", runsAs: .node)]
        state.appPorts[RealPath.of(shop)] = freePort()
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("node", "24"), ("nginx", "1.30")])

        try await whileRunning(engine) {
            await engine.syncBackgroundProcesses().value
            let site = await engine.siteInfo().first

            #expect(site?.problem?.hasPrefix("package.json has no dev or start script.") == true)
            #expect(site?.processProblems == ["The Node.js app does not run, because package.json has no dev or start script. Set a command, for example: nexus site edit shop.test --command \"npm run dev\""])
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    // A Node.js app with ignored env files. tracked holds files that git keeps.
    private func nodeApplication(in root: URL, files: [String: String], tracked: [String: String] = [:], package: String = #"{"scripts":{"dev":"sleep 300"}}"#, ignored: String = ".env\n.env.local\n") async throws -> URL {
        let shop = try await repository(in: root)
        try writeFile(ignored, to: ".gitignore", in: shop)
        try writeFile(package, to: "package.json", in: shop)

        for (name, text) in tracked {
            try writeFile(text, to: name, in: shop)
        }

        try await git("add", "-A", in: shop)
        try await git("commit", "-q", "-m", "app", in: shop)

        for (name, text) in files {
            try writeFile(text, to: name, in: shop)
        }

        return shop
    }

    private func nodeEngine(root: URL, shop: URL, ports: [String: Int] = [:], runtimes: [(name: String, line: String)] = [("node", "24")], keys: [WorkspaceEnvKey]? = nil) throws -> NexusEngine {
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "", workspaceKeys: keys, runsAs: .node, command: "exec sleep 300")]
        state.appPorts[RealPath.of(shop)] = freePort()
        state.ports.merge(ports) { _, port in port }
        return try makeSiteEngine(root: root, state: state, runtimes: runtimes)
    }

    @Test func aNodeWorkspaceGetsTheEnvFilesOfTheMainCheckoutWithItsOwnHosts() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await nodeApplication(in: root, files: [
            ".env": "APP_URL=https://shop.test\nSECRET=one\n",
            ".env.local": "NEXT_PUBLIC_SITE=https://shop.test/about\n",
        ])
        let engine = try nodeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)

            #expect(text(of: worktree.appending(path: ".env")) == "APP_URL=https://shop-fix.test\nSECRET=one\n")
            #expect(text(of: worktree.appending(path: ".env.local")) == "NEXT_PUBLIC_SITE=https://shop-fix.test/about\n")
            #expect(workspace.state == .ready)
            #expect(workspace.warnings == [])
            #expect(try await gitOutput("status", "--porcelain", in: worktree).isEmpty)
        }
    }

    @Test func anOwnKeyGoesIntoEachEnvFileOfANodeAppThatHasIt() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await nodeApplication(in: root, files: [
            ".env": "SECRET=one\n",
            ".env.local": "APP_NAME=main\n",
            ".env.development.local": "APP_NAME=main\n",
        ], ignored: ".env\n.env.local\n.env.development.local\n")
        let engine = try nodeEngine(root: root, shop: shop, keys: [WorkspaceEnvKey(key: "APP_NAME", value: "shop {workspace}"), WorkspaceEnvKey(key: "MODE", value: "workspace")])
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            #expect(text(of: worktree.appending(path: ".env.local")) == "APP_NAME=\"shop fix\"\n")
            #expect(text(of: worktree.appending(path: ".env.development.local")) == "APP_NAME=\"shop fix\"\n")
            #expect(text(of: worktree.appending(path: ".env")) == "SECRET=one\nMODE=workspace\n")
            #expect(await workspaces(engine).first?.state == .ready)
        }
    }

    @Test func anOwnKeyInATrackedEnvFileOfANodeAppIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await nodeApplication(in: root, files: [".env": "SECRET=one\n"], tracked: [".env.development": "APP_NAME=main\n"])
        let engine = try nodeEngine(root: root, shop: shop, keys: [WorkspaceEnvKey(key: "APP_NAME", value: "{workspace}")])
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)

            #expect(workspace.isolationProblem == "git does not ignore .env.development, so Nexus does not change APP_NAME in it.")
        }
    }

    @Test func aURLOfAServerOnAnotherComputerInAnotherEnvFileStaysAsItIs() {
        let request = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/a", workspaceFolder: "/b", mysqlPorts: [], postgresqlPorts: [5432], redisPorts: [])
        let plan = WorkspaceEnvPlan(nodeFiles: [
            NodeEnvFile(name: ".env", text: "DATABASE_URL=postgres://localhost:5432/app\n"),
            NodeEnvFile(name: ".env.local", text: "DATABASE_URL=postgres://db.example.com:5432/app\n"),
        ], usesDatabaseClient: true, request: request)
        let values = NodeEnvValues(plan: plan, serverPorts: [5432: 20001], redisIndexes: [:])

        #expect(values.values(in: "DATABASE_URL=postgres://db.example.com:5432/app\n").isEmpty)
        #expect(values.values(in: "DATABASE_URL=postgres://localhost:5432/app\n") == ["DATABASE_URL": "postgres://127.0.0.1:20001/app"])
    }

    @Test func aNodeWorkspaceWithADatabaseClientAndNoKeyGetsAWarning() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await nodeApplication(in: root, files: [".env": "SECRET=one\n"], package: #"{"scripts":{"dev":"sleep 300"},"dependencies":{"pg":"^8.0.0"}}"#)
        let engine = try nodeEngine(root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)

            #expect(workspace.state == .ready)
            #expect(workspace.warnings == ["Nexus found no database key in the env files of the app. When the app reaches a Nexus database in another way, this workspace uses the database of the main site."])
        }
    }

    @Test func aDatabaseKeyInATrackedEnvFileOfANodeAppIsNotIsolated() async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let shop = try await nodeApplication(in: root, files: [:], tracked: [".env.development": "DATABASE_URL=postgresql://root@127.0.0.1:\(port)/shop\n"])
        let engine = try nodeEngine(root: root, shop: shop, ports: ["postgresql-17": port], runtimes: [("node", "24"), ("postgresql", "17")])
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)

            #expect(workspace.isolationProblem?.contains("git does not ignore .env.development, so Nexus does not change DATABASE_URL in it.") == true)
            #expect(text(of: worktree.appending(path: ".env.development")) == "DATABASE_URL=postgresql://root@127.0.0.1:\(port)/shop\n")
        }
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(3)), arguments: [("postgresql", "17", "postgresql"), ("mysql", "8.4", "mysql")])
    func aRealNodeWorkspaceGetsItsOwnDatabaseServerAndRedisIndex(name: String, line: String, scheme: String) async throws {
        let root = workspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "\(name)-\(line)"
        let port = freePort()
        let redisPort = freePort()
        let shop = try await nodeApplication(in: root, files: [
            ".env": "DATABASE_URL=\(scheme)://root@localhost:\(port)/shop\nREDIS_URL=redis://127.0.0.1:\(redisPort)/3\n",
        ], package: #"{"scripts":{"dev":"sleep 300"},"dependencies":{"pg":"^8.0.0"}}"#)
        let engine = try nodeEngine(root: root, shop: shop, ports: [id: port, "redis-8.2": redisPort], runtimes: [])
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)
        try linkRealRuntimes(in: await engine.paths)
        try await link((name, line), in: engine)
        try await link(("redis", "8.2"), in: engine)

        try await whileRunning(engine) {
            _ = await engine.handle(.start(service: id))
            _ = await engine.handle(.start(service: "redis-8.2"))
            let client = try await databaseClient(engine, id: id, port: port)
            try await mainDatabase(client)
            let main = try await digest(client, "shop")

            try await settle(engine)
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let workspace = try #require(await workspaces(engine).first)
            let server = try #require(try await record(engine, of: shop).servers.first)
            let own = try await workspaceClient(engine, id: id, of: shop)
            let copy = try await digest(own, "shop")
            try await own.query("INSERT INTO items VALUES (2, 'workspace')", database: "shop")

            #expect(workspace.state == .ready)
            #expect(text(of: worktree.appending(path: ".env")) == "DATABASE_URL=\(scheme)://root@127.0.0.1:\(server.port)/shop\nREDIS_URL=redis://127.0.0.1:\(redisPort)/16\n")
            #expect(copy == main)
            #expect(try await digest(client, "shop") == main)
            #expect(try await digest(own, "shop") != main)
        }
    }
}

extension NexusEngine {
    func recordAutomaticFailure(_ failure: String) {
        appliedSites = []
        automaticWebFailure = failure
    }

    func addDatabaseRemovalProblem(for folder: String) {
        databaseRemovalProblems[folder] = DatabaseRemovalProblem(reason: "The save failed.", nextTry: .now)
    }

    func forgetRemovalProblems() {
        databaseRemovalProblems = [:]
    }

    func useTrashCheckWait(_ wait: Duration) {
        trashCheckWait = wait
    }
}

extension NexusEngine {
    var workspaceWorkRuns: Bool {
        reconcilingWorkspaces || settingUpWorkspaces || processSync != nil
    }

    func useWorktreeRemovalCheck(_ check: @escaping @Sendable () async -> Bool) {
        worktreeRemovalCheck = { _ in await check() }
    }

    func holdProcessSync(until release: AsyncStream<Void>) {
        processSync = Task {
            for await _ in release {}

            processSync = nil
        }
    }

    func markAsEmptying(_ indexes: Set<WorkspaceRedisIndex>) {
        emptyingRedisIndexes.formUnion(indexes)
    }

    func markAsUpdating(_ id: String) {
        updatingServices.insert(id)
    }
}
