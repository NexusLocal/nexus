import Foundation
import Testing
@testable import NexusCore

struct SiteMapTests {
    private let shop = SiteMap.Entry(place: DumpPlace(site: "shop.test"), host: "shop.test")
    private let fix = SiteMap.Entry(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "shop-fix.test")
    private let blog = SiteMap.Entry(place: DumpPlace(site: "blog.test"), host: "blog.test")

    private var hosts: [String: SiteMap.Entry] {
        ["shop.test": shop, "shop-fix.test": fix, "blog.test": blog]
    }

    private var folders: [String: SiteMap.Entry] {
        ["/Sites/shop": shop, "/Sites/shop/.worktrees/fix": fix, "/Sites/blog": blog]
    }

    private var map: SiteMap {
        SiteMap(hosts: hosts, folders: folders)
    }

    private func request(host: String? = nil, root: String? = nil) -> DumpedRequest {
        DumpedRequest(id: "a1", kind: host == nil ? .command : .http, target: "/", host: host, root: root, started: Date(timeIntervalSince1970: 1_794_414_394))
    }

    @Test func theHostDecidesBeforeTheRoot() {
        #expect(map.place(of: request(host: "shop.test", root: "/Sites/blog/public")) == DumpPlace(site: "shop.test"))
    }

    @Test func anUnknownHostOrACommandFindsTheLongestFolderThatHoldsItsRoot() {
        #expect(map.place(of: request(host: "news.blog.test", root: "/Sites/blog/public")) == DumpPlace(site: "blog.test"))
        #expect(map.place(of: request(root: "/Sites/shop/.worktrees/fix/app")) == DumpPlace(site: "shop.test", workspace: "fix"))
        #expect(map.place(of: request(root: "/Sites/shop/")) == DumpPlace(site: "shop.test"))
        #expect(map.entry(holding: "/Sites/shop/.worktrees/fix")?.host == "shop-fix.test")
    }

    @Test func theLocationOfARequestHasThePlaceTheFirstHostAndTheProjectFolder() {
        let fixEntry = SiteMap.Entry(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "shop-fix.test", projectFolder: "/Sites/shop/.worktrees/fix")
        let map = SiteMap(hosts: ["shop-fix.test": fixEntry])

        #expect(map.location(of: request(host: "shop-fix.test")) == DumpLocation(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "shop-fix.test", projectFolder: "/Sites/shop/.worktrees/fix"))
        #expect(map.location(of: request(host: "other.test")) == DumpLocation())
    }

    @Test func aRequestOutsideEverySiteHasNoPlace() {
        #expect(map.entry(of: request(root: "/Sites/shopping")) == nil)
        #expect(map.entry(of: request(host: "other.test")) == nil)
        #expect(map.entry(holding: "/") == nil)
        #expect(map.entry(holding: "shop.test") == nil)
        #expect(map.place(of: request()) == DumpPlace())
    }

    @Test func theSameMapIsNoChange() {
        let shared = SharedSiteMap(map)

        let same = shared.set(map)
        let other = shared.set(SiteMap(hosts: ["shop.test": shop]))

        #expect(!same)
        #expect(other)
        #expect(shared.current.entry(of: request(host: "blog.test")) == nil)
    }

    @Test func aSiteOnPublicGetsItsProjectFolderAndOnlyAPHPSiteGetsItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus Site Map \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "shop", directoryHint: .isDirectory)
        let publicFolder = project.appending(path: "public", directoryHint: .isDirectory)
        let app = root.appending(path: "app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))
        var map = SiteMap()

        map.add(Site(host: "shop.test", folder: publicFolder, aliases: ["shop.local"], php: "8.5"), place: DumpPlace(site: "shop.test"))
        map.add(Site(host: "app.test", folder: app, php: "8.5", runsAs: .node), place: DumpPlace(site: "app.test"))
        map.add(Site(host: "shop.test", folder: app, php: "8.5"), place: DumpPlace(site: "other.test"))

        #expect(map.entry(holding: "\(RealPath.of(project))/artisan")?.host == "shop.test")
        #expect(map.hosts["shop.local"] == SiteMap.Entry(place: DumpPlace(site: "shop.test"), host: "shop.test", projectFolder: RealPath.of(project)))
        #expect(map.folders[RealPath.of(app)]?.projectFolder == RealPath.of(app))
        #expect(map.hosts["shop.test"]?.place == DumpPlace(site: "shop.test"))
        #expect(map.folders[RealPath.of(app)]?.host == "app.test")
        #expect(map.phpSites.map(\.env.lastPathComponent) == [".env", ".env"])
        #expect(map.phpSites.first?.env.path(percentEncoded: false) == "\(RealPath.of(project))/.env")
        #expect(map.phpSites.first?.userIni.path(percentEncoded: false) == "\(RealPath.of(publicFolder))/.user.ini")
    }

    @Test(arguments: [false, true])
    func aSiteOnTheProjectFolderWinsOverTheProjectFolderOfASiteOnPublic(siteOnPublicFirst: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus Site Map \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "p", directoryHint: .isDirectory)
        let publicFolder = project.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))
        let onPublic = Site(host: "a.test", folder: publicFolder, php: "8.5")
        let onProject = Site(host: "b.test", folder: project, php: "8.5")
        var map = SiteMap()

        for site in siteOnPublicFirst ? [onPublic, onProject] : [onProject, onPublic] {
            map.add(site, place: DumpPlace(site: site.host))
        }

        #expect(map.entry(holding: "\(RealPath.of(publicFolder))/index.php")?.host == "a.test")
        #expect(map.entry(holding: RealPath.of(project))?.host == "b.test")
        #expect(map.entry(holding: "\(RealPath.of(project))/artisan")?.host == "b.test")
    }

    @Test func noPlaceIncludesAllPlaces() {
        let all: DumpPlace? = nil
        let shopOnly: DumpPlace? = DumpPlace(site: "shop.test")

        #expect(all.includes(DumpPlace(site: "blog.test")))
        #expect(all.includes(DumpPlace()))
        #expect(shopOnly.includes(DumpPlace(site: "shop.test")))
        #expect(!shopOnly.includes(DumpPlace(site: "shop.test", workspace: "fix")))
    }
}
