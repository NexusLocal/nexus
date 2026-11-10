import Foundation
import NexusCore
import NexusSupervisor

// The order of the cases is the order of the app: Claude and Claude Code first, then the others
// from A to Z.
public enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case claudeCode = "claude_code"
    case codex
    case cursor
    case geminiCLI = "gemini_cli"
    case junie
    case openCode = "opencode"
    case vsCode = "vs_code"
    case windsurf
    case zed

    public var id: String {
        rawValue
    }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .geminiCLI: "Gemini CLI"
        case .junie: "Junie"
        case .openCode: "OpenCode"
        case .vsCode: "VS Code"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        }
    }

    // Windsurf is now Devin Desktop. Its Cascade agent reads the first file. Its Devin agent reads
    // the second file.
    var files: [String] {
        switch self {
        case .claude: ["Library/Application Support/Claude/claude_desktop_config.json"]
        case .claudeCode: [".claude.json"]
        case .codex: [".codex/config.toml"]
        case .cursor: [".cursor/mcp.json"]
        case .geminiCLI: [".gemini/settings.json"]
        case .junie: [".junie/mcp/mcp.json"]
        case .openCode: [".config/opencode/opencode.json"]
        case .vsCode: ["Library/Application Support/Code/User/mcp.json"]
        case .windsurf: [".codeium/windsurf/mcp_config.json", ".config/devin/mcp_config.json"]
        case .zed: [".config/zed/settings.json"]
        }
    }

    var serversKey: String {
        switch self {
        case .claudeCode, .claude, .cursor, .geminiCLI, .junie, .windsurf: "mcpServers"
        case .openCode: "mcp"
        case .vsCode: "servers"
        case .zed: "context_servers"
        case .codex: "mcp_servers"
        }
    }

    var apps: [String] {
        switch self {
        case .claude: ["Claude.app"]
        case .codex: ["Codex.app"]
        case .cursor: ["Cursor.app"]
        case .vsCode: ["Visual Studio Code.app"]
        case .windsurf: ["Windsurf.app", "Devin.app"]
        case .zed: ["Zed.app"]
        case .claudeCode, .geminiCLI, .junie, .openCode: []
        }
    }

    var commands: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .cursor: ["cursor-agent"]
        case .geminiCLI: ["gemini"]
        case .junie: ["junie"]
        case .openCode: ["opencode"]
        case .vsCode: ["code"]
        case .zed: ["zed"]
        case .claude, .windsurf: []
        }
    }

    // A desktop app reads its settings only at its start.
    public var restartHint: String {
        switch self {
        case .claude, .cursor, .windsurf, .zed: "Restart \(name) to use Nexus."
        case .vsCode: "VS Code starts Nexus at the next chat."
        case .claudeCode, .codex, .geminiCLI, .junie, .openCode: "A new session of \(name) uses Nexus."
        }
    }

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased().replacing("-", with: "_"))
    }
}

public enum AgentState: Equatable, Sendable {
    case connected
    case otherCommand(String)
    case notConnected
    case unreadable(String)

    public var hasEntry: Bool {
        switch self {
        case .connected, .otherCommand: true
        case .notConnected, .unreadable: false
        }
    }
}

public struct AgentSetupError: Error, CustomStringConvertible, Equatable {
    public let agent: AgentKind
    public let file: String
    public let reason: String
    public let instruction: String
    public let entry: String

    public var description: String {
        "Nexus does not change \(file), because \(reason). \(instruction)\n\(entry)"
    }
}

// Nexus changes only its own entry in the files of other apps. A file that Nexus cannot change
// safely stays as it was, and the error holds what the user can do by hand. The home folder is a
// parameter, so the tests never reach the files of the user.
public struct AgentSetup: Sendable {
    public let home: URL
    public let serverName: String
    public let command: String
    let applicationFolders: [URL]
    let commandFolders: [URL]
    // Claude Code writes ~/.claude.json from its memory while it runs. A write of Nexus in that
    // file can get lost. So only the claude command changes it.
    let claude: (@Sendable ([String]) async throws -> Void)?

    public init(home: URL, serverName: String, command: String, applicationFolders: [URL], commandFolders: [URL], claude: (@Sendable ([String]) async throws -> Void)?) {
        self.home = home
        self.serverName = serverName
        self.command = command
        self.applicationFolders = applicationFolders
        self.commandFolders = commandFolders
        self.claude = claude
    }

    // Nexus Dev uses the entry nexus-dev, so both apps can be on. The entry has the full path of
    // the command, because an app from the Dock does not have the PATH of the shell.
    public static var standard: AgentSetup {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let commandFolders = Self.commandFolders(home: home)
        let claudeCommand = commandFolders.map { $0.appending(path: "claude") }.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
        let path = (commandFolders.map { $0.path(percentEncoded: false) } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")

        return AgentSetup(
            home: home,
            serverName: NexusVariant.current == .dev ? "nexus-dev" : "nexus",
            command: NexusPaths.standard.bin.appending(path: "nexus").path(percentEncoded: false),
            applicationFolders: [URL(filePath: "/Applications"), home.appending(path: "Applications")],
            commandFolders: commandFolders,
            claude: claudeCommand.map { executable in
                { @Sendable arguments in
                    try await CommandRunner.run(Command(executable: executable, arguments: arguments, environment: ["HOME": home.path(percentEncoded: false), "PATH": path], name: "claude"))
                }
            }
        )
    }

    // An npm install of an agent is a node script. So node must be on the PATH of the command too.
    static func commandFolders(home: URL) -> [URL] {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let nodes = ((try? FileManager.default.contentsOfDirectory(at: home.appending(path: ".nvm/versions/node"), includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appending(path: "bin", directoryHint: .isDirectory) }
        let usual = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".opencode/bin", ".cargo/bin"].map { home.appending(path: $0, directoryHint: .isDirectory) }
            + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            + nodes

        return usual + path.filter { !usual.contains($0) }
    }

    // MARK: State

    public func isOnThisMac(_ agent: AgentKind) -> Bool {
        let app = agent.apps.contains { name in
            applicationFolders.contains { FileManager.default.fileExists(atPath: $0.appending(path: name).path(percentEncoded: false)) }
        }

        let command = agent.commands.contains { name in
            commandFolders.contains { FileManager.default.isExecutableFile(atPath: $0.appending(path: name).path(percentEncoded: false)) }
        }

        return app || command
    }

    public func state(of agent: AgentKind) -> AgentState {
        var other: String?

        for file in files(of: agent) where exists(file) {
            do {
                switch try command(in: file, of: agent) {
                case command?: return .connected
                case let found?: other = found
                case nil: break
                }
            } catch {
                return .unreadable(display(file))
            }
        }

        return other.map(AgentState.otherCommand) ?? .notConnected
    }

    public func entryText(for agent: AgentKind?) -> String {
        guard let agent else {
            return JSONText.object([("mcpServers", .object([(serverName, standardEntry)]))]).rendered(indent: "", unit: "  ")
        }

        switch agent {
        case .codex:
            return (["[mcp_servers.\(serverName)]"] + codexKeys(askBeforeLooking: true).map { "\($0.name) = \($0.value)" }).joined(separator: "\n")
        case .claudeCode:
            return shellCommand(["claude", "mcp", "add", "--scope", "user", serverName, "--", command, "mcp"])
        default:
            return JSONText.object([(agent.serversKey, .object([(serverName, entry(for: agent))]))]).rendered(indent: "", unit: "  ")
        }
    }

    // MARK: Changes

    // askBeforeLooking false lets Claude Code and Codex read without a question. They still ask
    // before each change.
    @discardableResult
    public func connect(_ agent: AgentKind, askBeforeLooking: Bool) async throws -> String {
        switch agent {
        case .claudeCode:
            try await connectClaudeCode()
            try setClaudeCodeRules(askBeforeLooking: askBeforeLooking)
        case .codex:
            for file in targetFiles(of: agent) {
                try change(file, of: agent, instruction: addInstruction(agent), entry: entryText(for: agent)) { text in
                    try TOMLTextEdit.setting(["mcp_servers", serverName], keys: codexKeys(askBeforeLooking: askBeforeLooking), in: text)
                }
            }
        default:
            for file in targetFiles(of: agent) {
                try change(file, of: agent, instruction: addInstruction(agent), entry: entryText(for: agent)) { text in
                    try JSONTextEdit.setting([agent.serversKey, serverName], to: entry(for: agent), in: text)
                }
            }
        }

        return "Nexus is connected to \(agent.name). \(agent.restartHint)"
    }

    @discardableResult
    public func disconnect(_ agent: AgentKind) async throws -> String {
        switch agent {
        case .claudeCode:
            if state(of: .claudeCode).hasEntry {
                try await runClaude(["mcp", "remove", "--scope", "user", serverName])
            }

            try setClaudeCodeRules(askBeforeLooking: true)
        default:
            for file in files(of: agent) where exists(file) {
                try change(file, of: agent, instruction: "Remove the entry \(serverName) from it yourself.", entry: "") { text in
                    agent == .codex
                        ? try TOMLTextEdit.removing(["mcp_servers", serverName], in: text)
                        : try JSONTextEdit.removing([agent.serversKey, serverName], in: text)
                }
            }
        }

        return "Nexus is no longer connected to \(agent.name)."
    }

    public func applyLooking(askBeforeLooking: Bool) async throws {
        if state(of: .claudeCode) == .connected {
            try setClaudeCodeRules(askBeforeLooking: askBeforeLooking)
        }

        if state(of: .codex) == .connected {
            try await connect(.codex, askBeforeLooking: askBeforeLooking)
        }
    }

    // A failed add after the removal of an old entry puts the old entry back. Claude Code then
    // keeps a working Nexus.
    private func connectClaudeCode() async throws {
        switch state(of: .claudeCode) {
        case .connected:
            return
        case .unreadable(let file):
            throw AgentSetupError(agent: .claudeCode, file: file, reason: "Nexus cannot read it", instruction: "Run this command in Terminal:", entry: entryText(for: .claudeCode))
        case .otherCommand(let old):
            try await runClaude(["mcp", "remove", "--scope", "user", serverName])

            do {
                try await runClaude(["mcp", "add", "--scope", "user", serverName, "--", command, "mcp"])
            } catch {
                try? await runClaude(["mcp", "add", "--scope", "user", serverName, "--", old, "mcp"])
                throw error
            }
        case .notConnected:
            try await runClaude(["mcp", "add", "--scope", "user", serverName, "--", command, "mcp"])
        }
    }

    private func runClaude(_ arguments: [String]) async throws {
        guard let claude else {
            throw AgentSetupError(agent: .claudeCode, file: "~/.claude.json", reason: "Nexus does not find the claude command", instruction: "Run this command in Terminal:", entry: shellCommand(["claude"] + arguments))
        }

        do {
            try await claude(arguments)
        } catch {
            throw AgentSetupError(agent: .claudeCode, file: "~/.claude.json", reason: "the claude command failed: \(error)", instruction: "Run this command in Terminal:", entry: shellCommand(["claude"] + arguments))
        }
    }

    func setClaudeCodeRules(askBeforeLooking: Bool) throws {
        let file = home.appending(path: ".claude/settings.json")
        let rules = claudeCodeRuleNames

        guard !askBeforeLooking || exists(file) else {
            return
        }

        let instruction = askBeforeLooking ? "Remove these rules from permissions.allow yourself:" : "Add these rules to permissions.allow yourself:"

        try change(file, of: .claudeCode, instruction: instruction, entry: rules.joined(separator: "\n")) { text in
            askBeforeLooking
                ? try JSONTextEdit.removingStrings(Set(rules), fromArrayAt: ["permissions", "allow"], in: text)
                : try JSONTextEdit.addingStrings(rules, toArrayAt: ["permissions", "allow"], in: text)
        }
    }

    // Only the tools that read. A rule mcp__nexus__* would also skip the question before a change.
    var claudeCodeRuleNames: [String] {
        NexusTools.readToolNames.map { "mcp__\(serverName)__\($0)" }
    }

    public func claudeCodeRules() -> [String] {
        let file = home.appending(path: ".claude/settings.json")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let allowed = ((try? JSONTextEdit.value(at: ["permissions", "allow"], in: text)) as? [Any])?.compactMap { $0 as? String } ?? []
        return allowed.filter { $0.hasPrefix("mcp__\(serverName)__") }
    }

    // MARK: Entries

    private var standardEntry: JSONText {
        .object([("command", .string(command)), ("args", .array([.string("mcp")]))])
    }

    func entry(for agent: AgentKind) -> JSONText {
        switch agent {
        case .vsCode: .object([("type", .string("stdio")), ("command", .string(command)), ("args", .array([.string("mcp")]))])
        case .openCode: .object([("type", .string("local")), ("command", .array([.string(command), .string("mcp")])), ("enabled", .bool(true))])
        case .zed: .object([("command", .string(command)), ("args", .array([.string("mcp")])), ("env", .object([]))])
        default: standardEntry
        }
    }

    // Codex stops a tool after 60 seconds by default, and an install of PHP can take longer. A
    // timeout of the user stays.
    func codexKeys(askBeforeLooking: Bool) -> [TOMLTextEdit.Key] {
        [
            TOMLTextEdit.Key("command", TOMLTextEdit.quoted(command)),
            TOMLTextEdit.Key("args", "[\"mcp\"]"),
            TOMLTextEdit.Key("tool_timeout_sec", "120", keepExisting: true),
            TOMLTextEdit.Key("default_tools_approval_mode", askBeforeLooking ? "\"prompt\"" : "\"writes\""),
        ]
    }

    private func addInstruction(_ agent: AgentKind) -> String {
        "Add this entry to the MCP settings of \(agent.name) yourself:"
    }

    private func shellCommand(_ words: [String]) -> String {
        words.map { word in
            word.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) } ? word : "'\(word.replacing("'", with: "'\\''"))'"
        }.joined(separator: " ")
    }

    // MARK: Files

    private func files(of agent: AgentKind) -> [URL] {
        agent.files.map { home.appending(path: $0) }
    }

    private func targetFiles(of agent: AgentKind) -> [URL] {
        let all = files(of: agent)
        let present = all.filter { FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path(percentEncoded: false)) }
        return present.isEmpty ? Array(all.prefix(1)) : present
    }

    private func command(in file: URL, of agent: AgentKind) throws -> String? {
        let text = try String(contentsOf: file, encoding: .utf8)

        if agent == .codex {
            guard try TOMLTextEdit.hasTable(["mcp_servers", serverName], in: text) else {
                return nil
            }

            return try TOMLTextEdit.value("command", inTable: ["mcp_servers", serverName], in: text) ?? ""
        }

        guard let entry = try JSONTextEdit.value(at: [agent.serversKey, serverName], in: text) as? [String: Any] else {
            return nil
        }

        if let parts = entry["command"] as? [String] {
            return parts.first ?? ""
        }

        return (entry["command"] as? String) ?? ((entry["command"] as? [String: Any])?["path"] as? String) ?? ""
    }

    // A link, for example into a dotfiles folder, stays a link: Nexus writes the file that it
    // points to. A new file gets 0600, because the settings of an agent can hold keys.
    private func change(_ file: URL, of agent: AgentKind, instruction: String, entry: String, _ edit: (String) throws -> String) throws {
        let target = file.resolvingSymlinksInPath()
        let path = target.path(percentEncoded: false)
        let existed = FileManager.default.fileExists(atPath: path)
        let changed: String
        let text: String

        do {
            text = existed ? try String(contentsOf: target, encoding: .utf8) : ""
            changed = try edit(text)
        } catch {
            throw AgentSetupError(agent: agent, file: display(file), reason: "\(error)", instruction: instruction, entry: entry)
        }

        guard changed != text else {
            return
        }

        let permissions = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0o600
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(changed.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    private func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    func display(_ file: URL) -> String {
        let path = file.path(percentEncoded: false)
        let homePath = home.path(percentEncoded: false)
        return path.hasPrefix(homePath) ? "~/" + path.dropFirst(homePath.hasSuffix("/") ? homePath.count : homePath.count + 1) : path
    }
}
