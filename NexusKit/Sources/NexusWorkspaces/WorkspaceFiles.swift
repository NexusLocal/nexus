import Foundation
import NexusCore

// What a workspace gets from the main checkout (D49). The entries come from git, so each one is a
// path that git ignores there. git can list a folder as one entry or list the paths in it, for
// example for vendor/* or a tracked public/index.php. So each ignored path in these folders
// counts. bootstrap/cache and the .env files are not on this list.
public enum WorkspaceFiles {
    // Laravel Passport signs its tokens with keys in storage. Without them, a login fails.
    private static let folders = ["vendor", "node_modules", "public", "dist", "build", "storage/app", "storage/oauth", "storage/oauth-private.key", "storage/oauth-public.key"]

    // public/hot holds the address of the Vite server of the main site. The application in the
    // worktree would load its assets from there.
    private static let leftOut: Set<String> = ["public/hot"]

    // git also lists each folder above an ignored path when that folder holds no tracked file. git
    // does not ignore such a folder itself, so only the paths in it count.
    public static func clonable(_ entries: [String]) -> [String] {
        let foldersAbovePaths = Set(entries.map { "\((RealPath.trimmed($0) as NSString).deletingLastPathComponent)/" })

        return entries.filter { entry in
            let path = RealPath.trimmed(entry)

            guard !leftOut.contains(path), !foldersAbovePaths.contains(entry) else {
                return false
            }

            return folders.contains { path == $0 || path.hasPrefix("\($0)/") }
        }
    }

    // A folder that git ignores as a whole is one entry. So the list cannot leave out a path in it,
    // and the clone holds the links of that folder as they are. path is the place of the folder in
    // the application. A link outside the repository keeps its place, because the main site uses
    // it the same way. A relative link to that place gets the full path, because the worktree is
    // in another folder.
    public static func repairClone(at clone: String, of path: String, mainFolder: String, repository: String) throws {
        let manager = FileManager.default
        let folder = String("\(mainFolder)/\(path)".dropFirst(repository.count + 1))

        for left in leftOut where left.hasPrefix("\(path)/") {
            try? manager.removeItem(atPath: clone + left.dropFirst(path.count))
        }

        guard let items = manager.enumerator(atPath: clone) else {
            return
        }

        while let item = items.nextObject() as? String {
            guard items.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink else {
                continue
            }

            let link = "\(clone)/\(item)"

            guard let destination = try? manager.destinationOfSymbolicLink(atPath: link) else {
                continue
            }

            let place = "\(folder)/\(item)"
            let inWorktree = linkDestination(destination, of: place, repository: repository) ?? target(of: destination, at: place, repository: repository)

            guard inWorktree != destination else {
                continue
            }

            try manager.removeItem(atPath: link)
            try manager.createSymbolicLink(atPath: link, withDestinationPath: inWorktree)
        }
    }

    // php artisan storage:link writes an absolute link. In a workspace, that link must not lead
    // into the main checkout, because an upload would then go to the main site. A relative link
    // stays in the worktree, also after git worktree move. link is the path of the link in the
    // repository, because the worktree holds the whole repository. Gives nil for a link that leads
    // outside the repository.
    public static func linkDestination(_ destination: String, of link: String, repository: String) -> String? {
        let target = target(of: destination, at: link, repository: repository)

        guard RealPath.contains(repository, target) else {
            return nil
        }

        guard destination.hasPrefix("/") else {
            return destination
        }

        let up = link.split(separator: "/").dropLast().map { _ in ".." }
        let down = target.dropFirst(repository.count).split(separator: "/").map(String.init)

        return (up + down).joined(separator: "/")
    }

    // A link can name the main checkout through another path, such as /tmp for /private/tmp.
    private static func target(of destination: String, at link: String, repository: String) -> String {
        let folder = URL(filePath: "\(repository)/\(link)").deletingLastPathComponent()

        return RealPath.of(URL(filePath: destination, relativeTo: folder).absoluteURL.standardized)
    }
}
