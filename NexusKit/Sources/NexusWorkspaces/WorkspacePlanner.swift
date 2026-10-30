import Foundation
import NexusCore

// Compares the worktrees that git lists with what Nexus knows. A site without a known state
// keeps the worktrees that it has without a workspace. One application has 14 worktrees. A new
// site must not copy its databases 14 times. `nexus workspace create` makes a workspace for such
// a worktree (D40).
public enum WorkspacePlanner {
    // subfolder is the path of the project folder in the repository, with a leading /, or empty.
    // excluded holds the worktrees that are sites themselves. They get no workspace, also not
    // after that site goes away. So they count as listed. A worktree that git still adds gets no
    // workspace yet. The same applies to a worktree of a branch without the folder of the site. It
    // does not count as listed, so it gets its workspace when the folder comes.
    public static func update(
        _ known: SiteWorktrees?,
        listed: [Worktree],
        automatic: Bool,
        subfolder: String,
        excluded: Set<String>,
        folderExists: (String) -> Bool = { _ in true }
    ) -> SiteWorktrees {
        let finished = listed.filter { !$0.adding }

        guard let known else {
            return SiteWorktrees(listed: Set(finished.map(\.path)))
        }

        let paths = Set(listed.map(\.path))
        let goneWithoutWorkspace = known.listed.subtracting(paths).subtracting(known.workspaces.map(\.worktree))
        var kept = known.workspaces.filter { paths.contains($0.worktree) }
        var gone = known.workspaces.filter { !paths.contains($0.worktree) }
        var waiting: Set<String> = []

        for index in kept.indices {
            kept[index].branch = listed.first { $0.path == kept[index].worktree }?.branch
            kept[index].folder = kept[index].worktree + subfolder
        }

        for worktree in finished where !known.listed.contains(worktree.path) && !excluded.contains(worktree.path + subfolder) {
            let name = folderName(of: worktree.path)

            guard folderExists(worktree.path + subfolder) else {
                waiting.insert(worktree.path)
                continue
            }

            // git worktree move keeps the name of the folder. A workspace with its databases must
            // survive this. It needs a new setup, because its .env can hold the old path of a
            // SQLite file.
            if let moved = gone.first(where: { folderName(of: $0.worktree) == name }) {
                gone.removeAll { $0.name == moved.name }
                var workspace = moved
                workspace.worktree = worktree.path
                workspace.folder = worktree.path + subfolder
                workspace.branch = worktree.branch
                workspace.state = .preparing
                kept.append(workspace)
                continue
            }

            // A moved worktree without a workspace is no new worktree.
            guard automatic, !goneWithoutWorkspace.contains(where: { folderName(of: $0) == name }) else {
                continue
            }

            let workspaceName = Workspace.name(forFolder: name, taken: Set(kept.map(\.name) + gone.map(\.name)))
            kept.append(Workspace(name: workspaceName, worktree: worktree.path, folder: worktree.path + subfolder, branch: worktree.branch))
        }

        return SiteWorktrees(listed: known.listed.intersection(paths).union(finished.map(\.path)).subtracting(waiting), workspaces: kept)
    }

    private static func folderName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
