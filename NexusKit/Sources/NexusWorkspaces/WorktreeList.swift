import Foundation
import NexusCore
import NexusSupervisor

// A linked worktree, as git lists it. adding is true while git adds the worktree.
public struct Worktree: Sendable, Equatable {
    public let path: String
    public let branch: String?
    public let adding: Bool

    public init(path: String, branch: String? = nil, adding: Bool = false) {
        self.path = path
        self.branch = branch
        self.adding = adding
    }
}

// Only the list of git says which worktrees a repository has (D53).
public enum WorktreeList {
    public static func read(repository: String, git: URL) async throws -> [Worktree] {
        let list = Command(executable: git, arguments: ["-C", repository, "worktree", "list", "--porcelain"])

        return parse(try await CommandRunner.run(list).standardOutput, hasCheckout: hasCheckout)
    }

    // git locks a worktree until its checkout is complete. The checkout writes the index. A lock
    // alone says nothing: claude --worktree keeps its worktree locked. The text of the lock of
    // git depends on the language of git.
    static func hasCheckout(_ path: String) -> Bool {
        ProjectFolder.adminFolder(ofWorktree: path).map { folder in
            FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("index"))
        } ?? false
    }

    // A blank line ends a record. The first record is the main checkout. It is no worktree of
    // the site.
    static func parse(_ porcelain: String, hasCheckout: (String) -> Bool) -> [Worktree] {
        let records = porcelain.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map(String.init) }

        return records.filter { !$0.isEmpty }.dropFirst().compactMap { lines in
            guard let path = value(of: "worktree", in: lines) else {
                return nil
            }

            let branch = value(of: "branch", in: lines).map { $0.replacing("refs/heads/", with: "", maxReplacements: 1) }
            let locked = lines.contains { $0 == "locked" || $0.hasPrefix("locked ") }

            return Worktree(path: path, branch: branch, adding: locked && !hasCheckout(path))
        }
    }

    private static func value(of label: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix("\(label) ") }.map { String($0.dropFirst(label.count + 1)) }
    }
}
