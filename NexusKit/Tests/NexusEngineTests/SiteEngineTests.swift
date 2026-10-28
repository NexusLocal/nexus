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
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    private func makeSiteEngine(root: URL, state: EngineState = EngineState(), runtimes: [(name: String, line: String)] = []) throws -> NexusEngine {
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
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
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
    }

    private func siteTestRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Nexus Site Tests \(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func site(_ host: String, in folder: URL) -> Site {
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
        #expect(set == .done(message: "A new site gets Apache and PHP 8.4. The sites that exist do not change."))
        #expect(read == .siteDefaults(SiteDefaults(server: .apache, php: "8.4")))
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

    // The engine stops also when a step throws, so no watch or process stays after the test.
    private func whileRunning(_ engine: NexusEngine, _ steps: () async throws -> Void) async throws {
        do {
            try await steps()
        } catch {
            await engine.shutdown()
            throw error
        }

        await engine.shutdown()
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
        let root = URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()

        for runtime in ["nginx/1.30", "php/8.5"] {
            let parts = runtime.split(separator: "/").map(String.init)
            let link = paths.runtime(parts[0], line: parts[1])
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: runtime))
        }

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

    // A project with its public folder after a short wait, as composer create-project makes it.
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
    private func page(_ host: String, port: Int, expecting expected: String) async -> String? {
        let deadline = ContinuousClock.now + .seconds(15)
        var body: String?

        while body != expected, ContinuousClock.now < deadline {
            let curl = Process()
            curl.executableURL = URL(filePath: "/usr/bin/curl")
            curl.arguments = ["-sk", "--max-time", "2", "--resolve", "\(host):\(port):127.0.0.1", "https://\(host):\(port)/"]
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
