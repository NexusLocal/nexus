import Darwin
import Foundation

// A job of launchd in the domain of the user. A Homebrew service, such as homebrew.mxcl.mailpit,
// has KeepAlive in its launchd file. So launchd starts it again at once after a SIGTERM, and its
// port stays in use. Only brew services stop takes the job away (Phase 3, 3a).
public struct LaunchdJob: Sendable, Equatable {
    public static let homebrewPrefix = "homebrew.mxcl."

    public let label: String
    public let pid: Int32

    // The formula of a Homebrew service, for example mailpit or mysql@8.4.
    public var homebrewFormula: String? {
        label.hasPrefix(Self.homebrewPrefix) ? String(label.dropFirst(Self.homebrewPrefix.count)) : nil
    }

    // The program on a port can be a child of the job, for example the mysqld of mysqld_safe. So
    // the parents count too, up to launchd itself.
    public static func of(pid: Int32) async -> LaunchdJob? {
        guard let list = try? await CommandRunner.run(Command(executable: URL(filePath: "/bin/launchctl"), arguments: ["list"])) else {
            return nil
        }

        return of(pid: pid, list: list.standardOutput)
    }

    static func of(pid: Int32, list: String, lookup: (Int32) -> ProcessEntry? = ProcessTable.entry(of:)) -> LaunchdJob? {
        let labels = labelsByPID(in: list)
        var current = pid

        while current > 1 {
            if let label = labels[current] {
                return LaunchdJob(label: label, pid: current)
            }

            guard let parent = lookup(current)?.parent else {
                return nil
            }

            current = parent
        }

        return nil
    }

    // launchctl list gives "PID<tab>Status<tab>Label". A job that does not run has "-" as its PID.
    static func labelsByPID(in list: String) -> [Int32: String] {
        var labels: [Int32: String] = [:]

        for line in list.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)

            guard columns.count >= 3, let pid = Int32(columns[0]) else {
                continue
            }

            labels[pid] = String(columns[2])
        }

        return labels
    }

    // The brew of the Homebrew folder that holds the program. macOS gives no path for a program
    // whose file Homebrew removed at an update, so then each Homebrew folder counts. Without a
    // brew, launchctl takes the job away until the next login.
    public func stopHomebrewService(executable: String?) async throws {
        guard let formula = homebrewFormula else {
            throw SupervisorError.launchFailed("\(label) is no Homebrew service.")
        }

        let brew = Self.brew(for: executable) { FileManager.default.isExecutableFile(atPath: $0) }

        guard let brew else {
            _ = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/launchctl"), arguments: ["bootout", "gui/\(getuid())/\(label)"]))
            return
        }

        let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        _ = try await CommandRunner.run(Command(executable: brew, arguments: ["services", "stop", formula], environment: environment))
    }

    static func brew(for executable: String?, exists: (String) -> Bool) -> URL? {
        let prefixes = ["/opt/homebrew/", "/usr/local/"]
        let candidates = executable.map { path in prefixes.filter { path.hasPrefix($0) } } ?? prefixes

        return candidates.map { "\($0)bin/brew" }.first(where: exists).map { URL(filePath: $0) }
    }
}
