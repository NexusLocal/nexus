import Foundation

// The site that holds a folder, for nexus php, composer, node and npm (D38). root is the project
// folder of the site in the checkout of that folder. In a git worktree, root is in the worktree,
// because the worktree has its own files such as .nvmrc.
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
        let siteFolders = sites.map { (site: $0, path: projectFolder(of: $0), folder: RealPath.of($0.folder)) }

        // A site on a project and a site on its public folder have the same project folder. The
        // site whose own folder holds the path wins then.
        func deepestSite(holding path: String) -> (site: Site, path: String, folder: String)? {
            func ownDepth(_ folder: String) -> Int {
                RealPath.contains(folder, path) ? folder.count : 0
            }

            return siteFolders.filter { RealPath.contains($0.path, path) }.max {
                ($0.path.count, ownDepth($0.folder)) < ($1.path.count, ownDepth($1.folder))
            }
        }

        if let found = deepestSite(holding: path) {
            return ProjectLocation(site: found.site, root: URL(filePath: found.path, directoryHint: .isDirectory))
        }

        guard let worktree = worktree(holding: path) else {
            return nil
        }

        guard let found = deepestSite(holding: worktree.mainCheckout + path.dropFirst(worktree.root.count)) else {
            return nil
        }

        // The project folder of a public folder that is a repository itself is outside that
        // repository. A worktree has only the files of the repository.
        let folder = RealPath.contains(worktree.mainCheckout, found.path) ? found.path : found.folder

        guard RealPath.contains(worktree.mainCheckout, folder) else {
            return nil
        }

        let root = worktree.root + folder.dropFirst(worktree.mainCheckout.count)
        return ProjectLocation(site: found.site, root: URL(filePath: root, directoryHint: .isDirectory))
    }

    // A site can point at the public folder of a project, as a host of MAMP PRO does. The whole
    // project then belongs to the site. Only composer.json counts as the project file, because a
    // package.json can be in the home folder. A public folder without this file is a site of its
    // own.
    public static func projectFolder(of site: Site) -> String {
        let path = RealPath.of(site.folder)

        guard (path as NSString).lastPathComponent == "public" else {
            return path
        }

        let parent = (path as NSString).deletingLastPathComponent
        let hasComposerFile = FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent("composer.json"))

        return hasComposerFile ? parent : path
    }

    // The key of the workspace record of a site. It leaves out /public. So the key stays the same
    // when composer.json comes or goes, and the sites of one project share a record.
    public static func workspaceKey(of site: Site) -> String {
        let path = RealPath.of(site.folder)
        return (path as NSString).lastPathComponent == "public" ? (path as NSString).deletingLastPathComponent : path
    }

    // The main checkout that holds a folder. A .git file means a worktree or a submodule. Their
    // workspaces belong to the site of the main checkout.
    public static func repository(holding path: String) -> String? {
        nearestGit(from: path).flatMap { $0.isFolder ? $0.folder : nil }
    }

    private static func nearestGit(from path: String) -> (folder: String, isFolder: Bool)? {
        var current = path

        while true {
            var isFolder: ObjCBool = false

            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git"), isDirectory: &isFolder) {
                return (current, isFolder.boolValue)
            }

            guard current != "/" else {
                return nil
            }

            current = (current as NSString).deletingLastPathComponent
        }
    }

    // The repository of a site, and the path of the project folder in it with a leading / or
    // empty. A public folder that is a repository itself has its project folder outside that
    // repository. So a worktree holds only the public folder.
    public static func repository(of site: Site) -> (root: String, subfolder: String)? {
        let project = projectFolder(of: site)

        guard let root = repository(holding: RealPath.of(site.folder)) ?? repository(holding: project) else {
            return nil
        }

        return (root, RealPath.contains(root, project) ? String(project.dropFirst(root.count)) : "")
    }

    public static func adminFolder(ofWorktree path: String) -> String? {
        gitDir(in: (path as NSString).appendingPathComponent(".git"), base: path)
    }

    // A git worktree has a .git file with the line "gitdir: <folder>". That folder is in
    // .git/worktrees of the main checkout and has a commondir file. A submodule also has a .git
    // file, but its folder has no commondir file. A folder with a .git folder is a main checkout.
    static func worktree(holding path: String) -> (root: String, mainCheckout: String)? {
        guard let git = nearestGit(from: path), !git.isFolder, let gitDir = adminFolder(ofWorktree: git.folder) else {
            return nil
        }

        guard let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) else {
            return nil
        }

        let commonDir = RealPath.of(URL(filePath: common.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory, relativeTo: URL(filePath: gitDir, directoryHint: .isDirectory)))
        return (git.folder, (commonDir as NSString).deletingLastPathComponent)
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
