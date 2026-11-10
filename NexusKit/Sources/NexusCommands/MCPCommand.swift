import ArgumentParser
import Foundation
import NexusCore
import NexusMCP

// nexus mcp (0.3.0): the MCP server that coding agents start. It reads JSON-RPC messages on stdin
// and writes them on stdout, one on each line. Only the messages go to stdout. One other line
// would break the stream of the agent.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Connects coding agents such as Claude Code, Codex and Cursor to Nexus.",
        discussion: "An agent starts nexus mcp itself. It then sees the sites, the logs and the mail of Nexus. Nexus > Settings > Agents decides what agents can do.",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "serve", abstract: "Runs the MCP server on stdin and stdout.", shouldDisplay: false)

        func run() async throws {
            signal(SIGPIPE, SIG_IGN)

            let output = StandardOutput()
            let server = MCPServer(
                handler: NexusToolbox(folder: Self.projectFolder(), activity: ActivityLog(file: NexusPaths.standard.activityLog, source: "nexus mcp")),
                name: NexusVariant.current == .dev ? "nexus-dev" : "nexus",
                version: NexusVersion.current(),
                write: { await output.write($0) }
            )

            try await server.serve(LineReader(FileHandle.standardInput.bytes))
        }

        // Claude Code gives the project folder in CLAUDE_PROJECT_DIR. Other agents start the server
        // in the project folder, or in no project at all.
        static func projectFolder(environment: [String: String] = ProcessInfo.processInfo.environment, currentFolder: String = FileManager.default.currentDirectoryPath) -> String {
            let folder = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? currentFolder
            return RealPath.of(URL(filePath: folder, directoryHint: .isDirectory))
        }
    }
}

// The agent closed the pipe when a write fails. The server then has no one to answer.
private actor StandardOutput {
    func write(_ data: Data) {
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Foundation.exit(0)
        }
    }
}
