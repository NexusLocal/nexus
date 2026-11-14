import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusMCP

private actor FakeNexus: NexusConnecting {
    let running: Bool
    let caught: [DumpedRequest]
    let entries: [CaughtDump]
    var requests: [NexusRequest] = []

    init(running: Bool = true, caught: [DumpedRequest] = [], entries: [CaughtDump] = []) {
        self.running = running
        self.caught = caught
        self.entries = entries
    }

    func send(_ request: NexusRequest) async throws -> NexusResponse {
        guard running else {
            throw NexusClientError.daemonNotRunning("test")
        }

        requests.append(request)

        switch request.inner {
        case .sites:
            return .sites([SiteInfo(hosts: ["shop.test"], folder: "/w/shop/public", documentRoot: "/w/shop/public", php: "8.4", server: .nginx, parked: false, url: "https://shop.test", projectType: .laravel)])
        case .databaseConnections:
            return .databaseConnections([])
        case .siteMail:
            return .siteMail(SiteMail(sendsToNexus: true))
        case .mailStatus:
            return .mailStatus(MailStatus(installed: true, running: true, receiving: true, smtpPort: 1025, inboxPort: 8025, waiting: 0, waitingBytes: 0, removed: 0, refused: 0, outboxFolder: "/tmp", settings: MailSettings()))
        case .dumpPlace(let host):
            return .dumpPlace(place: DumpPlace(site: host), host: host)
        case .dumpList(let place):
            return .dumpList(DumpList(requests: caught.filter { place.includes($0.place) }, settings: DumpSettings(), receiving: true))
        case .requestDumps(let id, _):
            return .caughtDumps(entries.filter { $0.requestID == id })
        default:
            return .done(message: "Done.")
        }
    }
}

struct NexusToolboxTests {
    private func toolbox(_ nexus: FakeNexus, level: AgentLevel, folder: String = "/w/shop") -> NexusToolbox {
        NexusToolbox(connection: nexus, paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")), folder: folder, loadSettings: { AgentSettings(level: level) })
    }

    @Test(arguments: [(AgentLevel.read, 11), (.change, 17), (.remove, 21)])
    func eachLevelListsItsTools(level: AgentLevel, count: Int) async {
        let tools = await toolbox(FakeNexus(), level: level).tools(agent: nil)

        #expect(tools.count == count)
        #expect(tools.allSatisfy { $0.readOnly == (NexusTools.spec($0.name)?.level == .read) })
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
