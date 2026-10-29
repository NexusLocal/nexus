import Foundation

// The site that holds a folder, for nexus php, composer, node and npm (D38). root is the folder
// of the site in the checkout of that folder. In a git worktree, root is in the worktree, because
// the worktree has its own files such as .nvmrc.
public struct ProjectLocation: Sendable, Equatable {
    public let site: Site
    public let root: URL

    public init(site: Site, root: URL) {
        self.site = site
        self.root = root
    }
}

public enum ProjectFolder {
    // The deepest site folder that holds the folder wins. A folder in a git worktree of a site
    // also belongs to that site, when the worktree is outside the folder of the site. A worktree
    // of the repository that holds a site gives the same subfolder in the worktree.
    public static func locate(_ folder: URL, in sites: [Site]) -> ProjectLocation? {
        let path = RealPath.of(folder)
        let siteFolders = sites.map { (site: $0, path: RealPath.of($0.folder)) }

        func deepestSite(holding path: String) -> (site: Site, path: String)? {
            siteFolders.filter { RealPath.contains($0.path, path) }.max { $0.path.count < $1.path.count }
        }

        if let found = deepestSite(holding: path) {
            return ProjectLocation(site: found.site, root: URL(filePath: found.path, directoryHint: .isDirectory))
        }

        guard let worktree = worktree(holding: path) else {
            return nil
        }

        guard let found = deepestSite(holding: worktree.mainCheckout + path.dropFirst(worktree.root.count)),
              RealPath.contains(worktree.mainCheckout, found.path) else {
            return nil
        }

        let root = worktree.root + found.path.dropFirst(worktree.mainCheckout.count)
        return ProjectLocation(site: found.site, root: URL(filePath: root, directoryHint: .isDirectory))
    }

    // A git worktree has a .git file with the line "gitdir: <folder>". That folder is in
    // .git/worktrees of the main checkout and has a commondir file. A submodule also has a .git
    // file, but its folder has no commondir file. A folder with a .git folder is a main checkout.
    static func worktree(holding path: String) -> (root: String, mainCheckout: String)? {
        var current = path
        let fileManager = FileManager.default

        while true {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isFolder: ObjCBool = false

            if fileManager.fileExists(atPath: dotGit, isDirectory: &isFolder) {
                guard !isFolder.boolValue, let gitDir = gitDir(in: dotGit, base: current) else {
                    return nil
                }

                guard let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) else {
                    return nil
                }

                let commonDir = RealPath.of(URL(filePath: common.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory, relativeTo: URL(filePath: gitDir, directoryHint: .isDirectory)))
                return (current, (commonDir as NSString).deletingLastPathComponent)
            }

            guard current != "/" else {
                return nil
            }

            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func gitDir(in file: String, base: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }

        let folder = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return RealPath.of(URL(filePath: folder, directoryHint: .isDirectory, relativeTo: URL(filePath: base, directoryHint: .isDirectory)))
    }
}
