import Foundation
import NexusCore
import NexusSupervisor

// What git knows about a branch (owner, 2026-11-15). merged is true when HEAD of the main checkout
// holds the last commit of the branch. A squash merge does not count. gone is true when the
// upstream was gone at the last git fetch --prune. ahead counts the commits that the upstream does
// not have. A branch without an upstream has no ahead. Nexus never runs git fetch itself.
public struct BranchState: Sendable, Equatable {
    public var merged: Bool
    public var gone: Bool
    public var ahead: Int

    public init(merged: Bool = false, gone: Bool = false, ahead: Int = 0) {
        self.merged = merged
        self.gone = gone
        self.ahead = ahead
    }
}

// /usr/bin/git is only a stub without the developer tools of Apple. A run of that stub shows the
// install dialog of macOS at each check. xcode-select -p shows no dialog. So it tells if the stub
// is safe to run.
public enum GitTool {
    public static let missing = "Nexus needs git to find the worktrees of a site. Run: xcode-select --install"

    // git status, also inside git worktree remove, can write the index to keep it fresh.
    // GIT_OPTIONAL_LOCKS=0 keeps the index as it is. So a run of git from Nexus gives a workspace no
    // new last activity (owner, 2026-11-15).
    public static let noOptionalLocks = ["GIT_OPTIONAL_LOCKS": "0"]

    private static let otherPrograms = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]

    public static func executable() async -> URL? {
        let select = Command(executable: URL(filePath: "/usr/bin/xcode-select"), arguments: ["-p"])
        let hasDeveloperTools = (try? await CommandRunner.run(select)) != nil

        return executable(hasDeveloperTools: hasDeveloperTools, isProgram: FileManager.default.isExecutableFile(atPath:))
    }

    // Nexus never writes a file that git sees (D50). git check-ignore exits with 1 for a file that
    // git does not ignore, and with a higher status on an error.
    public static func ignores(_ file: String, in folder: String, git: URL) async throws -> Bool {
        do {
            try await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "check-ignore", "-q", "--", file]))
            return true
        } catch CommandError.failed(_, let status, _) where status == 1 {
            return false
        }
    }

    // True for a file in the index of git. git ls-files exits with 1 for a file that is not there.
    public static func tracks(_ file: String, in folder: String, git: URL) async throws -> Bool {
        do {
            try await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "ls-files", "--error-unmatch", "--", file]))
            return true
        } catch CommandError.failed(_, let status, _) where status == 1 {
            return false
        }
    }

    // The text of a file in the last commit, or nil when the commit does not have it.
    public static func committedText(_ file: String, in folder: String, git: URL) async -> String? {
        try? await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "show", "HEAD:\(file)"])).standardOutput
    }

    // True when one of these files has a change that is not committed.
    public static func hasChanges(_ files: [String], in folder: String, git: URL) async throws -> Bool {
        let output = try await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "status", "--porcelain", "--"] + files, environment: noOptionalLocks))
        return !output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The number of changes that git keeps a worktree for. These are changed, new and removed files
    // in the worktree and in its submodules.
    public static func changeCount(in folder: String, git: URL) async throws -> Int {
        let command = Command(executable: git, arguments: ["-C", folder, "status", "--porcelain", "--ignore-submodules=none"], environment: noOptionalLocks)
        return try await CommandRunner.run(command).standardOutput.split(separator: "\n").count
    }

    // git does not remove a worktree with submodules without --force. git looks for the folder
    // modules in the admin folder of the worktree. It also looks for each submodule of the index that
    // has a .git in the worktree. This check does the same. A submodule without .gitmodules is rare.
    // So the read of the index runs only when .gitmodules exists.
    public static func hasSubmodules(worktree: String, git: URL) async -> Bool {
        if let admin = ProjectFolder.adminFolder(ofWorktree: worktree), FileManager.default.fileExists(atPath: (admin as NSString).appendingPathComponent("modules")) {
            return true
        }

        guard FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent(".gitmodules")) else {
            return false
        }

        let index = (try? await CommandRunner.run(Command(executable: git, arguments: ["-C", worktree, "ls-files", "--stage", "-z"], environment: noOptionalLocks)).standardOutput) ?? ""

        return index.split(separator: "\0").contains { entry in
            guard entry.hasPrefix("160000 "), let tab = entry.firstIndex(of: "\t") else {
                return false
            }

            let folder = (worktree as NSString).appendingPathComponent(String(entry[entry.index(after: tab)...]))
            return FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git"))
        }
    }

    // The files and folders that git ignores in a folder. A folder that git ignores as a whole is
    // one entry, with a slash at its end. The list also holds the ignored files in a folder with a
    // tracked .gitignore.
    public static func ignoredEntries(in folder: String, git: URL) async throws -> [String] {
        let arguments = ["-C", folder, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]

        return try await CommandRunner.run(Command(executable: git, arguments: arguments)).standardOutput
            .split(separator: "\0")
            .map(String.init)
    }

    // The paths that git ignores in this folder. A folder can have thousands of ignored files, and
    // a command line has a limit. git puts a name with a quote or a line break in quotes. Such a
    // name then counts as a path that git sees, so Nexus does not write it.
    public static func ignored(_ paths: [String], in folder: String, git: URL) async throws -> Set<String> {
        var ignored: Set<String> = []

        for start in stride(from: 0, to: paths.count, by: 500) {
            let batch = paths[start..<min(start + 500, paths.count)]

            do {
                let output = try await CommandRunner.run(Command(executable: git, arguments: ["-C", folder, "-c", "core.quotePath=false", "check-ignore", "--"] + batch))
                ignored.formUnion(output.standardOutput.split(separator: "\n").map(String.init))
            } catch CommandError.failed(_, let status, _) where status == 1 {
                continue
            }
        }

        return ignored
    }

    static func executable(hasDeveloperTools: Bool, isProgram: (String) -> Bool) -> URL? {
        hasDeveloperTools ? URL(filePath: "/usr/bin/git") : otherPrograms.first(where: isProgram).map { URL(filePath: $0) }
    }
}

// The signs of git for the old workspaces (owner, 2026-11-15).
extension GitTool {
    // nil for a detached HEAD.
    public static func currentBranch(repository: String, git: URL) async -> String? {
        let output = try? await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "symbolic-ref", "--quiet", "--short", "HEAD"], environment: noOptionalLocks))
        return output.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func branchStates(repository: String, git: URL) async throws -> [String: BranchState] {
        let refs = try await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "for-each-ref", "--format=%(refname)%09%(upstream:track)", "refs/heads"], environment: noOptionalLocks))
        let merged = try await CommandRunner.run(Command(executable: git, arguments: ["-C", repository, "for-each-ref", "--merged=HEAD", "--format=%(refname)", "refs/heads"], environment: noOptionalLocks))

        return branchStates(refs: refs.standardOutput, merged: merged.standardOutput)
    }

    // Each line of refs is "refs/heads/<branch>", a tab and the track, for example "[gone]",
    // "[ahead 2]" or "[ahead 2, behind 1]". A branch name has no tab.
    static func branchStates(refs: String, merged: String) -> [String: BranchState] {
        let mergedBranches = Set(merged.split(separator: "\n").map { branchName(String($0)) })
        var states: [String: BranchState] = [:]

        for line in refs.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let branch = branchName(String(parts[0]))
            let track = parts.count > 1 ? String(parts[1]) : ""

            states[branch] = BranchState(merged: mergedBranches.contains(branch), gone: track == "[gone]", ahead: ahead(inTrack: track))
        }

        return states
    }

    static func ahead(inTrack track: String) -> Int {
        guard let match = track.firstMatch(of: #/ahead (\d+)/#) else {
            return 0
        }

        return Int(match.1) ?? 0
    }

    static func branchName(_ ref: String) -> String {
        ref.replacing("refs/heads/", with: "", maxReplacements: 1)
    }
}
