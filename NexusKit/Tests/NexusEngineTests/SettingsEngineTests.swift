import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusTestSupport
import Testing
@testable import NexusEngine

// The dev TLD, the account for new instances and the root CA of Settings (step 6, part 6g). The
// engine has no nginx and no PHP. So the sites do not run, and only their names change.
extension NexusEngineTests {
    private func dig(_ name: String, port: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/dig")
        process.arguments = ["@127.0.0.1", "-p", String(port), "+short", "+time=2", "+tries=1", name]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeResolver(_ tld: String, in root: URL) throws {
        let folder = root.appending(path: "etc/resolver", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(SystemDNSFiles.resolverContents(port: 10053).utf8).write(to: folder.appending(path: tld))
    }

    private func tldState(projects: URL, parked: URL) -> EngineState {
        var shop = site("shop.test", in: projects)
        shop.aliases = ["www.shop.test", "shop.local"]
        var state = EngineState()
        state.sites = [shop]
        state.parked = [ParkedFolder(folder: parked, php: "8.5")]
        state.siteLayout = [.group(name: "Work", hosts: ["shop.test", "blog.test"])]
        return state
    }

    @Test func aNewTLDGivesEverySiteItsNewNameAndMovesTheResolverFile() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parked.appending(path: "blog"), withIntermediateDirectories: true)
        let engine = try makeSiteEngine(root: root, state: tldState(projects: root.appending(path: "projects"), parked: parked))
        try writeResolver("test", in: root)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let dnsPort = try #require(await engine.stateStore.current().ports[NexusEngine.dnsServiceID])

            let response = await engine.handle(.tld("internal"))
            let state = await engine.stateStore.current()
            let list = await engine.siteList()

            guard case .done(let message) = response else {
                Issue.record("the TLD did not change: \(response)")
                return
            }
            #expect(message.hasPrefix("The dev TLD is .internal now. Every site has a new name, for example blog.internal."))
            #expect(state.tld == "internal")
            #expect(state.sites.first?.hosts == ["shop.internal", "www.shop.internal", "shop.local"])
            #expect(state.siteLayout == [.group(name: "Work", hosts: ["shop.internal", "blog.internal"])])
            #expect(list.tld == "internal")
            #expect(list.sites.map(\.hosts) == [["blog.internal"], ["shop.internal", "www.shop.internal", "shop.local"]])
            #expect(helper.requests.contains(.setResolver(tld: "internal", port: dnsPort)))
            #expect(helper.requests.contains(.removeResolver(tld: "test")))
            #expect(await engine.writtenHosts == ["shop.local"])
            #expect(try dig("shop.internal", port: dnsPort) == "127.0.0.1")
            #expect(try dig("shop.test", port: dnsPort).isEmpty)
            #expect(await engine.handle(.tld(nil)) == .done(message: "The dev TLD is .internal."))
        }
    }

    @Test func aNewTLDThatGivesTwoSitesOneNameChangesNothing() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        var state = EngineState()
        var blog = site("blog.test", in: projects)
        blog.aliases = ["shop.internal"]
        state.sites = [site("shop.test", in: projects), blog]
        let engine = try makeSiteEngine(root: root, state: state)

        try await whileRunning(engine) {
            await engine.startEnabledServices()

            let response = await engine.handle(.tld("internal"))

            #expect(response == .failure(message: "Nexus did not change the dev TLD, because two names would become shop.internal. Remove one of them from its site first."))
            #expect(await engine.stateStore.current().tld == "test")
            #expect(!helper.requests.contains { if case .setResolver("internal", _) = $0 { true } else { false } })
        }
    }

    @Test func aNewTLDThatHidesTheSiteOfAParkedFolderChangesNothing() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parked.appending(path: "blog"), withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [site("blog.internal", in: root.appending(path: "projects", directoryHint: .isDirectory))]
        state.parked = [ParkedFolder(folder: parked, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)

        try await whileRunning(engine) {
            await engine.startEnabledServices()

            let response = await engine.handle(.tld("internal"))

            #expect(response == .failure(message: "Nexus did not change the dev TLD, because blog.internal would be the name of an added site and of a site in a parked folder. Remove the name from the added site first."))
            #expect(await engine.stateStore.current().tld == "test")
        }
    }

    @Test func aRefusedResolverFileForTheNewTLDChangesNothing() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parked.appending(path: "blog"), withIntermediateDirectories: true)
        let state = tldState(projects: root.appending(path: "projects"), parked: parked)
        let engine = try makeSiteEngine(root: root, state: state)
        helper.refuseResolver(for: "internal")

        try await whileRunning(engine) {
            await engine.startEnabledServices()

            let response = await engine.handle(.tld("internal"))
            let invalid = await engine.handle(.tld("dev"))
            let after = await engine.stateStore.current()

            guard case .failure(let message) = response else {
                Issue.record("the TLD changed: \(response)")
                return
            }
            #expect(message.hasPrefix("Nexus did not change the dev TLD, because /etc/resolver/internal was not written. Nothing changed."))
            #expect(invalid == .failure(message: ".dev cannot be the dev TLD. Nexus supports .internal, .localhost, .test."))
            #expect(after.tld == "test")
            #expect(after.sites == state.sites)
            #expect(after.siteLayout == state.siteLayout)
        }
    }

    @Test func uninstallRemovesTheResolverFileOfAnOldTLDToo() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        try writeResolver("test", in: root)
        try writeResolver("internal", in: root)

        let response = await engine.handle(.uninstall)
        try await Task.sleep(for: .seconds(1.5))

        guard case .done = response else {
            Issue.record("uninstall failed: \(response)")
            return
        }
        #expect(helper.requests == [.removeResolver(tld: "internal"), .removeResolver(tld: "test"), .setHosts([])])
    }

    @Test func theAccountForNewInstancesIsCheckedAndReachesTheApp() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        try await whileRunning(engine) {
            let refused = await engine.handle(.setNewInstanceAccount(DatabaseAccount(user: "root user", password: "")))
            let changed = await engine.handle(.setNewInstanceAccount(DatabaseAccount(user: "dev", password: "secret")))
            let events = await engine.events()
            var list: ServiceList?
            for await case .services(let services) in events {
                list = services
                break
            }

            #expect(refused == .failure(message: "root user is not a user name that Nexus can use. Use 1 to 32 characters: letters, digits, _, - and dots."))
            #expect(changed == .done(message: "A new instance gets the user dev with a password. The instances that have data keep their account."))
            #expect(await engine.stateStore.current().newInstanceAccount == DatabaseAccount(user: "dev", password: "secret"))
            #expect(list?.newInstanceAccount == DatabaseAccount(user: "dev", password: "secret"))
        }
    }

    @Test func theRootCertificateShowsWhetherMacOSTrustsIt() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)

        let before = await engine.handle(.rootCertificate)
        _ = await engine.handle(.certificate(hosts: ["shop.test"]))
        let made = await engine.handle(.rootCertificate)
        _ = await engine.handle(.trust)
        let trusted = await engine.handle(.rootCertificate)

        guard case .rootCertificate(let none) = before, case .rootCertificate(let untrusted) = made, case .rootCertificate(let info) = trusted else {
            Issue.record("no root certificate info: \(before) \(made) \(trusted)")
            return
        }
        #expect(!none.trusted)
        #expect(none.validUntil == nil)
        #expect(!untrusted.trusted)
        #expect(untrusted.validUntil != nil)
        #expect(info.trusted)
        #expect(info.validUntil == untrusted.validUntil)
        #expect(FileManager.default.fileExists(atPath: info.file))
    }
}
