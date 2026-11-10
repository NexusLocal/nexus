import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusMCP

private actor FakeNexus: NexusConnecting {
    let running: Bool
    var requests: [NexusRequest] = []

    init(running: Bool = true) {
        self.running = running
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
        default:
            return .done(message: "Done.")
        }
    }
}

struct NexusToolboxTests {
    private func toolbox(_ nexus: FakeNexus, level: AgentLevel, folder: String = "/w/shop") -> NexusToolbox {
        NexusToolbox(connection: nexus, paths: NexusPaths(root: URL(filePath: "/tmp/nexus-tests-none")), folder: folder, loadSettings: { AgentSettings(level: level) })
    }

    @Test(arguments: [(AgentLevel.read, 10), (.change, 16), (.remove, 20)])
    func eachLevelListsItsTools(level: AgentLevel, count: Int) async {
        let tools = await toolbox(FakeNexus(), level: level).tools(agent: nil)

        #expect(tools.count == count)
        #expect(tools.allSatisfy { $0.readOnly == (NexusTools.spec($0.name)?.level == .read) })
    }

    @Test func aToolAboveTheLevelGetsTheRefusal() async {
        let nexus = FakeNexus()
        let result = await toolbox(nexus, level: .read).call("start_service", arguments: ["service": "mysql-8.4"], agent: "claude-code")

        #expect(result.isError)
        #expect(result.text == "Nexus lets agents only look. The user can change this in Nexus > Settings > Agents.")
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
