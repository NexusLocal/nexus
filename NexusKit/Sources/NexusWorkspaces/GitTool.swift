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

    static func executable(hasDeveloperTools: Bool, isProgram: (String) -> Bool) -> URL? {
        hasDeveloperTools ? URL(filePath: "/usr/bin/git") : otherPrograms.first(where: isProgram).map { URL(filePath: $0) }
    }
}
