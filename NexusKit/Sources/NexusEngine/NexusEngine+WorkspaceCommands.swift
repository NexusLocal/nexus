import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// The commands of a site that run in a new workspace after the database copy (D51). A command that
// fails stops the list and gives a warning. The next setup goes on with that command. A command
// runs one time, because a command such as a change of a domain cannot always run two times.
extension NexusEngine {
    // A command can wait for ever, and the setups run one at a time.
    private static let commandTimeLimit: Duration = .seconds(30 * 60)

    // The list comes from the site until it ends in this workspace. So a correction of a command that
    // failed reaches the next setup, and a command that ended well does not run again.
    func runCommands(of workspace: inout Workspace, database: String?, key: String) async {
        guard !workspace.commandsEnded else {
            return
        }

        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site).filter { ProjectFolder.workspaceKey(of: $0) == key }
        let host = workspace.hosts(of: sites, tld: state.tld).first ?? ""
        let databaseWord = database.map(WorkspaceKeys.shellWord)
        let finished = workspace.finishedCommands
        let pending = Self.commands(of: sites).filter { !finished.contains($0) }

        guard !pending.isEmpty else {
            await endCommands(of: &workspace, key: key)
            return
        }

        // A command can use the database of the main site in a workspace that is not isolated (D48).
        guard workspace.state == .preparing else {
            workspace.warnings.append("Nexus runs no commands in a workspace that is not isolated.")
            return
        }

        guard let folder = await fileFolders(of: workspace, key: key)?.worktree else {
            return
        }

        // The ports of this setup come from before the database copy, and the list can have changed
        // in that time. A {port:<name>} without a number would reach the shell as text.
        workspace.ports = workspacePorts(for: Self.textsWithPorts(of: sites), of: workspace, state: state)
        try? await recordAssignments(of: workspace, key: key)

        let log = "workspace-\(host)"

        for command in pending {
            guard database != nil || !command.contains(WorkspaceKeys.databasePlaceholder) else {
                workspace.warnings.append("The command \(command) needs a database, and this workspace has none. A retry goes on with this command.")
                return
            }

            let expanded = WorkspaceKeys.expanded(command, workspace: workspace.name, host: host, database: databaseWord, ports: workspace.ports)

            do {
                let shell = await shellCommand(expanded, log: log, in: folder)

                // nexusd can stop or git can remove the worktree during the wait above. A running
                // program is not known yet, so nothing would end this program.
                guard !watchingStopped, FileManager.default.fileExists(atPath: folder) else {
                    workspace.warnings.append("Nexus did not run the command \(expanded), because the folder \(folder) is gone.")
                    return
                }

                writeToLog(of: log, "$ \(expanded)\n")
                _ = try await runWithTimeLimit(shell, in: workspace.worktree)
                workspace.finishedCommands.append(command)
                try? await updateRecord(of: workspace.name, key: key) { [finishedCommands = workspace.finishedCommands] record in
                    record.finishedCommands = finishedCommands
                }
            } catch {
                writeToLog(of: log, "\(error)\n")
                workspace.warnings.append("The command \(expanded) failed. A retry goes on with this command. See \(paths.log(log).path(percentEncoded: false)).")
                return
            }
        }

        await endCommands(of: &workspace, key: key)
    }

    private func endCommands(of workspace: inout Workspace, key: String) async {
        workspace.commandsEnded = true
        try? await updateRecord(of: workspace.name, key: key) { record in
            record.commandsEnded = true
        }
    }

    // Two sites can share a project and have the same command. That command must run one time.
    static func commands(of sites: [Site]) -> [String] {
        var seen: Set<String> = []

        return sites.flatMap { $0.workspaceCommands ?? [] }.filter { seen.insert($0).inserted }
    }

    // A program of a setup gets the PATH of the tool, and the links of nexus for the other tools.
    func environment(of tool: ToolCommand?) -> [String: String] {
        let path = ((tool?.path ?? [commandLinks]) + [ChildEnvironment.path]).joined(separator: ":")

        return (tool?.environment ?? [:]).merging(["PATH": path]) { _, new in new }
    }

    // A command gets the PHP of the site. A site without its PHP version can still run a command that
    // needs no PHP, and the log then says why php is not that version. The output goes to the log
    // while the command runs, so a command that fails or that a stop ends keeps all its output. A
    // program can ignore SIGTERM, and the time limit must still end it.
    private func shellCommand(_ command: String, log: String, in folder: String) async -> Command {
        let tool: ToolCommand?

        do {
            tool = try await toolCommand(.php, folder: folder)
        } catch {
            writeToLog(of: log, "\(error)\n")
            tool = nil
        }

        return Command(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exec >>\"$NEXUS_COMMAND_LOG\" 2>&1\n\(command)"],
            environment: environment(of: tool).merging(["NEXUS_COMMAND_LOG": paths.log(log).path(percentEncoded: false)]) { _, new in new },
            workingDirectory: URL(filePath: folder, directoryHint: .isDirectory),
            stopSignal: SIGKILL
        )
    }

    private func runWithTimeLimit(_ command: Command, in worktree: String) async throws -> CommandOutput {
        let limit = Task {
            try await Task.sleep(for: Self.commandTimeLimit)
            runningCommand?.task.cancel()
        }
        defer { limit.cancel() }

        do {
            return try await run(command, in: worktree)
        } catch is CancellationError {
            limit.cancel()

            guard (try? await limit.value) != nil else {
                throw CancellationError()
            }

            throw RuntimeError.unsupported("The command did not end in 30 minutes, so Nexus stopped it.")
        }
    }

    // A program of a setup is its own process group, so it stays after nexusd stops. The next start
    // would then run it a second time in the same folder. So a stop of nexusd ends that program. The
    // same applies to a worktree that git removes, because the program would make that folder again.
    func run(_ command: Command, in worktree: String) async throws -> CommandOutput {
        let task = Task { try await CommandRunner.run(command) }

        runningCommand = (worktree, task)
        defer { runningCommand = nil }

        return try await task.value
    }
}
