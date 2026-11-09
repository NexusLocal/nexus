import Foundation
import Testing
@testable import NexusCore

struct SiteTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Sites \(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeFolder(_ path: String) throws -> URL {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theDocumentRootIsPublicWhenItExists() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let laravel = try makeFolder("laravel")
        _ = try makeFolder("laravel/public")
        let plain = try makeFolder("plain")

        #expect(Site(host: "a.test", folder: laravel, php: "8.5").documentRoot.lastPathComponent == "public")
        #expect(Site(host: "b.test", folder: plain, php: "8.5").documentRoot.lastPathComponent == "plain")
    }

    @Test func aChosenDocumentRootComesBeforePublic() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let laravel = try makeFolder("laravel")
        _ = try makeFolder("laravel/public")
        _ = try makeFolder("laravel/htdocs")

        let site = Site(host: "a.test", folder: laravel, php: "8.5", documentRootFolder: "htdocs")

        #expect(site.documentRoot.lastPathComponent == "htdocs")
    }

    @Test func aDocumentRootIsStoredAsAFolderInTheSiteFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try makeFolder("site")
        let nested = try makeFolder("site/build/web")

        #expect(try Site.documentRootFolder("build/web", in: site) == "build/web")
        #expect(try Site.documentRootFolder("./build/web/", in: site) == "build/web")
        #expect(try Site.documentRootFolder(nested.path(percentEncoded: false), in: site) == "build/web")
    }

    @Test func anEmptyDocumentRootOrTheSiteFolderIsAutomatic() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try makeFolder("site")

        #expect(try Site.documentRootFolder("", in: site) == nil)
        #expect(try Site.documentRootFolder(".", in: site) == nil)
        #expect(try Site.documentRootFolder(site.path(percentEncoded: false), in: site) == nil)
    }

    @Test func aDocumentRootOutsideTheSiteFolderIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try makeFolder("site")
        _ = try makeFolder("other")

        #expect(throws: DocumentRootError.outside("../other")) { try Site.documentRootFolder("../other", in: site) }
        #expect(throws: DocumentRootError.missing("dist")) { try Site.documentRootFolder("dist", in: site) }
    }

    @Test func aWorkspaceFileIsAPathInTheProjectFolder() throws {
        #expect(try Site.workspaceFile(" /storage/certs/ ") == "storage/certs")
        #expect(throws: WorkspaceFileError.invalid("../secrets")) { try Site.workspaceFile("../secrets") }
        #expect(throws: WorkspaceFileError.automatic(".env")) { try Site.workspaceFile(".env") }
        #expect(throws: WorkspaceFileError.automatic("vendor/bin")) { try Site.workspaceFile("vendor/bin") }
    }

    @Test func aWorkspaceServesTheSameDocumentRoot() {
        let main = Site(host: "shop.test", folder: URL(filePath: "/w/shop", directoryHint: .isDirectory), php: "8.5", documentRootFolder: "htdocs")
        let workspace = Workspace(name: "fix", worktree: "/w/fix", folder: "/w/fix")

        #expect(workspace.site(of: [main], tld: "test")?.documentRoot.path(percentEncoded: false) == "/w/fix/htdocs/")
    }

    @Test func eachSubfolderOfAParkedFolderIsASite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = try makeFolder("parked")
        _ = try makeFolder("parked/My Shop")
        _ = try makeFolder("parked/api_v2")
        _ = try makeFolder("parked/.hidden")
        try Data().write(to: parked.appending(path: "notes.txt"))

        let sites = ParkedFolder(folder: parked, php: "8.4", server: .apache).sites(tld: "test")

        #expect(sites.map(\.host) == ["api-v2.test", "my-shop.test"])
        #expect(sites.allSatisfy { $0.php == "8.4" && $0.server == .apache })
    }

    @Test func aLinkToAFolderInAParkedFolderIsASite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = try makeFolder("parked")
        let code = try makeFolder("code/shop")
        try FileManager.default.createSymbolicLink(at: parked.appending(path: "shop"), withDestinationURL: code)

        let sites = ParkedFolder(folder: parked, php: "8.5").sites(tld: "test")

        #expect(sites.map(\.host) == ["shop.test"])
    }

    @Test func aFolderNameBecomesALabel() {
        #expect(HostName.label(from: "My Shop_2") == "my-shop-2")
        #expect(HostName.label(from: "--Café--") == "caf")
        #expect(HostName.label(from: String(repeating: "a", count: 80)).count == 63)
    }

    @Test func anAliasWithAStarWorksOnlyInTheDevDomain() throws {
        #expect(try HostName.validatedAlias("*.Shop.test", tld: "test") == "*.shop.test")
        #expect(try HostName.validatedAlias("www.shop.test", tld: "test") == "www.shop.test")
        #expect(throws: HostNameError.wildcardOutsideDevTLD("*.shop.local", tld: "test")) { try HostName.validatedAlias("*.shop.local", tld: "test") }
        #expect(throws: HostNameError.invalidHost("test")) { try HostName.validatedAlias("*.test", tld: "test") }
        #expect(throws: HostNameError.self) { try HostName.validatedAlias("a.*.shop.test", tld: "test") }
        #expect(throws: HostNameError.self) { try HostName.validated("*.shop.test") }
        #expect(HostName.workspaceHost("*.shop.test", workspace: "fix", tld: "test") == "*.shop-fix.test")
    }

    @Test func aNewTLDChangesOnlyTheNamesInTheOldTLD() {
        let site = Site(host: "shop.test", folder: root, aliases: ["www.shop.test", "shop.local", "test.local"], php: "8.5")

        let moved = site.movingTLD(from: "test", to: "internal")
        let layout = SiteLayoutEntry.group(name: "Work", hosts: ["shop.test", "blog.local"]).movingTLD(from: "test", to: "internal")

        #expect(moved.hosts == ["shop.internal", "www.shop.internal", "shop.local", "test.local"])
        #expect(layout == .group(name: "Work", hosts: ["shop.internal", "blog.local"]))
        #expect(HostName.movingTLD("contest", from: "test", to: "internal") == "contest")
    }

    @Test func versionLinesCompareByNumber() {
        #expect(VersionLine.isOlder("8.2", than: "8.10"))
        #expect(VersionLine.newest(["8.4", "8.10", "8.5"]) == "8.10")
    }

    @Test func aSiteFromBeforeNodeSitesIsAPHPSite() throws {
        let stored = #"{"host":"shop.test","folder":"file:///Sites/shop/","aliases":[],"php":"8.5","server":"apache"}"#

        let site = try JSONDecoder().decode(Site.self, from: Data(stored.utf8))

        #expect(site.kind == .php)
        #expect(site.usedPHP == "8.5")
        #expect(site.usesApache)
    }

    @Test func onlyAPHPSiteUsesPHPAndApache() {
        let node = Site(host: "shop.test", folder: root, php: "8.5", server: .apache, runsAs: .node)
        let proxy = Site(host: "api.test", folder: root, php: "8.5", runsAs: .proxy, address: "http://127.0.0.1:3000")

        #expect(node.usedPHP == nil)
        #expect(!node.usesApache)
        #expect(node.createsWorkspaces)
        #expect(proxy.usedPHP == nil)
        #expect(!proxy.createsWorkspaces)
    }

    @Test func aProxyAddressGetsASchemeAHostAndAPort() throws {
        #expect(try ProxyAddress.validated("3000") == "http://127.0.0.1:3000")
        #expect(try ProxyAddress.validated(" LocalHost:5173 ") == "http://localhost:5173")
        #expect(try ProxyAddress.validated("http://[::1]:8000/") == "http://[::1]:8000")
        #expect(try ProxyAddress.validated("HTTPS://192.0.2.10") == "https://192.0.2.10:443")
        #expect(try ProxyAddress.validated("192.0.2.10") == "http://192.0.2.10:80")
    }

    @Test func aProxyAddressWithANameAPathAUserOrAnotherSchemeIsRefused() {
        for address in ["", "http://127.0.0.1:3000/api", "http://user@127.0.0.1:3000", "ftp://127.0.0.1:21", "http://127.0.0.1:99999", "http://a$b:3000", "http://127.0.0.1:3000?x=1", "shop.test:3000", "https://api.example.com", "http://256.1.1.1:80", "http://[::g]:80"] {
            #expect(throws: ProxyAddressError.self) {
                try ProxyAddress.validated(address)
            }
        }
    }

    @Test func onlyAnAddressOfThisMacHasAPortOnThisMac() {
        let interfaces: Set<String> = ["192.0.2.55", "fe80::1"]

        #expect(ProxyAddress.portOnThisMac(of: "http://127.0.0.1:8443", interfaces: interfaces) == 8443)
        #expect(ProxyAddress.portOnThisMac(of: "http://127.0.1.1:80", interfaces: interfaces) == 80)
        #expect(ProxyAddress.portOnThisMac(of: "http://0.0.0.0:80", interfaces: interfaces) == 80)
        #expect(ProxyAddress.portOnThisMac(of: "http://[::1]:3000", interfaces: interfaces) == 3000)
        #expect(ProxyAddress.portOnThisMac(of: "http://localhost:80", interfaces: interfaces) == 80)
        #expect(ProxyAddress.portOnThisMac(of: "http://192.0.2.55:8443", interfaces: interfaces) == 8443)
        #expect(ProxyAddress.portOnThisMac(of: "http://[fe80::1]:8443", interfaces: interfaces) == 8443)
        #expect(ProxyAddress.portOnThisMac(of: "http://192.0.2.10:8443", interfaces: interfaces) == nil)
    }

    @Test func theInterfaceAddressesHoldTheLoopback() {
        #expect(ProxyAddress.interfaceAddresses().contains("127.0.0.1"))
    }
}
