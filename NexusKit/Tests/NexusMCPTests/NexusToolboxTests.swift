import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusMCP

private actor FakeNexus: NexusConnecting {
    let running: Bool
    let change: ProgramChange?
    let changeAfterSites: Bool
    let caught: [DumpedRequest]
    let entries: [CaughtDump]
    let link: ShareInfo
    let details: [String: ShareRequestDetail]
    var requests: [NexusRequest] = []

    init(running: Bool = true, change: ProgramChange? = nil, changeAfterSites: Bool = false, caught: [DumpedRequest] = [], entries: [CaughtDump] = [], link: ShareInfo = NexusToolboxTests.openLink, details: [String: ShareRequestDetail] = [:]) {
        self.running = running
        self.change = change
        self.changeAfterSites = changeAfterSites
        self.caught = caught
        self.entries = entries
        self.link = link
        self.details = details
    }

    func send(_ request: NexusRequest) async throws -> NexusResponse {
        if let change, !(changeAfterSites && request.inner == .sites) {
            throw NexusClientError.programChanged(change)
        }

        guard running else {
            throw NexusClientError.daemonNotRunning("test")
        }

        requests.append(request)

        switch request.inner {
        case .sites:
            let workspace = WorkspaceInfo(name: "fix", worktree: "/w/shop-fix", folder: "/w/shop-fix", hosts: ["shop-fix.test"], url: "https://shop-fix.test", state: .ready, runState: .stopped, share: NexusToolboxTests.endedLink)
            return .sites([SiteInfo(hosts: ["shop.test"], folder: "/w/shop/public", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", workspaces: [workspace], projectType: .laravel, share: link)])
        case .tool:
            return .failure(message: "No PHP in this test.")
        case .databaseConnections:
            return .databaseConnections([])
        case .siteMail:
            return .siteMail(SiteMail(sendsToNexus: true))
        case .mailStatus:
            return .mailStatus(MailStatus(installed: true, running: true, receiving: true, smtpPort: 1025, inboxPort: 8025, waiting: 0, waitingBytes: 0, removed: 0, refused: 0, outboxFolder: "/tmp", settings: MailSettings()))
        case .dumpPlace(let host):
            return .dumpPlace(place: DumpPlace(site: host), host: host)
        case .dumpList(let place):
            return .dumpList(DumpList(requests: caught.filter { place.includes($0.place) }, settings: DumpSettings(catchDumps: true, catchLogs: true), receiving: true))
        case .requestDumps(let id, _):
            return .caughtDumps(entries.filter { $0.requestID == id })
        case .shareRequest(let id):
            return details[id].map(NexusResponse.shareRequest) ?? .failure(message: LinkRequestText.detailGone)
        default:
            return .done(message: "Done.")
        }
    }
}

struct NexusToolboxTests {
    static let openLink = ShareInfo(host: "shop.test", site: "shop.test", url: "https://calm-river-tree-lamp.trycloudflare.com", state: .open, options: ShareOptions(duration: .oneHour, password: true, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .random), started: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_003_600), password: "plum-river-42", visitors: 2, log: "/tmp/cloudflared-shop.test.log")
    static let endedLink = ShareInfo(host: "shop-fix.test", site: "shop.test", workspace: "fix", state: .ended(.sleep), options: .standard, started: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_028_800), log: "/tmp/cloudflared-shop-fix.test.log")

    private func toolbox(_ nexus: FakeNexus, level: AgentLevel, folder: String = "/w/shop") -> NexusToolbox {
        NexusToolbox(connection: nexus, paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")), folder: folder, loadSettings: { AgentSettings(level: level) })
    }

    @Test func anOpenLinkForTheAgentHasItsAddressItsEndAndItsVisitorsButNoPassword() throws {
        let link = AgentPublicLink(Self.openLink)
        let json = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)

        #expect(link.url == "https://calm-river-tree-lamp.trycloudflare.com")
        #expect(link.state == "open")
        #expect(link.endsAt == "2027-01-15T09:00:00Z")
        #expect(link.password)
        #expect(link.visitors == 2)
        #expect(link.requests == nil)
        #expect(link.ended == nil)
        #expect(!json.contains("plum-river-42"))
    }

    @Test func anEndedLinkForTheAgentHasTheReasonAndNoAddress() {
        let link = AgentPublicLink(Self.endedLink)

        #expect(link.state == "ended")
        #expect(link.url == nil)
        #expect(!link.password)
        #expect(link.ended == "Cloudflare removed the link during a sleep.")
    }

    @Test func siteInfoAndListSitesHaveThePublicLinkOfTheTarget() async {
        let site = await toolbox(FakeNexus(), level: .read).call("site_info", arguments: ["site": "shop.test"], agent: nil)
        let workspace = await toolbox(FakeNexus(), level: .read).call("site_info", arguments: ["site": "shop-fix.test"], agent: nil)
        let rows = await toolbox(FakeNexus(), level: .read).call("list_sites", arguments: [:], agent: nil)

        #expect(site.structured?["publicLink"]?["state"] == "open")
        #expect(site.structured?["publicLink"]?["url"] == "https://calm-river-tree-lamp.trycloudflare.com")
        #expect(workspace.structured?["publicLink"]?["state"] == "ended")
        #expect(rows.structured?["sites"]?.array?.first?["publicLink"]?["visitors"]?.int == 2)
        #expect(rows.structured?["sites"]?.array?.first?["workspaces"]?.array?.first?["publicLink"]?["state"] == "ended")
        #expect(!site.text.contains("plum-river-42"))
    }

    @Test func theInstructionsSayThatOnlyTheUserOpensALinkAndStayWhole() async {
        let text = await toolbox(FakeNexus(), level: .read, folder: "/w/shop-fix").instructions(agent: nil)

        #expect(text.contains("- Only the user opens a public link of a site. site_info shows an open link with its address."))
        #expect(text.hasSuffix("- You can only look. Ask the user to start a service or to install something."))
        #expect(text.count < AgentInstructions.longest)
    }

    @Test(arguments: [(AgentLevel.read, 12), (.change, 20), (.remove, 24)])
    func eachLevelListsItsTools(level: AgentLevel, count: Int) async {
        let tools = await toolbox(FakeNexus(), level: level).tools(agent: nil)

        #expect(tools.count == count)
        #expect(tools.allSatisfy { $0.readOnly == (NexusTools.spec($0.name)?.level == .read) })
    }

    @Test func theToolsOfTheIdleStopNeedTheLevelChange() async {
        let read = await toolbox(FakeNexus(), level: .read).tools(agent: nil).map(\.name)
        let change = await toolbox(FakeNexus(), level: .change).tools(agent: nil).map(\.name)

        #expect(!read.contains("stop_workspace"))
        #expect(!read.contains("start_workspace"))
        #expect(change.contains("stop_workspace"))
        #expect(change.contains("start_workspace"))
    }

    @Test func stopWorkspaceStopsTheWorkspaceOfItsNameForTheAgent() async {
        let nexus = FakeNexus()

        let result = await toolbox(nexus, level: .change).call("stop_workspace", arguments: ["workspace": "fix"], agent: "claude-code")

        #expect(!result.isError)
        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .stopWorkspace(host: "shop.test", name: "fix"))))
    }

    @Test func startWorkspaceWithKeepTurnsStopWhenIdleOff() async {
        let nexus = FakeNexus()

        _ = await toolbox(nexus, level: .change, folder: "/w/shop-fix/app").call("start_workspace", arguments: ["keep": true], agent: "claude-code")
        _ = await toolbox(nexus, level: .change).call("start_workspace", arguments: ["workspace": "/w/shop-fix"], agent: "claude-code")

        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .startWorkspace(host: "shop.test", name: "fix", keepAwake: true))))
        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .startWorkspace(host: "shop.test", name: "fix", keepAwake: nil))))
    }

    @Test func theCheckOfTheExtensionsIsNoActivityOfAWorkspace() async {
        let nexus = FakeNexus()

        _ = await toolbox(nexus, level: .read, folder: "/w/shop-fix").call("php_extensions", arguments: [:], agent: nil)
        let activities = await nexus.requests.compactMap { request -> Bool?? in
            guard case .tool(_, _, _, _, let activity) = request.inner else {
                return nil
            }

            return activity
        }

        #expect(activities == [false])
    }

    @Test func theInstructionsOfAWorkspaceSayThatItStopsWhenIdle() async {
        let change = await toolbox(FakeNexus(), level: .change, folder: "/w/shop-fix").instructions(agent: nil)
        let read = await toolbox(FakeNexus(), level: .read, folder: "/w/shop-fix").instructions(agent: nil)

        #expect(change.contains("- Nexus stops a workspace without activity. The next page, command or database connection starts it again."))
        #expect(change.contains("- Call stop_workspace when your work in this workspace is done."))
        #expect(change.count <= AgentInstructions.longest)
        #expect(!read.contains("stop_workspace"))
    }

    @Test func aWorkspaceForTheAgentHasItsRunState() {
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix", state: .ready, lastActivity: Date(timeIntervalSince1970: 1_763_200_000), runState: .stopped)

        #expect(AgentWorkspace(workspace).runState == "stopped")
        #expect(AgentWorkspace(workspace).lastActivity == "2025-11-15T09:46:40Z")
        #expect(AgentWorkspace(WorkspaceInfo(name: "fix", worktree: "/w/fix", folder: "/w/fix")).runState == "running")
    }

    @Test func eachToolHasAShortSummaryForTheAgentsScreen() {
        for tool in NexusTools.all {
            #expect(!tool.summary.isEmpty, "\(tool.name) has no summary")
            #expect(tool.summary.count <= 90, "The summary of \(tool.name) needs more than one line")
        }
    }

    private static let started = Date(timeIntervalSince1970: 1_762_850_000)

    private static func caught(_ id: String, site: String = "shop.test", queries: Int = 0, dumps: Int = 1) -> DumpedRequest {
        DumpedRequest(id: id, kind: .http, method: "GET", target: "/\(id)", url: "https://\(site)/\(id)", host: site, site: site, started: started, status: 200, dumpCount: dumps, queryCount: queries, queryMilliseconds: Double(queries))
    }

    private static func products(of request: String) -> [CaughtDump] {
        (1...5).map { seq in CaughtDump(requestID: request, seq: seq, time: started, kind: .query, file: "/w/shop/app/Models/CartItem.php", line: 24, text: "select * from `products` where `id` = \(seq)", milliseconds: 1, pattern: "select * from `products` where `id` = ?") }
    }

    private static func dump(of request: String, text: String = "\"EUR\"") -> CaughtDump {
        CaughtDump(requestID: request, seq: 9, time: started, file: "/w/shop/app/Http/Controllers/CheckoutController.php", line: 42, text: text)
    }

    @Test func readDumpsGivesTheNewestRequestsOfTheSiteOldestFirstWithTheirIDsAndTags() async throws {
        let nexus = FakeNexus(caught: [Self.caught("new", queries: 5, dumps: 0), Self.caught("blog", site: "blog.test"), Self.caught("old")], entries: Self.products(of: "new") + [Self.dump(of: "old"), Self.dump(of: "blog")])

        let result = await toolbox(nexus, level: .read, folder: "/w/shop/public").call("read_dumps", arguments: [:], agent: "claude-code")
        let old = try #require(result.text.range(of: "request old · 1 dump"))
        let new = try #require(result.text.range(of: "request new · 5 queries in 5 ms"))

        #expect(!result.isError)
        #expect(result.structured == nil)
        #expect(old.lowerBound < new.lowerBound)
        #expect(result.text.contains("  query  1 ms  N+1 · 5×  select * from `products` where `id` = 1  at /w/shop/app/Models/CartItem.php:24"))
        #expect(result.text.contains("    This line runs the same query 5 times with other values. One query for all values is faster. In Laravel, load the relation with with()."))
        #expect(result.text.contains("  dump at /w/shop/app/Http/Controllers/CheckoutController.php:42"))
        #expect(!result.text.contains("blog"))
        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .dumpList(place: DumpPlace(site: "shop.test")))))
        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .requestDumps(request: "new", afterNumber: 0))))
    }

    @Test func readDumpsWithALimitReadsOnlyTheNewestRequests() async {
        let nexus = FakeNexus(caught: [Self.caught("new"), Self.caught("old")], entries: [Self.dump(of: "new"), Self.dump(of: "old")])

        let result = await toolbox(nexus, level: .read).call("read_dumps", arguments: ["limit": 1], agent: nil)

        #expect(result.text.contains("request new"))
        #expect(!result.text.contains("request old"))
    }

    @Test func readDumpsWithARequestReadsThatRequestOfAnyPlace() async {
        let nexus = FakeNexus(caught: [Self.caught("blog", site: "blog.test"), Self.caught("shop")], entries: [Self.dump(of: "blog"), Self.dump(of: "shop")])

        let result = await toolbox(nexus, level: .read).call("read_dumps", arguments: ["request": "blog"], agent: nil)
        let missing = await toolbox(nexus, level: .read).call("read_dumps", arguments: ["request": "gone"], agent: nil)

        #expect(result.text.contains("request blog · 1 dump"))
        #expect(!result.text.contains("request shop"))
        #expect(await nexus.requests.contains(.fromAgent(agent: "an MCP client", request: .dumpList(place: nil))))
        #expect(missing.isError)
        #expect(missing.text.hasPrefix("Nexus has no request gone."))
    }

    @Test func readDumpsOutsideTheSitesReadsAllPlacesAndSaysWhenThereAreNone() async {
        let nexus = FakeNexus()

        let result = await toolbox(nexus, level: .read, folder: "/w/other").call("read_dumps", arguments: [:], agent: nil)
        let site = await toolbox(nexus, level: .read, folder: "/w/other").call("read_dumps", arguments: ["site": "shop.test"], agent: nil)

        #expect(result.text == "Nexus has no requests.")
        #expect(site.text == "Nexus has no requests of shop.test.")
        #expect(await nexus.requests.contains(.fromAgent(agent: "an MCP client", request: .dumpList(place: nil))))
    }

    @Test func readDumpsLeavesOutTheOldestRequestsWhenTheTextIsTooLong() async {
        let long = String(repeating: "x", count: NexusToolbox.dumpTextLimit + 10)
        let nexus = FakeNexus(caught: [Self.caught("new"), Self.caught("old")], entries: [Self.dump(of: "new", text: long), Self.dump(of: "old")])

        let result = await toolbox(nexus, level: .read).call("read_dumps", arguments: [:], agent: nil)

        #expect(result.text.hasPrefix("The text leaves out the oldest request, because it is too long. Give a lower limit or a request."))
        #expect(result.text.hasSuffix("[The text of this request stops here, because it is too long.]"))
        #expect(!result.text.contains("request old"))
    }

    private static let listedLink = ShareInfo(host: "shop.test", site: "shop.test", url: "https://calm-river-tree-lamp.trycloudflare.com", state: .open, options: ShareOptions(duration: .oneHour, password: false, hidesErrors: true, viteMode: .live, keepsRequests: true, address: .random), started: started, requestCount: 2, log: "/tmp/cloudflared-shop.test.log")

    private static func linkRequest(_ id: String, host: String = "shop.test", dumps: Int = 0) -> DumpedRequest {
        DumpedRequest(id: id, kind: .http, method: "POST", target: "/webhooks/\(id)", url: "https://calm-river-tree-lamp.trycloudflare.com/webhooks/\(id)", host: host, site: host, started: started, status: 200, duration: 0.184, dumpCount: dumps, publicLink: PublicLinkRequest(host: host, visitor: "3.18.12.63", size: 34, contentType: "application/json"))
    }

    private static func linkDetail(_ id: String) -> ShareRequestDetail {
        ShareRequestDetail(id: id, requestHeaders: [ShareHeader(name: "Content-Type", value: "application/json"), ShareHeader(name: "Cookie", value: "hidden")], requestBody: #"{"event":"\#(id)"}"#, requestBodyBytes: 14, requestBodyCut: false, status: 200, responseHeaders: [ShareHeader(name: "Content-Type", value: "application/json")], size: 34)
    }

    @Test func readLinkRequestsGivesTheRequestsOfTheLinkOldestFirstWithTheirHeadersAndBodies() async throws {
        let nexus = FakeNexus(caught: [Self.linkRequest("new"), Self.caught("plain"), Self.linkRequest("old", dumps: 1), Self.linkRequest("blog", host: "blog.test")], link: Self.listedLink, details: ["new": Self.linkDetail("new"), "old": Self.linkDetail("old")])

        let result = await toolbox(nexus, level: .read, folder: "/w/shop/public").call("read_link_requests", arguments: [:], agent: "claude-code")
        let old = try #require(result.text.range(of: "  request old · 1 dump"))
        let new = try #require(result.text.range(of: "  request new\n"))

        #expect(!result.isError)
        #expect(old.lowerBound < new.lowerBound)
        #expect(result.text.contains("  visitor 3.18.12.63"))
        #expect(result.text.contains("  Request headers\n    Content-Type: application/json\n    Cookie: hidden\n  Body\n    {\n      \"event\": \"new\"\n    }\n  Answer  200 · 34 bytes · application/json\n  Answer headers\n    Content-Type: application/json"))
        #expect(!result.text.contains("request plain"))
        #expect(!result.text.contains("request blog"))
        #expect(await nexus.requests.contains(.fromAgent(agent: "Claude Code", request: .shareRequest(id: "new"))))
    }

    @Test func readLinkRequestsWithARequestOrALimitReadsOnlyThose() async {
        let nexus = FakeNexus(caught: [Self.linkRequest("new"), Self.linkRequest("old")], link: Self.listedLink, details: ["new": Self.linkDetail("new")])

        let one = await toolbox(nexus, level: .read).call("read_link_requests", arguments: ["site": "shop.test", "request": "old"], agent: nil)
        let limited = await toolbox(nexus, level: .read).call("read_link_requests", arguments: ["site": "shop.test", "limit": 1], agent: nil)
        let unknown = await toolbox(nexus, level: .read).call("read_link_requests", arguments: ["site": "shop.test", "request": "gone"], agent: nil)

        #expect(one.text.contains("request old"))
        #expect(one.text.contains("  [\(LinkRequestText.detailGone)]"))
        #expect(!one.text.contains("request new"))
        #expect(limited.text.contains("request new"))
        #expect(!limited.text.contains("request old"))
        #expect(unknown.isError)
        #expect(unknown.text == "Nexus has no request gone of the link to shop.test. The link ended, or newer requests took its place.")
    }

    @Test func readLinkRequestsExplainsALinkWithoutAListAndASiteWithoutALink() async {
        let withoutList = await toolbox(FakeNexus(), level: .read).call("read_link_requests", arguments: ["site": "shop.test"], agent: nil)
        let withoutLink = await toolbox(FakeNexus(), level: .read).call("read_link_requests", arguments: ["site": "shop-fix.test"], agent: nil)
        let empty = await toolbox(FakeNexus(link: Self.listedLink), level: .read).call("read_link_requests", arguments: ["site": "shop.test"], agent: nil)

        #expect(withoutList.isError)
        #expect(withoutList.text == "The link to shop.test keeps no list of the requests. Only the user can turn on Keep a list of the requests, when they share the site.")
        #expect(withoutLink.isError)
        #expect(withoutLink.text == "shop-fix.test has no open link.")
        #expect(!empty.isError)
        #expect(empty.text == "No request came through the public link of shop.test yet.")
    }

    @Test func readDumpsLeavesOutARequestOfALinkWithoutEntries() async {
        let nexus = FakeNexus(caught: [Self.linkRequest("empty"), Self.linkRequest("dumped", dumps: 1)], entries: [Self.dump(of: "dumped")])

        let result = await toolbox(nexus, level: .read).call("read_dumps", arguments: [:], agent: nil)

        #expect(result.text.contains("request dumped · 1 dump"))
        #expect(!result.text.contains("request empty"))
    }

    @Test func readDumpsReadsAGroupAtATimeAndStopsWhenTheTextIsNearTheLimit() async throws {
        let ids = (1...12).map { number in "r\(number)" }
        let long = String(repeating: "x", count: NexusToolbox.dumpTextLimit / 3)
        let nexus = FakeNexus(caught: ids.map { id in Self.caught(id) }, entries: ids.map { id in Self.dump(of: id, text: long) })

        let result = await toolbox(nexus, level: .read).call("read_dumps", arguments: [:], agent: nil)
        let reads = await nexus.requests.filter { request in
            if case .requestDumps = request.inner {
                return true
            }

            return false
        }
        let second = try #require(result.text.range(of: "request r2 "))
        let newest = try #require(result.text.range(of: "request r1 "))

        #expect(reads.count == NexusToolbox.dumpReadsAtOnce)
        #expect(result.text.hasPrefix("The text leaves out the 10 oldest requests, because it is too long."))
        #expect(second.lowerBound < newest.lowerBound)
    }

    @Test func aToolAboveTheLevelGetsTheRefusal() async {
        let nexus = FakeNexus()
        let result = await toolbox(nexus, level: .read).call("start_service", arguments: ["service": "mysql-8.4"], agent: "claude-code")

        #expect(result.isError)
        #expect(result.text == "Nexus lets agents only look. The user can change this on the Agents screen of Nexus.")
        #expect(await nexus.requests.isEmpty)
    }

    @Test func aRemoveToolNeedsTheThirdLevel() async {
        let result = await toolbox(FakeNexus(), level: .change).call("stop_service", arguments: ["service": "mysql-8.4"], agent: nil)

        #expect(result.isError)
        #expect(result.text.hasPrefix("Nexus lets agents look and set up, but not remove."))
    }

    @Test func aChangeNamesTheAgentForTheActivityLog() async {
        let nexus = FakeNexus()
        let result = await toolbox(nexus, level: .change).call("start_service", arguments: ["service": "mysql-8.4", "restart": true], agent: "claude-code")

        #expect(!result.isError)
        #expect(result.structured?["message"] == "Done.")
        #expect(await nexus.requests == [.fromAgent(agent: "Claude Code", request: .restart(service: "mysql-8.4"))])
    }

    @Test func aMissingArgumentSaysWhatToGive() async {
        let result = await toolbox(FakeNexus(), level: .change).call("create_database", arguments: [:], agent: nil)

        #expect(result.text == "Give name.")
    }

    @Test func aFolderOutsideTheSitesIsNoSite() async {
        let result = await toolbox(FakeNexus(), level: .read, folder: "/w/other").call("site_info", arguments: [:], agent: nil)

        #expect(result.isError)
        #expect(result.text == "/w/other is not a Nexus site. Call list_sites to see the sites, or add_site to serve this folder.")
    }

    @Test func aHostFindsItsSite() async {
        let result = await toolbox(FakeNexus(), level: .read, folder: "/w/other").call("site_info", arguments: ["site": "shop.test"], agent: nil)

        #expect(result.structured?["site"] == "shop.test")
        #expect(result.structured?["mail"]?["sendsToNexus"] == true)
    }

    @Test func clearMailOutsideTheSitesNeedsAll() async {
        let result = await toolbox(FakeNexus(), level: .remove, folder: "/w/other").call("clear_mail", arguments: [:], agent: nil)

        #expect(result.isError)
        #expect(result.text.hasSuffix("To remove the mail of all sites, give site all."))
    }

    @Test func statusSaysThatNexusDoesNotRun() async {
        let result = await toolbox(FakeNexus(running: false), level: .read).call("status", arguments: [:], agent: nil)

        #expect(!result.isError)
        #expect(result.structured?["running"] == false)
    }

    @Test func otherToolsSayThatNexusDoesNotRun() async {
        let result = await toolbox(FakeNexus(running: false), level: .read).call("site_info", arguments: [:], agent: nil)

        #expect(result.text == NexusToolbox.notRunning)
    }

    @Test func theInstructionsSayWhenNexusDoesNotRun() async {
        let text = await toolbox(FakeNexus(running: false), level: .read).instructions(agent: nil)

        #expect(text.contains("Nexus does not run now."))
        #expect(text.contains("You can only look."))
        #expect(text.count <= AgentInstructions.longest)
    }

    private func changedToolbox(_ change: ProgramChange, restart: MCPRestart? = nil) -> NexusToolbox {
        NexusToolbox(connection: FakeNexus(change: change), paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")), folder: "/w/shop", loadSettings: { AgentSettings(level: .read) }, restart: restart)
    }

    private func failedStart() throws -> MCPRestart {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus Update \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let program = folder.appending(path: "nexus")
        try Data("old".utf8).write(to: program)
        let restart = MCPRestart(file: try #require(ExecutableFile(path: program.path(percentEncoded: false)))) { _, _ in }
        try Data("new".utf8).write(to: folder.appending(path: "nexus.new"))
        _ = try FileManager.default.replaceItemAt(program, withItemAt: folder.appending(path: "nexus.new"))

        restart.run(MCPResume(agent: nil, input: Data()))

        return restart
    }

    @Test func aCallDuringAnUpdateSaysThatItCanRunAgain() async {
        let toolbox = changedToolbox(.updated)

        let status = await toolbox.call("status", arguments: [:], agent: "claude-code")
        let siteInfo = await toolbox.call("site_info", arguments: [:], agent: "claude-code")

        #expect(status == .error("Nexus was updated during this call. Call the tool again."))
        #expect(siteInfo == .error(NexusToolbox.updatedDuringCallText))
    }

    @Test func eachCallAfterAFailedStartOfTheNewBuildSaysThatTheServerMustRestart() async throws {
        let restart = try failedStart()

        let status = await changedToolbox(.updated, restart: restart).call("status", arguments: [:], agent: "claude-code")
        let text = await changedToolbox(.updated, restart: restart).instructions(agent: "claude-code")

        #expect(restart.startFailed)
        #expect(status == .error("Nexus was updated while this MCP server ran. Restart the MCP server of Nexus in your agent, for example with /mcp in Claude Code."))
        #expect(text.contains(NexusToolbox.updatedText))
        #expect(!text.contains("does not run"))
        #expect(text.count <= AgentInstructions.longest)
    }

    @Test func aMovedNexusSaysSoToTheAgentAndToTheCommand() async {
        let toolbox = changedToolbox(.removed)

        let call = await toolbox.call("site_info", arguments: [:], agent: "claude-code")
        let command = await toolbox.look("site_info", arguments: [:])
        let text = await toolbox.instructions(agent: "claude-code")

        #expect(call == .error("Nexus was moved or removed while this MCP server ran. Open Nexus. Then restart the MCP server of Nexus in your agent, for example with /mcp in Claude Code."))
        #expect(command == .error("Nexus was moved or removed while this command ran. Open Nexus. Then run the command again."))
        #expect(text.contains(NexusToolbox.removedText))
    }

    @Test func aReadThatOnlyAddsDetailsDoesNotHideAChangeOfTheProgram() async {
        let toolbox = NexusToolbox(connection: FakeNexus(change: .updated, changeAfterSites: true), paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")), folder: "/w/shop/public", loadSettings: { AgentSettings(level: .read) })

        let siteInfo = await toolbox.call("site_info", arguments: [:], agent: "claude-code")
        let text = await toolbox.instructions(agent: "claude-code")

        #expect(siteInfo == .error(NexusToolbox.updatedDuringCallText))
        #expect(text.contains(NexusToolbox.updatedText))
        #expect(!text.contains("This folder is"))
    }

    @Test func aCommandAfterAnUpdateSaysThatItCanRunAgain() async {
        let result = await changedToolbox(.updated).look("site_info", arguments: [:])

        #expect(result == .error("Nexus was updated while this command ran. Run the command again."))
    }

    @Test func theInstructionsNameTheSite() async {
        let text = await toolbox(FakeNexus(), level: .change, folder: "/w/shop/public").instructions(agent: nil)

        #expect(text.contains("This folder is the Nexus site shop.test at https://shop.test. It uses PHP 8.4."))
        #expect(!text.contains("You can only look."))
    }

    @Test(arguments: [("claude-code", "Claude Code"), ("codex-mcp-client", "Codex"), ("Visual Studio Code", "VS Code"), ("gemini-cli-mcp-client", "Gemini CLI"), (nil, "an MCP client"), ("my\nagent", "myagent")])
    func theNameOfAnAgentIsReadable(client: String?, name: String) {
        #expect(AgentName.display(client) == name)
    }

    @Test func theSettingsKeepTheirDefaultsForABrokenFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        let paths = NexusPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AgentSettings.load(from: paths) == AgentSettings())

        try Data("{\"level\":\"everything\",\"askBeforeLooking\":true}".utf8).write(to: AgentSettings.file(in: paths))
        #expect(AgentSettings.load(from: paths) == AgentSettings(level: .change, askBeforeLooking: true))

        try AgentSettings(level: .remove, listed: ["codex"], searched: true).save(to: paths)
        #expect(AgentSettings.load(from: paths).level == .remove)
        #expect(AgentSettings.load(from: paths).listed == ["codex"])
        #expect(AgentSettings.load(from: paths).searched)
    }

    @Test func anAgentGetsOneRowInTheList() {
        var settings = AgentSettings(listed: ["codex"])

        settings.list([.codex, .claudeCode])
        settings.list([.claudeCode])

        #expect(settings.listed == ["codex", "claude_code"])
    }

    @Test func aWorkspaceGivesTheDocumentRootOfItsWorktree() {
        let site = SiteInfo(hosts: ["shop.test"], folder: "/w/shop", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", projectType: .laravel)
        let workspace = WorkspaceInfo(name: "fix", worktree: "/w/shop-fix", folder: "/w/shop-fix", documentRoot: "/w/shop-fix/public")

        let main = AgentSite(target: SiteTarget(site: site, workspace: nil), connections: [], mail: nil, testDatabase: nil)
        let fix = AgentSite(target: SiteTarget(site: site, workspace: workspace), connections: [], mail: nil, testDatabase: nil)

        #expect(main.documentRoot == "/w/shop/public")
        #expect(fix.documentRoot == "/w/shop-fix/public")
    }
}
