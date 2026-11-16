import Darwin
import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

extension NexusEngine {
    func useOpenConnectionPorts(_ ports: @escaping @Sendable (Set<Int>) async -> Set<Int>?) {
        openConnectionPorts = ports
    }

    func useHotFilePortAnswers(_ answers: @escaping @Sendable (Int) -> Bool) {
        hotFilePortAnswers = answers
    }

    func dropDevServerPlan(of owner: String) {
        devServerPlans[owner] = nil
    }

    func watchAccessLogs(_ state: EngineState) {
        let workspaces = workspaceSites(state)
        watchAccessLogs(state, sitesOfRecord: workspaces.sitesOfRecord, conflicts: workspaces.conflicts)
    }
}

extension NexusEngineTests {
    private static let devServer = "echo {port:vite} > port.txt; exec sleep 300"

    func openPage(_ engine: NexusEngine, shop: URL, workspace: String? = nil, now: Date = .now) async {
        await engine.pageRequested(by: NexusEngine.processOwner(key: RealPath.of(shop), workspace: workspace), now: now)
        await engine.syncBackgroundProcesses().value
    }

    private func fileText(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    private func owner(of shop: URL, workspace: String? = nil) -> String {
        NexusEngine.processOwner(key: RealPath.of(shop), workspace: workspace)
    }

    private func workspaceWithDevServer(root: URL, commands: [String] = [devServer]) async throws -> (engine: NexusEngine, shop: URL, worktree: URL) {
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses(commands, root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
        try await settle(engine)
        return (engine, shop, worktree)
    }

    private func vitePort(_ engine: NexusEngine, of shop: URL) async throws -> Int {
        try #require(try await record(engine, of: shop).ports[DevServer.portName])
    }

    private func pid(_ engine: NexusEngine, command: String) async -> Int32? {
        for status in await engine.processSupervisor.status() where status.displayName == command {
            if case .running(let pid, _) = status.state {
                return pid
            }
        }

        return nil
    }

    private func listenOnIPv6Loopback() -> (descriptor: Int32, port: Int)? {
        for _ in 0..<50 {
            let port = Int.random(in: 50_001...60_000)
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }

            if bound == 0, Darwin.listen(descriptor, 5) == 0 {
                return (descriptor, port)
            }

            close(descriptor)
        }

        return nil
    }

    private func portAbove50000() -> Int {
        var port = Int.random(in: 50_001...60_000)

        while !PortInspector.isFree(port) || PortInspector.acceptsLoopbackConnections(port) {
            port = Int.random(in: 50_001...60_000)
        }

        return port
    }

    @Test func aWorkspaceRunsItsDevServerOnlyAfterAPageAndStopsItWithoutAPageAndATab() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, worktree) = try await workspaceWithDevServer(root: root)

        try await whileRunning(engine) {
            let port = try await vitePort(engine, of: shop)
            let before = await runningProcesses(engine)

            await openPage(engine, shop: shop, workspace: "fix")

            #expect(before.isEmpty)
            #expect(await eventually { fileText(worktree.appending(path: "port.txt")) == "\(port)\n" })
            #expect(await runningProcesses(engine) == ["echo \(port) > port.txt; exec sleep 300"])

            await engine.useOpenConnectionPorts { _ in [port] }
            await engine.checkIdleDevServers(now: .now + 301)
            let withTab = await runningProcesses(engine)

            await engine.useOpenConnectionPorts { _ in [] }
            await engine.checkIdleDevServers(now: .now + 301)
            let soonAfterTheTab = await runningProcesses(engine)

            await engine.checkIdleDevServers(now: .now + 602)
            let log = fileText(await engine.paths.log("workspace-shop-fix.test"))

            #expect(withTab.count == 1)
            #expect(soonAfterTheTab.count == 1)
            #expect(await runningProcesses(engine).isEmpty)
            #expect(log?.contains("Nexus stops this program, because no page loaded for 5 minutes and no tab is open.\n") == true)
        }
    }

    @Test func withNeverADevServerKeepsItsRun() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try await workspaceWithDevServer(root: root)

        try await whileRunning(engine) {
            try await engine.stateStore.update { $0.devServerStop = .never }
            await openPage(engine, shop: shop, workspace: "fix")
            await engine.useOpenConnectionPorts { _ in [] }
            await engine.checkIdleDevServers(now: .now + 86_400)

            #expect(await runningProcesses(engine).count == 1)
        }
    }

    @Test func aPageStartsTheDevServerOfAWorkspaceWhileRunInWorkspacesIsOff() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let engine = try await engineWithProcesses([Self.devServer, "exec sleep 301"], root: root, shop: shop)
        let worktree = root.appending(path: "fix", directoryHint: .isDirectory)

        try await whileRunning(engine) {
            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(workspaceProcesses: false)))
            try await git("worktree", "add", "-q", "-b", "fix", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)

            let port = try await vitePort(engine, of: shop)
            let before = await runningProcesses(engine)

            await openPage(engine, shop: shop, workspace: "fix")

            #expect(before.isEmpty)
            #expect(await runningProcesses(engine) == ["echo \(port) > port.txt; exec sleep 300"])
        }
    }

    @Test func thePageOfTheMainCheckoutStartsItsDevServerWithoutTheSwitchAndWithoutAProbe() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try FileManager.default.createDirectory(at: shop.appending(path: "bootstrap"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: shop.appending(path: "artisan"))
        try Data("<?php".utf8).write(to: shop.appending(path: "bootstrap/app.php"))
        let engine = try await engineWithProcesses([Self.devServer, "exec sleep 301"], root: root, shop: shop)

        try await whileRunning(engine) {
            let before = await runningProcesses(engine)

            await openPage(engine, shop: shop)

            let port = try #require(await engine.mainDevServerPlans[RealPath.of(shop)]?.ports[DevServer.portName])
            let command = "echo \(port) > port.txt; exec sleep 300"

            #expect(before.isEmpty)
            #expect(await eventually { fileText(shop.appending(path: "port.txt")) == "\(port)\n" })
            #expect(await runningProcesses(engine) == [command])
            #expect(await engine.mainProbeFailures.isEmpty)

            let first = await pid(engine, command: command)
            _ = await engine.handle(.editSite(host: "shop.test", change: SiteChange(mainProcesses: true)))
            try await settle(engine)

            #expect(await engine.mainDevServerPlans[RealPath.of(shop)]?.ports[DevServer.portName] == port)
            #expect(await engine.mainProbeFailures[RealPath.of(shop)] != nil)
            #expect(first != nil)
            #expect(await pid(engine, command: command) == first)
        }
    }

    @Test func aDevServerThatEndsFailsAtOnceAndAPageTenSecondsLaterTriesAgain() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try await workspaceWithDevServer(root: root, commands: ["echo {port:vite}; exit 3"])
        let owner = owner(of: shop, workspace: "fix")

        try await whileRunning(engine) {
            let paths = await engine.paths
            let log = paths.log("workspace-shop-fix.test")
            let starts = { (self.fileText(log) ?? "").components(separatedBy: "$ echo").count - 1 }

            await engine.watchAccessLogs(await engine.stateStore.current())
            await openPage(engine, shop: shop, workspace: "fix")

            #expect(await eventually { await engine.devServerFailures[owner] != nil })
            #expect(await eventually { await runningProcesses(engine).isEmpty })

            let failure = try #require(await engine.devServerFailures[owner])
            let problems = await engine.siteInfo().first?.processProblems ?? []
            let page = fileText(paths.devServerPage("shop-fix.test"))

            await openPage(engine, shop: shop, workspace: "fix", now: failure.time + 5)
            let startsAfterFiveSeconds = starts()

            await openPage(engine, shop: shop, workspace: "fix", now: failure.time + 11)

            #expect(problems.contains("The dev server echo of fix does not start. Its log is \(log.path(percentEncoded: false))."))
            #expect(page?.contains("The dev server of shop-fix.test does not start") == true)
            #expect(startsAfterFiveSeconds == 1)
            #expect(await eventually { starts() == 2 })
        }
    }

    @Test func aDevServerThatNeedsADatabaseInAWorkspaceWithoutOneShowsThePageOfTheFailure() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = "echo {port:vite} {database}; exec sleep 300"
        let (engine, shop, _) = try await workspaceWithDevServer(root: root, commands: [command])
        let owner = owner(of: shop, workspace: "fix")

        try await whileRunning(engine) {
            let paths = await engine.paths
            let log = paths.log("workspace-shop-fix.test")

            await engine.watchAccessLogs(await engine.stateStore.current())
            await openPage(engine, shop: shop, workspace: "fix")

            let failure = await engine.devServerFailures[owner]
            let problems = await engine.siteInfo().first?.processProblems ?? []

            #expect(failure?.command == command)
            #expect(failure?.reason == "It needs a database, and fix has none.")
            #expect(await runningProcesses(engine).isEmpty)
            #expect(problems.contains("The dev server echo of fix does not start. It needs a database, and fix has none. Its log is \(log.path(percentEncoded: false))."))
            #expect(fileText(paths.devServerPage("shop-fix.test"))?.contains("The dev server of shop-fix.test does not start") == true)
            #expect(fileText(log)?.contains("Nexus does not start \(command). It needs a database, and fix has none.\n") == true)
        }
    }

    @Test func aDevServerThatTheSupervisorCannotStartShowsThePageOfTheFailure() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try await workspaceWithDevServer(root: root)
        let owner = owner(of: shop, workspace: "fix")

        try await whileRunning(engine) {
            let paths = await engine.paths
            let log = paths.log("workspace-shop-fix.test")
            try? FileManager.default.removeItem(at: log)
            try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)

            await engine.watchAccessLogs(await engine.stateStore.current())
            await openPage(engine, shop: shop, workspace: "fix")

            let failure = await engine.devServerFailures[owner]
            let problems = await engine.siteInfo().first?.processProblems ?? []

            #expect(failure?.command == Self.devServer)
            #expect(failure?.reason != nil)
            #expect(await runningProcesses(engine).isEmpty)
            #expect(problems.contains { $0.hasPrefix("The dev server echo of fix does not start. ") && $0.contains(failure?.reason ?? "?") })
            #expect(fileText(paths.devServerPage("shop-fix.test"))?.contains("The dev server of shop-fix.test does not start") == true)
        }
    }

    @Test func aFailureWithoutAPlanKeepsTheCommandWithThePortNameAndTheNextSyncStartsNothing() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = "echo {port:vite}; sleep 1; exit 3"
        let (engine, shop, _) = try await workspaceWithDevServer(root: root, commands: [command])
        let owner = owner(of: shop, workspace: "fix")

        try await whileRunning(engine) {
            let log = await engine.paths.log("workspace-shop-fix.test")
            let starts = { (self.fileText(log) ?? "").components(separatedBy: "$ echo").count - 1 }

            await openPage(engine, shop: shop, workspace: "fix")
            await engine.dropDevServerPlan(of: owner)

            #expect(await eventually { await engine.devServerFailures[owner] != nil })

            await engine.syncBackgroundProcesses().value

            #expect(await engine.devServerFailures[owner]?.command == command)
            #expect(await runningProcesses(engine).isEmpty)
            #expect(starts() == 1)
        }
    }

    @Test func aViteConfigThatComesLaterGivesTheMainCheckoutItsDevServer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        try FileManager.default.createDirectory(at: shop.appending(path: "bootstrap"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: shop.appending(path: "artisan"))
        try Data("<?php".utf8).write(to: shop.appending(path: "bootstrap/app.php"))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state)
        try await settle(engine)

        try await whileRunning(engine) {
            await engine.syncBackgroundProcesses().value
            let before = await engine.devServerInfo(owner: owner(of: shop))

            try Data("export default {};\n".utf8).write(to: shop.appending(path: "vite.config.js"))
            try Data("/public/build\n/public/hot\n".utf8).write(to: shop.appending(path: ".gitignore"))
            await engine.syncBackgroundProcesses().value
            let after = await engine.devServerInfo(owner: owner(of: shop))

            #expect(before == nil)
            #expect(after?.state == .waitsForPage)
            #expect(after?.command == "npm run dev")
        }
    }

    @Test func aWorkspaceThatComesBackWithTheSameNameWaitsForItsOwnFirstPage() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, worktree) = try await workspaceWithDevServer(root: root)
        let owner = owner(of: shop, workspace: "fix")

        try await whileRunning(engine) {
            await engine.markPage(of: owner, now: .now)
            try await git("worktree", "remove", "--force", worktree.path(percentEncoded: false), in: shop)
            try await settle(engine)
            await engine.syncBackgroundProcesses().value

            let startedAfterTheRemoval = await engine.startedOnDemand.contains(owner)
            let pageAfterTheRemoval = await engine.lastPageRequest[owner]

            try await git("worktree", "add", "-q", worktree.path(percentEncoded: false), "fix", in: shop)
            try await settle(engine)
            await engine.syncBackgroundProcesses().value

            #expect(!startedAfterTheRemoval)
            #expect(pageAfterTheRemoval == nil)
            #expect(await engine.devServerInfo(owner: owner)?.state == .waitsForPage)
            #expect(await runningProcesses(engine).isEmpty)
        }
    }

    @Test func aHotFileOfAPortOfNexusThatAnswersHoldsBackTheStart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, worktree) = try await workspaceWithDevServer(root: root)
        let port = NexusEngine.firstWorkspacePort + 900
        let hot = worktree.appending(path: "public/hot")

        try await whileRunning(engine) {
            await engine.useHotFilePortAnswers { $0 == port }
            try FileManager.default.createDirectory(at: hot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("http://[::1]:\(port)".utf8).write(to: hot)

            await openPage(engine, shop: shop, workspace: "fix")
            let info = await engine.devServerInfo(owner: owner(of: shop, workspace: "fix"))

            #expect(await runningProcesses(engine).isEmpty)
            #expect(exists(hot))
            #expect(info?.state == .outsideNexus)
            #expect(info?.port == port)
        }
    }

    @Test func thePagesOfNginxChangeOnlyWithTheirPlansAndFailures() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, _) = try await workspaceWithDevServer(root: root, commands: ["echo {port:vite}; exit 3"])

        try await whileRunning(engine) {
            let page = await engine.paths.devServerPage("shop-fix.test")

            await engine.watchAccessLogs(await engine.stateStore.current())
            try Data("changed".utf8).write(to: page)
            await engine.syncBackgroundProcesses().value
            let afterASync = fileText(page)

            await openPage(engine, shop: shop, workspace: "fix")

            #expect(afterASync == "changed")
            #expect(await eventually { fileText(page)?.contains("does not start") == true })
        }
    }

    @Test func aHotFileOfAPortOfNexusWithoutAListenerGoesAtTheNextSync() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, shop, worktree) = try await workspaceWithDevServer(root: root)
        let port = try #require((20_000..<49_152).first { !PortInspector.acceptsLoopbackConnections($0) })
        let hot = worktree.appending(path: "public/hot")

        try await whileRunning(engine) {
            try FileManager.default.createDirectory(at: hot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("http://[::1]:\(port)".utf8).write(to: hot)

            await engine.syncBackgroundProcesses().value
            let log = fileText(await engine.paths.log("workspace-shop-fix.test"))

            #expect(!exists(hot))
            #expect(log?.contains("Nexus removed public/hot, because it named port \(port) and nothing listens there.\n") == true)
            #expect(await engine.devServerInfo(owner: owner(of: shop, workspace: "fix"))?.state == .waitsForPage)
        }
    }

    @Test func aHotFileOfAServerOutsideNexusThatAnswersHoldsBackTheStart() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try #require(listenOnIPv6Loopback())
        defer { close(listener.descriptor) }
        let (engine, shop, worktree) = try await workspaceWithDevServer(root: root)
        let hot = worktree.appending(path: "public/hot")

        try await whileRunning(engine) {
            try FileManager.default.createDirectory(at: hot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("http://[::1]:\(listener.port)".utf8).write(to: hot)

            await openPage(engine, shop: shop, workspace: "fix")
            let info = await engine.devServerInfo(owner: owner(of: shop, workspace: "fix"))

            #expect(await runningProcesses(engine).isEmpty)
            #expect(exists(hot))
            #expect(info?.state == .outsideNexus)
            #expect(info?.port == listener.port)
            #expect(info?.text == "A dev server outside Nexus runs on port \(listener.port). Nexus starts no second one.")
        }
    }

    @Test func thePagesOfNginxFollowTheHostsWithADevServer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, _, _) = try await workspaceWithDevServer(root: root)

        try await whileRunning(engine) {
            let paths = await engine.paths
            let gone = paths.devServerPage("gone.test")
            try FileManager.default.createDirectory(at: gone.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: gone)

            await engine.watchAccessLogs(await engine.stateStore.current())

            #expect(fileText(paths.devServerPage("shop.test"))?.contains("The dev server of shop.test does not run yet. Nexus starts echo.") == true)
            #expect(fileText(paths.devServerPage("shop-fix.test"))?.contains("<title>The dev server starts</title>") == true)
            #expect(!exists(gone))
        }
    }

    @Test func theSettingOfTheDevServersIsKeptAndAStateWithoutItGetsFiveMinutes() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        let fifteen = await engine.handle(.setDevServerStop(.fifteenMinutes))
        let stored = await engine.stateStore.current().devServerStop
        let listed = await engine.siteList().devServerStop
        let never = await engine.handle(.setDevServerStop(.never))
        let old = try JSONDecoder().decode(EngineState.self, from: Data("{}".utf8))
        let unknown = try JSONDecoder().decode(EngineState.self, from: Data(#"{"devServerStop":7}"#.utf8))

        #expect(fifteen == .done(message: "Nexus stops a dev server after 15 minutes without a page and without an open tab."))
        #expect(stored == .fifteenMinutes)
        #expect(listed == .fifteenMinutes)
        #expect(never == .done(message: "Nexus does not stop a dev server. A dev server starts with the first page of its site."))
        #expect(old.devServerStop == .fiveMinutes)
        #expect(unknown.devServerStop == .fiveMinutes)
    }

    @Test func aNodeAppStartsOnlyAfterAPage() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = try await repository(in: root)
        let started = shop.appending(path: "started.txt")
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "", runsAs: .node, command: "echo $PORT > started.txt; exec sleep 300")]
        state.appPorts[RealPath.of(shop)] = freePort()
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("node", "24")])
        try await settle(engine)

        try await whileRunning(engine) {
            await engine.syncBackgroundProcesses().value
            let waiting = await engine.siteInfo().first?.app
            let startedBefore = exists(started)

            await openPage(engine, shop: shop)

            #expect(waiting?.startsWithPage == true)
            #expect(waiting?.stateText == "Starts with the first page")
            #expect(!startedBefore)
            #expect(await eventually { exists(started) })
            #expect(await engine.siteInfo().first?.app?.startsWithPage == false)
        }
    }
}

// Real nginx and PHP, only when NEXUS_REAL_RUNTIMES names the runtimes folder. The site lives in a
// folder in /tmp.
extension NexusEngineTests {
    private func fetch(_ host: String, port: Int, accept: String, header: String? = nil) async -> (status: Int, body: String) {
        let curl = Process()
        curl.executableURL = URL(filePath: "/usr/bin/curl")
        curl.arguments = ["-s", "--max-time", "5", "--resolve", "\(host):\(port):127.0.0.1", "-H", "Accept: \(accept)"] + (header.map { ["-H", $0] } ?? []) + ["-w", "\n%{http_code}", "http://\(host):\(port)/"]
        let output = Pipe()
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        try? curl.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let status = Int(text.split(separator: "\n").last ?? "") ?? 0

        return (status, String(text.dropLast(String(status).count + 1)))
    }

    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNginxShowsTheWaitPageOfADevServerUntilTheHotFileAndThenThePageOfTheFailure() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths)

        let httpPort = portAbove50000()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = httpPort
        state.ports[ServiceCatalog.httpsPortKey] = portAbove50000()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let shop = root.appending(path: "projects/shop", directoryHint: .isDirectory)
        for folder in ["bootstrap", "node_modules", "public"] {
            try FileManager.default.createDirectory(at: shop.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data("<?php".utf8).write(to: shop.appending(path: "artisan"))
        try Data("<?php".utf8).write(to: shop.appending(path: "bootstrap/app.php"))
        try Data("export default {};\n".utf8).write(to: shop.appending(path: "vite.config.js"))
        try Data("<?php echo 'shop';".utf8).write(to: shop.appending(path: "public/index.php"))
        let hot = shop.appending(path: "public/hot")

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
        var waits, other, inertia, xhr, withHotFile, fails: (status: Int, body: String)?
        var hasPage = false

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            _ = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: nil, aliases: [], php: "8.5", server: nil))
            hasPage = await eventually { exists(paths.devServerPage("shop.test")) }

            waits = await fetch("shop.test", port: httpPort, accept: "text/html")
            other = await fetch("shop.test", port: httpPort, accept: "*/*")
            inertia = await fetch("shop.test", port: httpPort, accept: "text/html, application/xhtml+xml", header: "X-Inertia: true")
            xhr = await fetch("shop.test", port: httpPort, accept: "text/html", header: "X-Requested-With: XMLHttpRequest")

            try Data("http://[::1]:5173".utf8).write(to: hot)
            withHotFile = await fetch("shop.test", port: httpPort, accept: "text/html")
            try FileManager.default.removeItem(at: hot)

            _ = await eventually { await engine.devServerFailures.isEmpty == false }
            fails = await fetch("shop.test", port: httpPort, accept: "text/html")

            _ = await engine.handle(.stopAll)
        }

        #expect(hasPage)
        #expect(waits?.status == 503)
        #expect(waits?.body.contains("The dev server starts") == true)
        #expect(other?.body == "shop")
        #expect(inertia?.body == "shop")
        #expect(xhr?.body == "shop")
        #expect(withHotFile?.body == "shop")
        #expect(fails?.body.contains("does not start") == true)
    }
}
