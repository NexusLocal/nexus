import Foundation
import NexusSupervisor

// /usr/bin/git is only a stub without the developer tools of Apple. A run of that stub shows the
// install dialog of macOS at each check. xcode-select -p shows no dialog. So it tells if the stub
// is safe to run.
public enum GitTool {
    public static let missing = "Nexus needs git to find the worktrees of a site. Run: xcode-select --install"

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
