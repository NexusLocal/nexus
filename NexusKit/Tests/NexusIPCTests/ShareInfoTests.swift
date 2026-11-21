import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct ShareInfoTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static let changedOptions = ShareOptions(duration: .oneHour, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .ownDomain)

    static func link(_ host: String = "shop.test", workspace: String? = nil, state: ShareState = .open) -> ShareInfo {
        ShareInfo(
            host: host,
            site: "shop.test",
            workspace: workspace,
            url: "https://calm-river-tree-lamp.trycloudflare.com",
            state: state,
            options: changedOptions,
            started: started,
            endsAt: started.addingTimeInterval(3_600),
            password: "secret",
            visitors: 2,
            lastVisit: started.addingTimeInterval(60),
            requestCount: 12,
            usesVite: true,
            liveBlocked: "Vite 5.4.2 is too old for Live.",
            log: "/logs/cloudflared-\(host).log"
        )
    }

    static func siteList() -> SiteList {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, share: link("fix.shop.test", workspace: "fix", state: .ended(.failed("cloudflared stopped."))))
        let site = SiteInfo(hosts: ["shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", workspaces: [workspace], share: link())
        let domain = OwnDomainInfo(domain: "example.com", tunnelName: "nexus-macbook-pro", state: .connecting(loginPage: "https://dash.cloudflare.com/argotunnel"), addresses: ["shop.example.com"])

        return SiteList(sites: [site], layout: [], parkedFolders: [], defaults: SiteDefaults(), tld: "test", shareDefaults: changedOptions, ownDomain: domain)
    }

    static let requests: [NexusRequest] = [
        .shares,
        .sharePreview(host: "shop.test"),
        .startShare(ShareStart(host: "shop.test")),
        .startShare(ShareStart(host: "shop.test", duration: .untilStopped, password: true, hidesErrors: false, viteMode: .build, keepsRequests: true, address: .ownDomain, label: "shop")),
        .stopShare(host: "shop.test"),
        .stopAllShares(appQuit: true),
        .stopAllShares(appQuit: false),
        .setShareDefaults(changedOptions),
        .rebuildShare(host: "shop.test"),
        .shareRequest(id: "5f2b0c9d8e7a6b5c4d3e2f1a0b9c8d7e"),
        .clearLinkRequests(host: "shop.test"),
        .clearLinkRequests(host: nil),
        .checkOwnDomain(domain: "example.com"),
        .connectOwnDomain(domain: "example.com"),
        .cancelOwnDomain,
        .disconnectOwnDomain,
        .fromAgent(agent: "claude", request: .sharePreview(host: "shop.test")),
    ]

    static let responses: [NexusResponse] = [
        .shares([link(), link("fix.shop.test", workspace: "fix", state: .starting(.buildAssets))]),
        .share(link(state: .ended(.sleep))),
        .sharePreview(SharePreview(host: "shop.test", defaults: changedOptions, usesVite: true, liveBlocked: "Vite 5.4.2 is too old for Live.", refusal: "Build cannot run.", warnings: ShareWarning.allCases, extraHosts: ["cms.shop.test"], ownDomain: "example.com", label: "shop", openLink: link())),
        .sharePreview(SharePreview(host: "shop.test", defaults: .standard)),
        .shareRequest(ShareRequestDetail(id: "5f2b", requestHeaders: [ShareHeader(name: "Cookie", value: "hidden")], requestBody: #"{"a":1}"#, requestBodyBytes: 7, requestBodyCut: false, status: 200, responseHeaders: [ShareHeader(name: "Content-Type", value: "application/json")], size: 2_048)),
        .ownDomainCheck(OwnDomainCheck(domain: "example.com", usesCloudflare: false, nameservers: ["ns1.example.net", "ns2.example.net"])),
        .ownDomainCheck(OwnDomainCheck(domain: "example.com", usesCloudflare: nil, nameservers: [])),
        .ownDomainRemoval(OwnDomainRemoval(removedRecords: ["shop.example.com"], keptRecords: ["blog.example.com"])),
        .ownDomainRemoval(OwnDomainRemoval(removedRecords: [], keptRecords: ["shop.example.com"], keptTunnel: "nexus-macbook-pro")),
    ]

    @Test(arguments: requests)
    func eachRequestOfTheLinksIsReadWithoutLoss(request: NexusRequest) throws {
        let data = try NexusMessageCoding.encode(request)

        #expect(try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data) == request)
    }

    @Test(arguments: responses)
    func eachAnswerOfTheLinksSurvivesTheWireWithoutLoss(response: NexusResponse) throws {
        let data = try NexusMessageCoding.encode(response)

        #expect(try NexusMessageCoding.decodeWithoutLoss(NexusResponse.self, from: data) == response)
    }

    @Test func theLinksTheDefaultsAndTheDomainSurviveTheWire() throws {
        let list = Self.siteList()

        let decoded = try NexusMessageCoding.decodeWithoutLoss(SiteList.self, from: NexusMessageCoding.encode(list))

        #expect(decoded == list)
        #expect(decoded.sites.first?.share?.url == "https://calm-river-tree-lamp.trycloudflare.com")
        #expect(decoded.sites.first?.workspaces?.first?.share?.state == .ended(.failed("cloudflared stopped.")))
    }

    @Test func aStateOfANewerNexusdGivesNilAndTheListStillDecodes() throws {
        let text = String(decoding: try NexusMessageCoding.encode(Self.siteList()), as: UTF8.self)
            .replacing(#"{"open":{}}"#, with: #"{"paused":{}}"#)
            .replacing(#""failed":{"_0":"cloudflared stopped."}"#, with: #""crashed":{}"#)
            .replacing(#""connecting":{"loginPage""#, with: #""waiting":{"loginPage""#)

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: Data(text.utf8))

        #expect(text.contains(#"{"paused":{}}"#))
        #expect(text.contains(#""crashed":{}"#))
        #expect(text.contains(#""waiting":{"loginPage""#))
        #expect(decoded.sites.first?.share == nil)
        #expect(decoded.sites.first?.workspaces?.first?.share == nil)
        #expect(decoded.ownDomain == nil)
        #expect(decoded.sites.first?.workspaces?.first?.name == "fix")
        #expect(decoded.sites.first?.hosts == ["shop.test"])
        #expect(decoded.shareDefaults == Self.changedOptions)
    }

    @Test func aDurationOfANewerNexusdInTheDefaultsGivesEightHours() throws {
        let text = String(decoding: try NexusMessageCoding.encode(Self.siteList()), as: UTF8.self)
            .replacing(#""duration":60"#, with: #""duration":30"#)

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: Data(text.utf8))

        #expect(text.contains(#""duration":30"#))
        #expect(decoded.shareDefaults?.duration == .eightHours)
        #expect(decoded.shareDefaults?.viteMode == .build)
    }

    @Test func aListOfANexusdFromBefore4bHasNoLinks() throws {
        let data = Data(#"{"sites":[{"hosts":["shop.test"],"folder":"/w/shop","documentRoot":"/w/shop/public","php":"8.4","server":"nginx","parked":false,"url":"https://shop.test","workspaces":[{"name":"fix","worktree":"/w/fix","folder":"/w/fix"}]}],"layout":[],"parkedFolders":[],"defaults":{"php":"8.4","server":"nginx"},"tld":"test"}"#.utf8)

        let decoded = try NexusMessageCoding.decode(SiteList.self, from: data)

        #expect(decoded.sites.first?.share == nil)
        #expect(decoded.sites.first?.workspaces?.first?.share == nil)
        #expect(decoded.shareDefaults == nil)
        #expect(decoded.ownDomain == nil)
    }

    @Test func aDurationThatNexusdDoesNotKnowIsRefusedWithItsName() {
        let data = Data(#"{"setShareDefaults":{"_0":{"duration":30,"password":false,"hidesErrors":true,"viteMode":"live","keepsRequests":false,"address":"random"}}}"#.utf8)

        let error = #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }

        #expect(error?.path == "setShareDefaults._0.duration")
    }

    @Test func anOptionOfTheStartThatNexusdDoesNotKnowIsRefusedWithItsName() {
        let data = Data(#"{"startShare":{"_0":{"host":"shop.test","pin":true}}}"#.utf8)

        let error = #expect(throws: UnknownRequestFields.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }

        #expect(error?.path == "startShare._0.pin")
    }

    @Test func aStartWithAValueThatNexusdDoesNotKnowIsNotRead() {
        let data = Data(#"{"startShare":{"_0":{"host":"shop.test","duration":30}}}"#.utf8)

        #expect(throws: DecodingError.self) {
            try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)
        }
    }

    @Test func aStartWithoutOptionsSendsOnlyTheHost() throws {
        let data = try NexusMessageCoding.encode(ShareStart(host: "shop.test"))

        #expect(String(decoding: data, as: UTF8.self) == #"{"host":"shop.test"}"#)
    }

    @Test func theDefaultsOfAnOlderCommandWithFewerFieldsAreRead() throws {
        let data = Data(#"{"setShareDefaults":{"_0":{"duration":60}}}"#.utf8)

        let request = try NexusMessageCoding.decodeWithoutLoss(NexusRequest.self, from: data)

        #expect(request == .setShareDefaults(ShareOptions(duration: .oneHour, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .random)))
    }

    @Test func theSheetSeesOnlyTheSetupOfItsOwnDomain() {
        let setup = OwnDomainInfo(domain: "example.com", state: .connecting(loginPage: nil))
        let failed = OwnDomainInfo(domain: "example.com", state: .failed("No key.", keyMade: true))

        #expect(setup.state(of: "example.com") == .connecting(loginPage: nil))
        #expect(failed.state(of: "example.com") == .failed("No key.", keyMade: true))
        #expect(setup.state(of: "other.com") == nil)
        #expect(failed.state(of: "example.org") == nil)
    }
}
