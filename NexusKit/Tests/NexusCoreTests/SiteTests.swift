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
}
