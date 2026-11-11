import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Synchronization
import Testing
@testable import NexusEngine

// Site groups, the defaults for new sites and the watch of the parked folders (step 6, part 6e).
extension NexusEngineTests {
    static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    func linkRealRuntimes(in paths: NexusPaths, _ runtimes: [String] = ["nginx/1.30", "php/8.5"]) throws {
        for runtime in runtimes {
            let parts = runtime.split(separator: "/").map(String.init)
            let link = paths.runtime(parts[0], line: parts[1])
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: runtime))
        }
    }

    func makeSiteEngine(root: URL, state: EngineState = EngineState(), runtimes: [(name: String, line: String)] = [], processSupervisor: ProcessSupervisor = ProcessSupervisor(), dumpLibrarySource: URL? = nil) throws -> NexusEngine {
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
        try paths.createFolders()
        var state = state
        state.ports[NexusEngine.dnsServiceID] = state.ports[NexusEngine.dnsServiceID] ?? freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        for (name, line) in runtimes {
            let folder = paths.runtime(name, line: line)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runtime = InstalledRuntime(name: name, line: line, version: "\(line).0", revision: 1, sha256: "", installedAt: .now, folder: folder)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(runtime).write(to: folder.appending(path: InstalledRuntime.metadataFileName))
        }

        return NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            processSupervisor: processSupervisor,
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            workspaceFolderQuiet: .zero,
            dumpLibrarySource: dumpLibrarySource
        )
    }

    func siteTestRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Nexus Site Tests \(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func site(_ host: String, in folder: URL) -> Site {
        Site(host: host, folder: folder.appending(path: host, directoryHint: .isDirectory), php: "8.5")
    }

    @Test func theLayoutKeepsTheOrderOfTheUserAndAddsANewSiteAtTheEnd() {
        let folder = URL(filePath: "/projects", directoryHint: .isDirectory)
        var state = EngineState()
        state.sites = ["shop.test", "blog.test", "crm.test", "docs.test"].map { site($0, in: folder) }
        let stored: [SiteLayoutEntry] = [.site("crm.test"), .group(name: "Clients", hosts: ["docs.test", "gone.test"]), .site("shop.test")]

        let layout = NexusEngine.layout(stored, sites: state.sites, state: state)

        #expect(layout == [.site("crm.test"), .group(name: "Clients", hosts: ["docs.test"]), .site("shop.test"), .site("blog.test")])
    }

    @Test func aSiteOfAParkedFolderIsInTheLayoutOnlyInAGroup() {
        let parked = URL(filePath: "/Sites", directoryHint: .isDirectory)
        var state = EngineState()
        state.parked = [ParkedFolder(folder: parked, php: "8.5")]
        state.sites = [site("edited.test", in: parked), site("shop.test", in: URL(filePath: "/projects"))]
        let sites = state.sites + [site("acme.test", in: parked), site("demo.test", in: parked)]

        let layout = NexusEngine.layout([.group(name: "Work", hosts: ["acme.test"])], sites: sites, state: state)

        #expect(layout == [.group(name: "Work", hosts: ["acme.test"]), .site("shop.test")])
        #expect(NexusEngine.parkedFolder(of: state.sites[0], in: state.parked) == state.parked[0])
        #expect(NexusEngine.parkedFolder(of: state.sites[1], in: state.parked) == nil)
    }

    @Test func aMoveToAGroupThatDoesNotExistMakesTheGroupAtTheEnd() {
        let layout: [SiteLayoutEntry] = [.group(name: "Work", hosts: ["shop.test", "crm.test"]), .site("blog.test")]

        let moved = layout.moving("shop.test", toGroup: "Private")
        let back = moved.moving("shop.test", toGroup: "Work")
        let out = back.moving("shop.test", toGroup: nil)

        #expect(moved == [.group(name: "Work", hosts: ["crm.test"]), .site("blog.test"), .group(name: "Private", hosts: ["shop.test"])])
        #expect(back == [.group(name: "Work", hosts: ["crm.test", "shop.test"]), .site("blog.test"), .group(name: "Private", hosts: [])])
        #expect(out == [.group(name: "Work", hosts: ["crm.test"]), .site("blog.test"), .group(name: "Private", hosts: [])])
    }

    @Test func aMoveToAGroupNameWithOtherCapitalsUsesTheGroupThatExists() {
        let layout: [SiteLayoutEntry] = [.group(name: "Work", hosts: ["crm.test"]), .site("shop.test")]

        let moved = layout.moving("shop.test", toGroup: "work")

        #expect(moved == [.group(name: "Work", hosts: ["crm.test", "shop.test"])])
    }

    @Test func aLayoutWithAHostTwiceOrAGroupWithoutANameIsRefused() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        let twice = await engine.handle(.setSiteLayout([.site("shop.test"), .group(name: "Work", hosts: ["shop.test"])]))
        let unnamed = await engine.handle(.setSiteLayout([.group(name: " ", hosts: [])]))
        let sameName = await engine.handle(.setSiteLayout([.group(name: "Work", hosts: []), .group(name: "work", hosts: [])]))
        let kept = await engine.handle(.setSiteLayout([.group(name: " Work ", hosts: ["shop.test"])]))

        #expect(twice == .failure(message: "shop.test is in the order of the sites two times."))
        #expect(unnamed == .failure(message: "A group needs a name."))
        #expect(sameName == .failure(message: "There is a group work already."))
        #expect(kept == .done(message: "Nexus keeps the new order of the sites."))
        #expect(await engine.stateStore.current().siteLayout == [.group(name: "Work", hosts: ["shop.test"])])
    }

    @Test func aDefaultPHPVersionMustBeInstalled() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.4")])

        let missing = await engine.handle(.setSiteDefaults(SiteDefaults(server: .apache, php: "8.3")))
        let set = await engine.handle(.setSiteDefaults(SiteDefaults(server: .apache, php: "8.4")))
        let read = await engine.handle(.siteDefaults)

        #expect(missing == .failure(message: "PHP 8.3 is not installed. Run: nexus install php 8.3"))
        #expect(set == .done(message: "A new site gets Apache and PHP 8.4. Its Node version comes from the project. A new WordPress site gets Apache and PHP 8.4. The sites that exist do not change."))
        #expect(read == .siteDefaults(SiteDefaults(server: .apache, php: "8.4")))
    }

    @Test func aProxySiteNeedsAnAddressOfAnotherServerThanNginx() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "api", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = EngineState()
        state.ports[ServiceCatalog.httpsPortKey] = 8443
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])
        let path = folder.path(percentEncoded: false)

        let noAddress = await engine.handle(.addSite(folder: path, host: nil, aliases: [], php: nil, server: nil, runsAs: .proxy))
        let loop = await engine.handle(.addSite(folder: path, host: nil, aliases: [], php: nil, server: nil, runsAs: .proxy, address: "0.0.0.0:8443"))
        let noKind = await engine.handle(.addSite(folder: path, host: nil, aliases: [], php: nil, server: nil, address: "3000"))
        let wrongKind = await engine.handle(.addSite(folder: path, host: nil, aliases: [], php: nil, server: nil, runsAs: .php, command: "npm run dev"))
        let name = await engine.handle(.addSite(folder: path, host: nil, aliases: [], php: nil, server: nil, runsAs: .proxy, address: "http://shop.test"))

        #expect(noAddress == .failure(message: "A proxy site needs the address of its server, for example: --address 3000"))
        #expect(loop == .failure(message: "nginx of Nexus listens on port 8443. So a proxy to http://0.0.0.0:8443 sends each request back to nginx. Use the port of your own server."))
        #expect(noKind == .failure(message: "Only a proxy site has an address. Add --runs-as proxy."))
        #expect(wrongKind == .failure(message: "Only a Node.js app has a command. Add --runs-as node."))
        #expect(name == .failure(message: "http://shop.test is not an address that Nexus can use. Use a port, for example 3000, or an IP address with a port, for example http://127.0.0.1:3000."))
        #expect(await engine.stateStore.current().sites.isEmpty)
    }

    @Test func aWorkspaceOfAProxySiteDoesNotRun() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let site = Site(host: "shop.test", folder: root, php: "", runsAs: .proxy, address: "http://127.0.0.1:3000")
        var state = EngineState()
        state.sites = [site]
        state.worktrees[ProjectFolder.workspaceKey(of: site)] = SiteWorktrees(workspaces: [Workspace(name: "ticket-1", worktree: "/work/ticket-1", folder: "/work/ticket-1")])
        let engine = try makeSiteEngine(root: root, state: state)

        let workspaces = await engine.workspaceSites(state)

        #expect(workspaces.sites.isEmpty)
        #expect(Array(workspaces.conflicts.values) == ["The workspace ticket-1 does not run, because shop.test is a proxy site. Each workspace would go to the same server. Remove the workspace."])
    }

    @Test func aCommandDoesNotChangeAPHPSite() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: root, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])

        let response = await engine.handle(.editSite(host: "shop.test", change: SiteChange(command: Site.commandFromProject)))

        #expect(response == .failure(message: "Only a Node.js app has a command. Add --runs-as node."))
        #expect(await engine.stateStore.current().sites.first?.kind == .php)
    }

    @Test func onlyAPHPSiteNeedsPHP() {
        let installed = [InstalledRuntime(name: "nginx", line: "1.30", version: "1.30.6", revision: 1, sha256: "", installedAt: .now, folder: URL(filePath: "/nginx"))]
        let folder = URL(filePath: "/projects/shop", directoryHint: .isDirectory)

        let php = NexusEngine.problem(of: Site(host: "shop.test", folder: folder, php: "8.5"), installed: installed)
        let proxy = NexusEngine.problem(of: Site(host: "shop.test", folder: folder, php: "", server: .apache, runsAs: .proxy, address: "http://127.0.0.1:3000"), installed: installed)
        let noAddress = NexusEngine.problem(of: Site(host: "shop.test", folder: folder, php: "", runsAs: .proxy), installed: installed)

        #expect(php == "PHP 8.5 is not installed. Run: nexus install php 8.5")
        #expect(proxy == nil)
        #expect(noAddress == "It runs as a proxy, and it has no address. Run: nexus site edit shop.test --address 3000")
    }

    @Test func aCommandOfANodeAppChangesWithoutNginxAndProjectGivesTheScriptAgain() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: app.appending(path: "package.json"))
        try Data().write(to: app.appending(path: "pnpm-lock.yaml"))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: app, php: "8.5", runsAs: .node)]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5")])

        let chosen = await engine.handle(.editSite(host: "shop.test", change: SiteChange(command: "  pnpm dev --port {port:app}  ")))
        let stored = await engine.stateStore.current().sites.first?.command
        let empty = await engine.handle(.editSite(host: "shop.test", change: SiteChange(command: " ")))
        let back = await engine.handle(.editSite(host: "shop.test", change: SiteChange(command: Site.commandFromProject)))
        let shown = await engine.siteInfo().first

        #expect(chosen == .done(message: "https://shop.test runs the Node.js app in \(app.path(percentEncoded: false)) with pnpm dev --port {port:app}."))
        #expect(stored == "pnpm dev --port {port:app}")
        #expect(empty == .failure(message: "A command is one line, for example npm run dev. Use project for the script of package.json."))
        #expect(back == .done(message: "https://shop.test runs the Node.js app in \(app.path(percentEncoded: false)) with pnpm run dev."))
        #expect(await engine.stateStore.current().sites.first?.command == nil)
        #expect(shown?.projectCommand == "pnpm run dev")
        #expect(shown?.framework == nil)
    }

    // The engine has no nginx. So the new site shows with its problem, and nothing starts.
    @Test func aNewProjectInAParkedFolderShowsWithTheDefaultsWithoutARequest() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        var state = EngineState()
        state.siteDefaults = SiteDefaults(server: .apache, php: "8.4")
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.4"), ("php", "8.5")])

        try await whileRunning(engine) {
            let parkedFolder = await engine.handle(.park(folder: parked.path(percentEncoded: false), php: nil, server: nil))
            let sites = Mutex<[SiteList]>([])
            let events = await engine.events()
            Task {
                for await case .sites(let list) in events {
                    sites.withLock { $0.append(list) }
                }
            }

            try FileManager.default.createDirectory(at: parked.appending(path: "New Shop"), withIntermediateDirectories: true)
            let deadline = ContinuousClock.now + .seconds(5)
            var shown: SiteInfo?
            while shown == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                shown = sites.withLock { $0.last?.sites.first { $0.hosts == ["new-shop.test"] } }
            }

            if case .done = parkedFolder {} else { Issue.record("the folder was not parked: \(parkedFolder)") }
            #expect(shown?.php == "8.4")
            #expect(shown?.server == .apache)
            #expect(shown?.parked == true)
            #expect(shown?.parkedFolder == NexusEngine.displayPath(parked))
            #expect(shown?.problem?.contains("nginx is not installed") == true)
            #expect(sites.withLock { $0.last?.parkedFolders } == [NexusEngine.displayPath(parked)])
        }
    }

    @Test func theDatabaseUsersComeFromTheEnvOfEachSite() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        let envs = [
            "shop.test": "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=13306\nDB_DATABASE=shop\n",
            "blog.test": "DB_CONNECTION=mariadb\nDB_PORT=\"13306\"\nDB_DATABASE='shop' # the same database\n",
            "crm.test": "DB_CONNECTION=mysql\nDB_PORT=3306\nDB_DATABASE=crm\n",
            "notes.test": "DB_CONNECTION=pgsql\nDB_PORT=13306\nDB_DATABASE=notes\n",
            "remote.test": "DB_CONNECTION=mysql\nDB_HOST=db.example\nDB_PORT=13306\nDB_DATABASE=remote\n",
        ]
        var state = EngineState()
        for (host, env) in envs {
            let site = site(host, in: projects)
            try FileManager.default.createDirectory(at: site.folder, withIntermediateDirectories: true)
            try Data(env.utf8).write(to: site.folder.appending(path: ".env"))
            state.sites.append(site)
        }
        let engine = try makeSiteEngine(root: root, state: state)

        let users = await engine.databaseUsers(kind: .mysql, port: 13306)

        #expect(users == ["shop": ["blog.test", "shop.test"]])
    }
}

// Real nginx and PHP, only when NEXUS_REAL_RUNTIMES names the runtimes folder (see
// RealDatabaseTests). The sites and the servers live in a folder in /tmp.
extension NexusEngineTests {
    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aNewRealProjectInAParkedFolderOpensOverHTTPSAndWaitsWhileStopAllIsInEffect() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths)

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try project("first", in: parked, publicFolder: false)

        let makeEngine = {
            NexusEngine(
                paths: paths,
                helper: self.helper,
                certificateAuthority: CertificateAuthority(paths: paths, store: self.keyStore),
                systemFiles: SystemDNSFiles(
                    resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                    hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
                )
            )
        }
        let engine = makeEngine()
        var first, second, third: String?
        var thirdWhileStopped = false
        var nginxWhileStopped: Bool?

        try await whileRunning(engine) {
            _ = await engine.handle(.park(folder: parked.path(percentEncoded: false), php: "8.5", server: nil))
            first = await page("first.test", port: httpsPort, expecting: "first")

            try project("second", in: parked, publicFolder: true)
            second = await page("second.test", port: httpsPort, expecting: "second")

            _ = await engine.handle(.stopAll)
            try project("third", in: parked, publicFolder: false)
            thirdWhileStopped = await waitForSite("third.test", in: engine)
            nginxWhileStopped = await engine.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
            _ = await engine.handle(.startStopped)
            third = await page("third.test", port: httpsPort, expecting: "third")

            _ = await engine.handle(.stopAll)
        }

        let restarted = makeEngine()
        var nginxAfterRestart: Bool?
        var waiting: Set<String> = []

        try await whileRunning(restarted) {
            await restarted.startEnabledServices()
            nginxAfterRestart = await restarted.supervisor.state(of: ServiceCatalog.nginxID)?.isActive
            waiting = await restarted.stateStore.current().stoppedByStopAll
        }

        #expect(first == "first")
        #expect(second == "second")
        #expect(thirdWhileStopped)
        #expect(nginxWhileStopped != true)
        #expect(third == "third")
        #expect(nginxAfterRestart != true)
        #expect(waiting.isSuperset(of: [ServiceCatalog.nginxID, "php-8.5"]))
    }

    // The "Done when" of part 6g: every site opens on its new name after a change of the dev TLD.
    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func everyRealSiteOpensOnItsNewNameAfterAChangeOfTheTLD() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths)

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try project("parked", in: parked, publicFolder: false)
        let added = root.appending(path: "projects", directoryHint: .isDirectory)
        try project("added", in: added, publicFolder: true)

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
        var before, parkedPage, addedPage, aliasPage, oldName: String?

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            _ = await engine.handle(.park(folder: parked.path(percentEncoded: false), php: "8.5", server: nil))
            _ = await engine.handle(.addSite(folder: added.appending(path: "added").path(percentEncoded: false), host: nil, aliases: ["www.added.test"], php: "8.5", server: nil))
            before = await page("added.test", port: httpsPort, expecting: "added")

            _ = await engine.handle(.tld("internal"))
            parkedPage = await page("parked.internal", port: httpsPort, expecting: "parked")
            addedPage = await page("added.internal", port: httpsPort, expecting: "added")
            aliasPage = await page("www.added.internal", port: httpsPort, expecting: "added")
            oldName = await page("added.test", port: httpsPort, expecting: "")

            _ = await engine.handle(.stopAll)
        }

        #expect(before == "added")
        #expect(parkedPage == "parked")
        #expect(addedPage == "added")
        #expect(aliasPage == "added")
        #expect(oldName?.isEmpty == true)
    }

    // A project with its public folder after a short wait, as composer create-project makes it.
    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealNodeAppAndAProxySiteOpenOverHTTPSAndNextGetsItsOwnOrigin() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths, ["nginx/1.30", "php/8.5", "node/24"])

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let shop = root.appending(path: "projects/shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"dev":"node server.js"},"dependencies":{"next":"16.4.0"}}"#.utf8).write(to: shop.appending(path: "package.json"))
        try Data("require('http').createServer((request, response) => response.end(`app ${request.headers.host} ${request.headers.origin ?? ''}`)).listen(process.env.PORT, '::1')\n".utf8).write(to: shop.appending(path: "server.js"))
        let api = root.appending(path: "projects/api", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
        var added: NexusResponse?
        var app, ownOrigin, otherOrigin, proxy: String?
        var port = 0

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            added = await engine.handle(.addSite(folder: shop.path(percentEncoded: false), host: nil, aliases: [], php: nil, server: nil))

            port = try #require(await engine.siteInfo().first { $0.hosts.first == "shop.test" }?.app?.port)
            _ = await engine.handle(.addSite(folder: api.path(percentEncoded: false), host: nil, aliases: [], php: nil, server: nil, runsAs: .proxy, address: "http://[::1]:\(port)"))

            app = await page("shop.test", port: httpsPort, expecting: "app shop.test:\(httpsPort) ")
            ownOrigin = await page("shop.test", port: httpsPort, origin: "https://shop.test:\(httpsPort)", expecting: "app shop.test:\(httpsPort) http://localhost:\(port)")
            otherOrigin = await page("shop.test", port: httpsPort, origin: "https://evil.example", expecting: "app shop.test:\(httpsPort) https://evil.example")
            proxy = await page("api.test", port: httpsPort, expecting: "app api.test:\(httpsPort) ")

            _ = await engine.handle(.stopAll)
        }

        #expect(added.map { if case .done = $0 { true } else { false } } == true, "\(String(describing: added))")
        #expect(app == "app shop.test:\(httpsPort) ")
        #expect(ownOrigin == "app shop.test:\(httpsPort) http://localhost:\(port)")
        #expect(otherOrigin == "app shop.test:\(httpsPort) https://evil.example")
        #expect(proxy == "app api.test:\(httpsPort) ")
    }

    static let realNodeApps = ProcessInfo.processInfo.environment["NEXUS_NODE_APPS"]

    // NEXUS_NODE_APPS names a folder with the installed projects next, nuxt and vite. Each one has
    // a page with the text <name>-marker. The websocket of hot reload must open through nginx.
    @Test(.enabled(if: realRuntimes != nil && realNodeApps != nil), .timeLimit(.minutes(5)))
    func realNextNuxtAndViteAppsOpenOverHTTPSWithTheirWebsocket() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths, ["nginx/1.30", "php/8.5", "node/24"])

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let apps = URL(filePath: Self.realNodeApps!, directoryHint: .isDirectory)
        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
        var pages: [String: String] = [:]
        var viteClient = "", viteSocket = "", nextSocket = "", nextForeignSocket = ""

        try await whileRunning(engine) {
            await engine.startEnabledServices()

            for name in ["next", "nuxt", "vite"] {
                _ = await engine.handle(.addSite(folder: apps.appending(path: name).path(percentEncoded: false), host: nil, aliases: [], php: nil, server: nil))
            }

            for name in ["next", "nuxt", "vite"] {
                pages[name] = await page("\(name).test", port: httpsPort, containing: "\(name)-marker")
            }

            viteClient = await curl(["https://vite.test:\(httpsPort)/@vite/client"], host: "vite.test", port: httpsPort)
            let token = viteClient.firstMatch(of: /wsToken = "([^"]+)"/).map { String($0.1) } ?? ""
            viteSocket = await curl(websocket(origin: "https://vite.test:\(httpsPort)", protocol: "vite-hmr") + ["https://vite.test:\(httpsPort)/?token=\(token)"], host: "vite.test", port: httpsPort)
            nextSocket = await curl(websocket(origin: "https://next.test:\(httpsPort)") + ["https://next.test:\(httpsPort)/_next/hmr?id=nexus"], host: "next.test", port: httpsPort)
            nextForeignSocket = await curl(websocket(origin: "https://evil.example") + ["https://next.test:\(httpsPort)/_next/hmr?id=nexus"], host: "next.test", port: httpsPort)

            _ = await engine.handle(.stopAll)
        }

        for name in ["next", "nuxt", "vite"] {
            #expect(pages[name]?.contains("\(name)-marker") == true, "\(name): \(pages[name]?.prefix(300) ?? "no page")")
        }

        #expect(viteClient.contains("wsToken"), "\(viteClient.prefix(300))")
        #expect(viteSocket.hasPrefix("HTTP/1.1 101"), "\(viteSocket.prefix(300))")
        #expect(nextSocket.hasPrefix("HTTP/1.1 101"), "\(nextSocket.prefix(300))")
        #expect(!nextForeignSocket.hasPrefix("HTTP/1.1 101"), "\(nextForeignSocket.prefix(300))")
    }

    private func websocket(origin: String, protocol name: String? = nil) -> [String] {
        ["--http1.1", "-i", "-N", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket", "-H", "Sec-WebSocket-Version: 13", "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "-H", "Origin: \(origin)"]
            + (name.map { ["-H", "Sec-WebSocket-Protocol: \($0)"] } ?? [])
    }

    // A dev server compiles the page at the first request. That can take half a minute.
    private func page(_ host: String, port: Int, containing marker: String) async -> String? {
        let deadline = ContinuousClock.now + .seconds(90)
        var body = ""

        while !body.contains(marker), ContinuousClock.now < deadline {
            body = await curl(["https://\(host):\(port)/"], host: host, port: port, seconds: 30)

            if !body.contains(marker) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        return body
    }

    private func curl(_ arguments: [String], host: String, port: Int, seconds: Int = 3) async -> String {
        let curl = Process()
        curl.executableURL = URL(filePath: "/usr/bin/curl")
        curl.arguments = ["-sk", "--max-time", "\(seconds)", "--resolve", "\(host):\(port):127.0.0.1"] + arguments
        let output = Pipe()
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        try? curl.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func project(_ name: String, in parked: URL, publicFolder: Bool) throws {
        let folder = parked.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if publicFolder {
            Thread.sleep(forTimeInterval: 1)
        }

        let documentRoot = publicFolder ? folder.appending(path: "public", directoryHint: .isDirectory) : folder
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        try Data("<?php echo '\(name)';".utf8).write(to: documentRoot.appending(path: "index.php"))
    }

    private func waitForSite(_ host: String, in engine: NexusEngine) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)

        while ContinuousClock.now < deadline {
            if await engine.siteInfo().contains(where: { $0.hosts.first == host }), await engine.appliedSites?.contains(where: { $0.hasPrefix("\(host) ") }) == true {
                return true
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        return false
    }

    // curl does not trust the root CA of the test. That does not matter here.
    func page(_ host: String, port: Int, origin: String? = nil, expecting expected: String) async -> String? {
        let deadline = ContinuousClock.now + .seconds(15)
        var body: String?

        while body != expected, ContinuousClock.now < deadline {
            let curl = Process()
            curl.executableURL = URL(filePath: "/usr/bin/curl")
            curl.arguments = ["-sk", "--max-time", "2", "--resolve", "\(host):\(port):127.0.0.1"] + (origin.map { ["-H", "Origin: \($0)"] } ?? []) + ["https://\(host):\(port)/"]
            let output = Pipe()
            curl.standardOutput = output
            curl.standardError = FileHandle.nullDevice
            try? curl.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            curl.waitUntilExit()
            body = String(decoding: data, as: UTF8.self)

            if body != expected {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        return body
    }
}
