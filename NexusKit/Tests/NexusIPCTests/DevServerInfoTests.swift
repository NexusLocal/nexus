import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct DevServerInfoTests {
    private func siteList(state: DevServerInfo.State = .waitsForPage, stop: DevServerStop = .fiveMinutes) -> SiteList {
        let devServer = DevServerInfo(command: "npm run dev", port: 20_001, state: state, log: "/logs/main-shop.test.log")
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, devServer: devServer)
        let site = SiteInfo(hosts: ["shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", workspaces: [workspace], devServer: devServer)

        return SiteList(sites: [site], layout: [], parkedFolders: [], defaults: SiteDefaults(), tld: "test", devServerStop: stop)
    }

    @Test func theDevServersAndTheSettingSurviveTheWire() throws {
        let list = siteList(state: .outsideNexus, stop: .never)
        let decoded = try NexusMessageCoding.decode(SiteList.self, from: NexusMessageCoding.encode(list))

        #expect(decoded == list)
    }

    @Test func aDevServerThatALinkWithBuildHoldsBackSurvivesTheWire() throws {
        let list = siteList(state: .pausedForLink)
        let text = String(decoding: try NexusMessageCoding.encode(list), as: UTF8.self)
        let decoded = try NexusMessageCoding.decode(SiteList.self, from: Data(text.utf8))

        #expect(text.contains("\"paused_for_link\""))
        #expect(decoded == list)
        #expect(decoded.sites.first?.devServer?.text == "npm run dev does not run while a public link of this site uses Build.")
    }

    @Test func aStateAndANumberOfMinutesOfANewerNexusdGiveNilAndTheListStillDecodes() throws {
        let text = String(decoding: try NexusMessageCoding.encode(siteList()), as: UTF8.self)
            .replacing("\"waits_for_page\"", with: "\"sleeps\"")
            .replacing("\"devServerStop\":5", with: "\"devServerStop\":7")

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: Data(text.utf8))

        #expect(text.contains("\"sleeps\""))
        #expect(text.contains("\"devServerStop\":7"))
        #expect(decoded.devServerStop == nil)
        #expect(decoded.sites.first?.devServer == nil)
        #expect(decoded.sites.first?.workspaces?.first?.devServer == nil)
        #expect(decoded.sites.first?.workspaces?.first?.name == "fix")
        #expect(decoded.sites.first?.hosts == ["shop.test"])
    }
}
