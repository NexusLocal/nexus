import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// A workspace in one step (owner, 2026-11-09, Herd item 21). nexus workspace create <branch> and the
// "New workspace" button run git worktree add in the place of Settings > Workspaces. Then
// createWorkspace gives the worktree its workspace, also for a site with automatic workspaces off.
// A new branch starts from the current branch of the main checkout. A branch that exists, also
// only on one remote, gets its worktree as it is.
extension NexusEngine {
    func createWorktree(folder: String, branch: String, databases: WorkspaceDatabaseKind?) async throws -> String {
        let state = await stateStore.current()
        let path = RealPath.of(URL(filePath: folder, directoryHint: .isDirectory))

        guard let site = ProjectFolder.locate(URL(filePath: path, directoryHint: .isDirectory), in: resolvedSites(state).map(\.site))?.site,
              let (repository, subfolder) = ProjectFolder.repository(of: site) else {
            throw RuntimeError.unsupported("No site of Nexus with a git repository holds \(path). Run this in the folder of a site.")
        }

        guard site.kind != .proxy else {
            throw RuntimeError.unsupported("\(site.host) is a proxy site. A proxy site gets no workspaces, because each workspace would go to the same server.")
        }

        guard let git = await GitTool.executable() else {
            throw RuntimeError.unsupported(GitTool.missing)
        }

        guard await succeeds(git, ["check-ref-format", "--branch", branch], in: repository) else {
            throw RuntimeError.unsupported("\(branch) is not a valid name for a git branch.")
        }

        let settings = state.workspaceSettings
        let worktree = NewWorktree.path(branch: branch, repository: repository, place: settings.worktreePlace, folder: settings.worktreeFolder)

        guard !FileManager.default.fileExists(atPath: worktree) else {
            throw RuntimeError.unsupported("\(worktree) exists already. Choose another branch, or remove that folder.")
        }

        let existing = await branchExists(branch, in: repository, git: git)
        let arguments = existing ? [worktree, branch] : ["-b", branch, worktree]

        let parent = URL(filePath: (worktree as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        var projectFolder: String?

        defer {
            if let projectFolder {
                worktreesInCreation.remove(projectFolder)
            }
        }

        do {
            // git reads a pattern for a folder only when that folder exists.
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let inCreation = "\(RealPath.of(parent))/\((worktree as NSString).lastPathComponent)\(subfolder)"
            projectFolder = inCreation
            worktreesInCreation.insert(inCreation)

            if RealPath.contains((repository as NSString).appendingPathComponent(NewWorktree.projectFolder), worktree) {
                await excludeWorktreeFolder(of: repository, git: git, worktree: worktree)
            }

            _ = try await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "worktree", "add"] + arguments))
        } catch {
            throw RuntimeError.unsupported("git did not make the worktree \(worktree). \(error)")
        }

        let workspace = try await createWorkspace(folder: worktree, databases: databases)
        let start = existing ? "the branch \(branch)" : "the new branch \(branch)"

        return "git made the worktree \(worktree) on \(start). \(workspace)"
    }

    // The folder in the project must not show in git status. Only the worktree folder goes into the
    // exclude file of this repository. That file stays on this Mac, so the team and the shared files
    // in .claude do not change. A folder that git ignores already needs no line.
    private func excludeWorktreeFolder(of repository: String, git: URL, worktree: String) async {
        guard await !succeeds(git, ["check-ignore", "--quiet", worktree], in: repository),
              let common = try? await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "rev-parse", "--git-common-dir"])).trimmed else {
            return
        }

        let gitFolder = URL(filePath: common, directoryHint: .isDirectory, relativeTo: URL(filePath: repository, directoryHint: .isDirectory))
        let exclude = gitFolder.appending(path: "info/exclude")

        guard let text = Self.excludeText(adding: "/\(NewWorktree.projectFolder)/", to: (try? String(contentsOf: exclude, encoding: .utf8)) ?? "") else {
            return
        }

        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: exclude, options: .atomic)
    }

    // nil when the file has the line already.
    static func excludeText(adding line: String, to current: String) -> String? {
        guard !current.split(whereSeparator: \.isNewline).contains(where: { $0 == line }) else {
            return nil
        }

        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        return "\(current)\(separator)\(line)\n"
    }

    // git worktree add makes a local branch from a branch on a remote when one remote has it.
    private func branchExists(_ branch: String, in repository: String, git: URL) async -> Bool {
        if await succeeds(git, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository) {
            return true
        }

        let remotes = try? await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "for-each-ref", "--format=%(refname)", "refs/remotes/*/\(branch)"]))

        return remotes?.trimmed.split(separator: "\n").count == 1
    }

    private func succeeds(_ git: URL, _ arguments: [String], in repository: String) async -> Bool {
        (try? await CommandRunner.run(Command(executable: git, arguments: ["-C", repository] + arguments))) != nil
    }
}
