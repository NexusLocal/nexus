import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime
import NexusSupervisor
import NexusWorkspaces

// The files of a workspace (D49, part 8g). A clone uses no extra disk until a file changes. A clone
// that fails or a path that git sees in the worktree gives a warning (D50). A worktree without
// vendor then also gets no check of its configuration, so that workspace is not isolated (D48).
extension NexusEngine {
    // application holds the configuration of the main checkout. applicationRoot is the top folder of
    // its .gitignore files. A repository in the public folder does not hold the application.
    typealias FileFolders = (main: String, worktree: String, repository: String, application: String, applicationRoot: String)

    private struct Installer {
        let lockFile: String
        let folder: String
        let tool: ProjectTool
        let arguments: [String]
        // npm ci removes the folder first. composer install uses what the folder holds.
        let replacesFolder: Bool
    }

    private static let installers = [
        Installer(lockFile: "composer.lock", folder: "vendor", tool: .composer, arguments: ["install", "--no-interaction"], replacesFolder: false),
        Installer(lockFile: "package-lock.json", folder: "node_modules", tool: .npm, arguments: ["ci"], replacesFolder: true),
    ]

    // Nexus has no yarn and no pnpm, so the user runs these.
    private static let otherLockFiles = ["yarn.lock", "pnpm-lock.yaml"]

    func cloneFiles(into workspace: inout Workspace, key: String, beforeInstall: (inout Workspace) async -> Void) async {
        guard let folders = await fileFolders(of: workspace, key: key), let git = await GitTool.executable() else {
            return
        }

        await forgetInstalls(in: folders.worktree, of: &workspace, key: key)

        // A clone of a folder that the install removes costs seconds for nothing. When the install
        // fails, the worktree still gets that clone.
        let replaced = Self.installers.filter { $0.replacesFolder && workspace.state == .preparing && Self.newLockFile(of: $0, in: folders, workspace: workspace) != nil }
        var warnings = await clone(in: folders, git: git, leavingOut: replaced.map { "\($0.folder)/" })

        // Another program can write vendor or node_modules of the worktree at the same time, for
        // example a script that copies them and runs composer install. The probe and the install
        // wait until it stops.
        let installFolders = Self.installers.map { "\(folders.worktree)/\($0.folder)" }

        for installer in Self.installers {
            // The install before this one can give the packages that an earlier probe needed.
            if Self.newLockFile(of: installer, in: folders, workspace: workspace) != nil {
                await FolderActivity.waitUntilQuiet(installFolders, quiet: workspaceFolderQuiet)
                await beforeInstall(&workspace)
            }

            guard let warning = await install(installer, folders: folders, git: git, workspace: workspace, key: key) else {
                continue
            }

            warnings.append(warning)

            if installer.replacesFolder {
                warnings += await clone(in: folders, git: git)
            }
        }

        await FolderActivity.waitUntilQuiet(installFolders, quiet: workspaceFolderQuiet)

        for lockFile in Self.otherLockFiles where Self.lockFile(lockFile, differsIn: folders) {
            warnings.append("\(lockFile) is different from the main checkout, so node_modules can be out of date. Run the install in the worktree.")
        }

        workspace.warnings = warnings
    }

    private func clone(in folders: FileFolders, git: URL, leavingOut leftOut: [String] = []) async -> [String] {
        do {
            return try await cloneEntries(in: folders, git: git, leavingOut: leftOut, chosen: await chosenWorkspaceFiles(mainFolder: folders.main))
        } catch {
            return ["Nexus cannot read which files git ignores: \(ErrorText.plain(error))"]
        }
    }

    // A folder that is gone gets a new clone from the main checkout. That clone does not follow the
    // lock file of the worktree, so the record must not name that lock file.
    private func forgetInstalls(in worktree: String, of workspace: inout Workspace, key: String) async {
        let installed = Self.installers.filter { workspace.installedLockFiles[$0.lockFile] != nil }

        for installer in installed where !FileManager.default.fileExists(atPath: "\(worktree)/\(installer.folder)") {
            workspace.installedLockFiles[installer.lockFile] = nil
            try? await updateRecord(of: workspace.name, key: key) { [lockFile = installer.lockFile] record in
                record.installedLockFiles[lockFile] = nil
            }
        }
    }

    // True when the worktree has a lock file that the main checkout does not have.
    private static func lockFile(_ name: String, differsIn folders: FileFolders) -> Bool {
        guard let lock = try? Data(contentsOf: URL(filePath: "\(folders.worktree)/\(name)")) else {
            return false
        }

        return lock != (try? Data(contentsOf: URL(filePath: "\(folders.main)/\(name)")))
    }

    static func digest(of file: String, in folder: String) -> String? {
        try? FileChecksum.sha256(of: URL(filePath: "\(folder)/\(file)"))
    }

    // The digest of the lock file when the folder does not fit it. The folder fits the lock file of
    // the last install, or else the lock file of the main checkout. So a lock file that goes back
    // to the one of the main checkout needs an install too.
    private static func newLockFile(of installer: Installer, in folders: FileFolders, workspace: Workspace) -> String? {
        let lockFile = installer.lockFile

        guard let digest = digest(of: lockFile, in: folders.worktree),
              digest != workspace.installedLockFiles[lockFile] ?? Self.digest(of: lockFile, in: folders.main) else {
            return nil
        }

        return digest
    }

    // A repository in the public folder does not hold the application above it. git can only list
    // the files of the repository, and the worktree holds only these files.
    func fileFolders(of workspace: Workspace, key: String) async -> FileFolders? {
        fileFolders(of: workspace, key: key, sites: resolvedSites(await stateStore.current()).map(\.site))
    }

    func fileFolders(of workspace: Workspace, key: String, sites: [Site]) -> FileFolders? {
        guard let site = sites.first(where: { ProjectFolder.workspaceKey(of: $0) == key }) else {
            return nil
        }

        let project = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)
        let main = RealPath.of(LaravelProject.root(containing: project) ?? project)
        let worktree = Self.applicationFolder(main, of: site, in: workspace)

        guard let root = ProjectFolder.repository(of: site)?.root else {
            return (main: main, worktree: worktree, repository: main, application: main, applicationRoot: main)
        }

        let holdsApplication = RealPath.contains(root, main)

        return (
            main: holdsApplication ? main : root,
            worktree: worktree,
            repository: root,
            application: main,
            applicationRoot: holdsApplication ? root : main
        )
    }

    // The paths of the sites of the project in this folder of the main checkout. A repository can
    // hold the project in a subfolder, and a site can be on the public folder of the project.
    private func chosenWorkspaceFiles(mainFolder: String) async -> [String] {
        let sites = resolvedSites(await stateStore.current()).map(\.site)
        let own = sites.filter { site in
            let project = ProjectFolder.projectFolder(of: site)
            return RealPath.contains(mainFolder, project) || RealPath.contains(project, mainFolder)
        }

        return Self.distinct(own.flatMap { $0.workspaceFiles ?? [] })
    }

    // A cloned .env file such as .env.testing names the servers of the main site, so tests in the
    // workspace would write to them (owner, 2026-11-09). A key gets the value of the workspace when
    // the file has the value of the main .env, or when the file does not have the key, because the
    // default of the configuration can be the server of the main site. A value of its own, for
    // example DB_DATABASE=:memory:, stays.
    static func chosenEnvKeys(_ keys: [String: String], file: [String: String], main: [String: String]) -> [String: String] {
        keys.filter { key, _ in
            guard let value = file[key] else {
                return true
            }

            return value == main[key]
        }
    }

    func rewriteChosenEnvFiles(_ written: WrittenEnv, in workspace: inout Workspace) async {
        guard let rewrite = written.envRewrite else {
            return
        }

        let main = EnvFile.values(of: URL(filePath: "\(written.mainFolder)/.env"))
        let envFiles = await chosenWorkspaceFiles(mainFolder: written.mainFolder).filter { ($0 as NSString).lastPathComponent.hasPrefix(".env.") }

        for path in envFiles where FileManager.default.fileExists(atPath: "\(written.folder)/\(path)") {
            guard (try? await GitTool.ignores(path, in: written.folder, git: written.git)) == true else {
                workspace.warnings.append("git does not ignore \(path) in this worktree, so Nexus does not change its keys.")
                continue
            }

            do {
                let file = "\(written.folder)/\(path)"
                let text = try Self.envText(of: file)
                let keys = Self.chosenEnvKeys(rewrite.keys, file: EnvFile.values(in: text), main: main)

                try Data(EnvRewrite.apply(to: text, hosts: rewrite.hosts, keys: keys).utf8).write(to: URL(filePath: file), options: .atomic)
            } catch {
                workspace.warnings.append("Nexus did not change the keys in \(path) of this worktree: \(ErrorText.plain(error))")
            }
        }
    }

    private func cloneEntries(in folders: FileFolders, git: URL, leavingOut leftOut: [String], chosen: [String]) async throws -> [String] {
        let exists = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)) != nil }
        let worktree = folders.worktree
        let ignoredInMain = try await GitTool.ignoredEntries(in: folders.main, git: git)
        let isWordPress = PHPProject.type(of: URL(filePath: folders.application, directoryHint: .isDirectory)).isWordPress
        // A folder that git ignores can hold worktrees, for example .claude/worktrees. A clone of it
        // would copy each worktree. It would also copy the new worktree into itself.
        let worktrees = try await WorktreeList.read(repository: folders.repository, git: git).map(\.path)
        let holdsWorktree = { (entry: String) in
            let path = "\(folders.main)/\(RealPath.trimmed(entry))"
            return worktrees.contains { $0 == path || $0.hasPrefix("\(path)/") }
        }
        let automatic = isWordPress ? WorkspaceFiles.clonableForWordPress(ignoredInMain) : WorkspaceFiles.clonable(ignoredInMain)
        let entries = Self.distinct(automatic + WorkspaceFiles.chosen(ignoredInMain, paths: chosen))
            .filter { entry in !exists("\(worktree)/\(entry)") && !leftOut.contains { entry.hasPrefix($0) } && !holdsWorktree(entry) }
        let ignored = try await GitTool.ignored(entries.filter { !Self.isBehindLink($0, in: worktree) }, in: worktree, git: git)
        var warnings = Self.warning(for: entries.filter { !ignored.contains($0) })

        for entry in entries where ignored.contains(entry) {
            // A clone can take long, and git can remove or move the worktree in that time. A
            // clone would make that folder again. A stop of nexusd also ends the setup.
            guard !watchingStopped, FileManager.default.fileExists(atPath: worktree) else {
                return warnings
            }

            // Another program can make the path during the clone. Its file or folder stays.
            do {
                try await clone(entry, in: folders)
            } catch FileCloneError.targetExists, CocoaError.fileWriteFileExists {
                continue
            } catch {
                warnings.append(ErrorText.plain(error))
            }
        }

        return warnings
    }

    // git stops with an error on a path behind a link, for each path of the command. A branch can
    // have a link where the main checkout has a folder. So only that path must get no clone.
    private static func isBehindLink(_ entry: String, in worktree: String) -> Bool {
        let parent = entry.hasSuffix("/") ? entry : (entry as NSString).deletingLastPathComponent
        var path = worktree

        return parent.split(separator: "/").contains { folder in
            path += "/\(folder)"
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        }
    }

    private static func warning(for paths: [String]) -> [String] {
        guard let first = paths.first else {
            return []
        }

        return paths.count == 1
            ? ["git does not ignore \(first) in this worktree, so Nexus does not clone it."]
            : ["git does not ignore \(first) and \(paths.count - 1) more paths in this worktree, so Nexus does not clone them."]
    }

    private func clone(_ entry: String, in folders: FileFolders) async throws {
        let path = RealPath.trimmed(entry)
        let source = "\(folders.main)/\(path)"
        let target = "\(folders.worktree)/\(path)"

        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: source) else {
            try await Self.cloneOutsideTheActor(source, to: target) { clone in
                try WorkspaceFiles.repairClone(at: clone, of: path, mainFolder: folders.main, repository: folders.repository)
            }
            return
        }

        let linkInRepository = String(source.dropFirst(folders.repository.count + 1))

        guard let inWorktree = WorkspaceFiles.linkDestination(destination, of: linkInRepository, repository: folders.repository) else {
            throw RuntimeError.unsupported("\(path) is a link to a folder outside the project, so Nexus does not clone it.")
        }

        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: inWorktree)
    }

    // The clone of vendor or node_modules fits the lock file of the main checkout. The record names
    // the lock file after a run that worked, because a new setup must not run npm ci again. That
    // command removes node_modules first. Composer and npm run the scripts of the project, and a
    // script can use the database of the main site in a workspace that is not isolated (D48).
    private func install(_ installer: Installer, folders: FileFolders, git: URL, workspace: Workspace, key: String) async -> String? {
        let lockFile = installer.lockFile

        guard let digest = Self.newLockFile(of: installer, in: folders, workspace: workspace) else {
            return nil
        }

        let settings = await stateStore.current().workspaceSettings

        guard installer.tool == .composer ? settings.runsComposerInstall : settings.runsNpmInstall else {
            return "\(installer.folder) does not fit \(lockFile). The install is off in Settings > Workspaces, so run it in the worktree."
        }

        guard workspace.state == .preparing else {
            return "\(installer.folder) does not fit \(lockFile), and Nexus runs no install in a workspace that is not isolated."
        }

        do {
            guard try await GitTool.ignores("\(installer.folder)/", in: folders.worktree, git: git) else {
                return "\(installer.folder) does not fit \(lockFile), and git does not ignore \(installer.folder)/ in this worktree. So Nexus runs no install."
            }

            let tool = try await toolCommand(installer.tool, folder: folders.worktree, inSetup: true)
            let command = Command(
                executable: URL(filePath: tool.executable),
                arguments: tool.arguments + installer.arguments,
                environment: environment(of: tool),
                workingDirectory: URL(filePath: folders.worktree, directoryHint: .isDirectory)
            )

            guard !watchingStopped else {
                return nil
            }

            _ = try await run(command, in: workspace.worktree)
            try await updateRecord(of: workspace.name, key: key) { record in
                record.installedLockFiles[lockFile] = digest
            }
            return nil
        } catch {
            Self.removeLeftover(of: installer, in: folders.worktree, worktree: workspace.worktree)
            return "\(installer.folder) does not fit \(lockFile), and the install failed: \(ErrorText.plain(error))"
        }
    }

    // The .git file of a worktree goes first when git removes it. An install that still ran then
    // makes the folder again, and that folder blocks a new worktree on this path.
    private static func removeLeftover(of installer: Installer, in folder: String, worktree: String) {
        guard !FileManager.default.fileExists(atPath: "\(worktree)/.git") else {
            return
        }

        try? FileManager.default.removeItem(atPath: "\(folder)/\(installer.folder)")

        var path = folder

        while RealPath.contains(worktree, path), rmdir(path) == 0 {
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
