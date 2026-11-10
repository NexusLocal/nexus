import Foundation
import Testing
@testable import NexusMCP

// Each test uses its own temporary home folder. The files of the user stay out of reach.
struct AgentSetupTests {
    private let home: URL
    private let setup: AgentSetup
    private let command = "/Users/me/Library/Application Support/Nexus/bin/nexus"

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setup = Self.setup(home: home, command: command, claude: Self.fakeClaude(home: home))
    }

    private static func setup(home: URL, command: String, claude: (@Sendable ([String]) async throws -> Void)?) -> AgentSetup {
        AgentSetup(home: home, serverName: "nexus", command: command, applicationFolders: [home.appending(path: "Applications")], commandFolders: [home.appending(path: "bin")], claude: claude)
    }

    // claude mcp add and claude mcp remove, as Claude Code writes them in ~/.claude.json. failing
    // makes an add of this command fail.
    private static func fakeClaude(home: URL, failing: String? = nil) -> @Sendable ([String]) async throws -> Void {
        { arguments in
            let file = home.appending(path: ".claude.json")
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "{}"
            let name = arguments[4]

            if arguments[1] == "remove" {
                try JSONTextEdit.removing(["mcpServers", name], in: text).write(to: file, atomically: true, encoding: .utf8)
                return
            }

            let words = Array(arguments.drop { $0 != "--" }.dropFirst())

            if words.first == failing {
                throw TOMLTextEdit.Failure(description: "no node")
            }

            let entry = JSONText.object([("type", .string("stdio")), ("command", .string(words[0])), ("args", .array(words.dropFirst().map(JSONText.string)))])
            try JSONTextEdit.setting(["mcpServers", name], to: entry, in: text).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func write(_ text: String, to path: String) throws {
        let file = home.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: home.appending(path: path), encoding: .utf8)
    }

    @Test func anAgentIsFoundFromItsAppOrItsCommand() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "Applications/Cursor.app"), withIntermediateDirectories: true)
        try write("#!/bin/sh\n", to: "bin/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/codex").path(percentEncoded: false))

        #expect(setup.isOnThisMac(.cursor))
        #expect(setup.isOnThisMac(.codex))
        #expect(!setup.isOnThisMac(.zed))
    }

    @Test func eachJSONAgentGetsItsOwnEntry() async throws {
        for agent in AgentKind.allCases where agent != .codex {
            #expect(setup.state(of: agent) == .notConnected)
            try await setup.connect(agent, askBeforeLooking: true)
            #expect(setup.state(of: agent) == .connected, "\(agent)")
        }

        let openCode = try JSONTextEdit.value(at: ["mcp", "nexus"], in: try read(".config/opencode/opencode.json")) as? [String: Any]
        let vsCode = try JSONTextEdit.value(at: ["servers", "nexus", "type"], in: try read("Library/Application Support/Code/User/mcp.json")) as? String

        #expect(openCode?["command"] as? [String] == [command, "mcp"])
        #expect(openCode?["type"] as? String == "local")
        #expect(vsCode == "stdio")
    }

    @Test func codexGetsATableWithItsApprovalMode() async throws {
        try write("model = \"gpt\"\n\n[mcp_servers.pencil]\ncommand = \"/p\"\n", to: ".codex/config.toml")

        try await setup.connect(.codex, askBeforeLooking: false)
        #expect(setup.state(of: .codex) == .connected)
        #expect(try read(".codex/config.toml").contains("default_tools_approval_mode = \"writes\""))

        try await setup.applyLooking(askBeforeLooking: true)
        #expect(try read(".codex/config.toml").contains("default_tools_approval_mode = \"prompt\""))

        try await setup.disconnect(.codex)
        #expect(try read(".codex/config.toml") == "model = \"gpt\"\n\n[mcp_servers.pencil]\ncommand = \"/p\"\n")
    }

    @Test func claudeCodeGetsTheRulesForTheToolsThatRead() async throws {
        try write("{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  }\n}\n", to: ".claude/settings.json")
        try write("{\"numStartups\": 3}", to: ".claude.json")

        try await setup.connect(.claudeCode, askBeforeLooking: false)

        #expect(setup.claudeCodeRules().count == NexusTools.readToolNames.count)
        #expect(setup.claudeCodeRules().contains("mcp__nexus__wait_for_mail"))
        #expect(!setup.claudeCodeRules().contains("mcp__nexus__start_service"))
        #expect(try JSONTextEdit.value(at: ["numStartups"], in: try read(".claude.json")) as? Int == 3)

        try await setup.disconnect(.claudeCode)

        #expect(setup.claudeCodeRules().isEmpty)
        #expect(try read(".claude/settings.json") == "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  }\n}\n")
    }

    @Test func aFailedAddPutsTheOldEntryOfClaudeCodeBack() async throws {
        try write("{\"mcpServers\": {\"nexus\": {\"type\": \"stdio\", \"command\": \"/old/nexus\", \"args\": [\"mcp\"]}}}", to: ".claude.json")
        let failing = Self.setup(home: home, command: command, claude: Self.fakeClaude(home: home, failing: command))

        await #expect(throws: AgentSetupError.self) {
            try await failing.connect(.claudeCode, askBeforeLooking: true)
        }

        #expect(failing.state(of: .claudeCode) == .otherCommand("/old/nexus"))
    }

    @Test func withoutTheClaudeCommandTheErrorGivesTheCommandToRun() async throws {
        let without = Self.setup(home: home, command: command, claude: nil)

        do {
            try await without.connect(.claudeCode, askBeforeLooking: true)
            Issue.record("The connect did not fail.")
        } catch let error as AgentSetupError {
            #expect(error.entry == "claude mcp add --scope user nexus -- '/Users/me/Library/Application Support/Nexus/bin/nexus' mcp")
        }

        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude.json").path(percentEncoded: false)))
    }

    @Test func aBrokenSettingsFileOfClaudeCodeNamesTheRules() async throws {
        try write("{\"permissions\": {\"allow\": {}}}", to: ".claude/settings.json")

        do {
            try await setup.connect(.claudeCode, askBeforeLooking: false)
            Issue.record("The connect did not fail.")
        } catch let error as AgentSetupError {
            #expect(error.instruction == "Add these rules to permissions.allow yourself:")
            #expect(error.entry.contains("mcp__nexus__site_info"))
        }
    }

    @Test func anOldCommandShowsAndAConnectReplacesIt() async throws {
        try write("{\"mcpServers\": {\"nexus\": {\"command\": \"/old/nexus\", \"args\": [\"mcp\"]}}}", to: ".cursor/mcp.json")

        #expect(setup.state(of: .cursor) == .otherCommand("/old/nexus"))

        try await setup.connect(.cursor, askBeforeLooking: true)
        #expect(setup.state(of: .cursor) == .connected)
    }

    @Test func aBrokenFileStaysAsItWasAndTheErrorHoldsTheEntry() async throws {
        try write("{ \"mcpServers\": ", to: ".gemini/settings.json")

        #expect(setup.state(of: .geminiCLI) == .unreadable("~/.gemini/settings.json"))

        do {
            try await setup.connect(.geminiCLI, askBeforeLooking: true)
            Issue.record("The connect did not fail.")
        } catch let error as AgentSetupError {
            #expect(error.file == "~/.gemini/settings.json")
            #expect(error.entry.contains(command))
        }

        #expect(try read(".gemini/settings.json") == "{ \"mcpServers\": ")
    }

    @Test func aLinkStaysALinkAndThePermissionsStay() async throws {
        try write("{}", to: "dotfiles/mcp.json")
        let real = home.appending(path: "dotfiles/mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".cursor/mcp.json"), withDestinationURL: real)

        try await setup.connect(.cursor, askBeforeLooking: true)

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.appending(path: ".cursor/mcp.json").path(percentEncoded: false))
        let permissions = try FileManager.default.attributesOfItem(atPath: real.path(percentEncoded: false))[.posixPermissions] as? Int

        #expect(link == real.path(percentEncoded: false))
        #expect(permissions == 0o600)
        #expect(setup.state(of: .cursor) == .connected)
    }

    @Test func windsurfGetsEachFileWhoseFolderExists() async throws {
        try FileManager.default.createDirectory(at: home.appending(path: ".codeium/windsurf"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".config/devin"), withIntermediateDirectories: true)

        try await setup.connect(.windsurf, askBeforeLooking: true)

        #expect(try read(".codeium/windsurf/mcp_config.json").contains(command))
        #expect(try read(".config/devin/mcp_config.json").contains(command))

        try await setup.disconnect(.windsurf)
        #expect(setup.state(of: .windsurf) == .notConnected)
    }

    @Test func theArgumentAcceptsDashes() {
        #expect(AgentKind(argument: "claude-code") == .claudeCode)
        #expect(AgentKind(argument: "VS-Code") == .vsCode)
        #expect(AgentKind(argument: "copilot") == nil)
    }
}
