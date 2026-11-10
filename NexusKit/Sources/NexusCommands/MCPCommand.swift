import ArgumentParser
import Foundation
import NexusCore
import NexusMCP

// Only the messages go to stdout. One other line would break the stream of the agent.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Connects coding agents such as Claude Code, Codex and Cursor to Nexus.",
        discussion: "An agent starts nexus mcp itself. It then sees the sites, the logs and the mail of Nexus. Nexus > Settings > Agents decides what agents can do.",
        subcommands: [Serve.self, Status.self, Install.self, Uninstall.self],
        defaultSubcommand: Serve.self
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows which coding agents are on this Mac and which ones use Nexus.")

        func run() async throws {
            let setup = AgentSetup.standard
            let settings = AgentSettings.load()

            print("Agents can: \(settings.level.title). Ask before agents look: \(settings.askBeforeLooking ? "on" : "off").")

            for agent in AgentKind.allCases {
                let place = setup.isOnThisMac(agent) ? "on this Mac" : "not found"
                let state = switch setup.state(of: agent) {
                case .connected: "connected"
                case .otherCommand(let command): "connected to another nexus: \(command)"
                case .notConnected: "not connected"
                case .unreadable(let file): "Nexus cannot read \(file)"
                }

                print([agent.rawValue.replacing("_", with: "-").padding(to: 13), place.padding(to: 13), state].joined(separator: " "))
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connects coding agents to Nexus, for example: nexus mcp install --agent claude-code",
            discussion: "Without --agent, Nexus connects each agent that it finds on this Mac. Nexus adds only its own entry to the settings of an agent. With \"Ask me before agents look\" off, Claude Code and Codex read from Nexus without a question."
        )

        @Option(name: .customLong("agent"), help: "claude, claude-code, codex, cursor, gemini-cli, junie, opencode, vs-code, windsurf or zed. Repeat it for more agents.") var agents: [AgentKind] = []

        func run() async throws {
            let setup = AgentSetup.standard
            var settings = AgentSettings.load()
            let chosen = agents.isEmpty ? AgentKind.allCases.filter(setup.isOnThisMac) : agents
            var failed = false

            guard !chosen.isEmpty else {
                print("Nexus finds no coding agent on this Mac. Give one with --agent, for example: nexus mcp install --agent claude-code")
                return
            }

            for agent in chosen {
                do {
                    print(try await setup.connect(agent, askBeforeLooking: settings.askBeforeLooking))

                    if !settings.listed.contains(agent.rawValue) {
                        settings.listed.append(agent.rawValue)
                    }
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    failed = true
                }
            }

            try settings.save()

            if failed {
                throw ExitCode.failure
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Removes the entry of Nexus from the settings of coding agents. Without --agent, from each agent.")

        @Option(name: .customLong("agent"), help: "An agent as nexus mcp status shows it. Repeat it for more agents.") var agents: [AgentKind] = []

        func run() async throws {
            let setup = AgentSetup.standard
            let chosen = agents.isEmpty ? AgentKind.allCases.filter { setup.state(of: $0).hasEntry } : agents
            var failed = false

            guard !chosen.isEmpty else {
                print("No coding agent uses Nexus.")
                return
            }

            for agent in chosen {
                do {
                    print(try await setup.disconnect(agent))
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    failed = true
                }
            }

            if failed {
                throw ExitCode.failure
            }
        }
    }

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

extension AgentKind: ExpressibleByArgument {}

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
