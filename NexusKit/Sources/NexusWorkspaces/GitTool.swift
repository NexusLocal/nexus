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

    static func executable(hasDeveloperTools: Bool, isProgram: (String) -> Bool) -> URL? {
        hasDeveloperTools ? URL(filePath: "/usr/bin/git") : otherPrograms.first(where: isProgram).map { URL(filePath: $0) }
    }
}
