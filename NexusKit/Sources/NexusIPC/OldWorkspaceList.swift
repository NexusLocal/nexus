import Foundation
import NexusCore

// The old workspaces of one site with the signs of git (owner, 2026-11-15). The sheet "Old
// workspaces" and nexus workspace list --old show them. days is the limit that nexusd used.
// mainBranch is the branch of the main checkout. It is nil for a detached HEAD.
public struct OldWorkspaceList: Codable, Sendable, Equatable {
    public let host: String
    public let days: Int
    public let dumpDays: Int
    // nil from a nexusd before 0.6.2, which writes a dump at each removal.
    public let dumpsBeforeRemoval: Bool?
    public let mainBranch: String?
    public let workspaces: [OldWorkspace]

    public init(host: String, days: Int, settings: WorkspaceSettings, mainBranch: String?, workspaces: [OldWorkspace]) {
        self.host = host
        self.days = days
        self.dumpDays = settings.dumpDays
        self.dumpsBeforeRemoval = settings.dumpsBeforeRemoval
        self.mainBranch = mainBranch
        self.workspaces = workspaces
    }

    public var keptDumpDays: Int? {
        WorkspaceSettings(dumpDays: dumpDays, dumpsBeforeRemoval: dumpsBeforeRemoval ?? true).keptDumpDays
    }
}

// One old workspace. The signs help the user to choose. They do not make the choice. locked is the
// lock reason of git, as in WorkspaceInfo. gitProblem holds the error of git when git cannot read the
// worktree.
public struct OldWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let branch: String?
    public let worktree: String
    public let activity: WorkspaceActivity
    public let hasDatabases: Bool
    public let merged: Bool
    public let branchGone: Bool
    public let commitsNotPushed: Int
    public let changesNotCommitted: Int
    public let locked: String?
    public let hasSubmodules: Bool
    public let folderGone: Bool
    public let gitProblem: String?

    public var id: String { name }

    // Each value after activity has a default. So a test names only what it checks.
    public init(
        name: String,
        branch: String? = nil,
        worktree: String,
        activity: WorkspaceActivity,
        hasDatabases: Bool = false,
        merged: Bool = false,
        branchGone: Bool = false,
        commitsNotPushed: Int = 0,
        changesNotCommitted: Int = 0,
        locked: String? = nil,
        hasSubmodules: Bool = false,
        folderGone: Bool = false,
        gitProblem: String? = nil
    ) {
        self.name = name
        self.branch = branch
        self.worktree = worktree
        self.activity = activity
        self.hasDatabases = hasDatabases
        self.merged = merged
        self.branchGone = branchGone
        self.commitsNotPushed = commitsNotPushed
        self.changesNotCommitted = changesNotCommitted
        self.locked = locked
        self.hasSubmodules = hasSubmodules
        self.folderGone = folderGone
        self.gitProblem = gitProblem
    }

    // git refuses git worktree remove without --force for these. The app never sends --force
    // (owner, 2026-11-15). The command line prints this text below the row. It is the text of a
    // refused removal.
    public var refusal: String? {
        if let locked {
            return WorkspaceRemovalText.locked(name, reason: locked)
        }

        if changesNotCommitted > 0 {
            return WorkspaceRemovalText.changes(name)
        }

        if hasSubmodules {
            return WorkspaceRemovalText.submodules(name)
        }

        return gitProblem
    }

    public var canGo: Bool {
        refusal == nil
    }

    // The tags of a row in "Sheet Old Workspaces" of nexus.pen. A warning is orange.
    public func signs(mainBranch: String?) -> [OldWorkspaceSign] {
        var signs: [OldWorkspaceSign] = []

        if merged, let mainBranch {
            signs.append(OldWorkspaceSign(text: "Merged into \(mainBranch)", isWarning: false))
        }

        if branchGone {
            signs.append(OldWorkspaceSign(text: "Branch gone on the remote", isWarning: false))
        }

        if commitsNotPushed > 0 {
            signs.append(OldWorkspaceSign(text: "\(Count.text(commitsNotPushed, "commit")) \(commitsNotPushed == 1 ? "is" : "are") not pushed", isWarning: true))
        }

        if folderGone {
            signs.append(OldWorkspaceSign(text: "The folder is gone", isWarning: false))
        }

        if changesNotCommitted > 0 {
            signs.append(OldWorkspaceSign(text: "\(Count.text(changesNotCommitted, "change")) \(changesNotCommitted == 1 ? "is" : "are") not committed", isWarning: true))
        }

        if let locked {
            signs.append(OldWorkspaceSign(text: locked.isEmpty ? "In use" : "In use: \(locked)", isWarning: true))
        }

        if hasSubmodules {
            signs.append(OldWorkspaceSign(text: "Has submodules", isWarning: true))
        }

        if gitProblem != nil {
            signs.append(OldWorkspaceSign(text: "git cannot read the worktree", isWarning: true))
        }

        return signs
    }
}

public struct OldWorkspaceSign: Sendable, Hashable {
    public let text: String
    public let isWarning: Bool

    public init(text: String, isWarning: Bool) {
        self.text = text
        self.isWarning = isWarning
    }
}

// A notification about old workspaces that is due now (owner, 2026-11-15). host is the first host
// of the first site of the project. The names are in alphabetical order.
public struct OldWorkspacesNotice: Codable, Sendable, Equatable {
    public let host: String
    public let names: [String]
    public let days: Int

    public init(host: String, names: [String], days: Int) {
        self.host = host
        self.names = names
        self.days = days
    }
}
