import Darwin
import Foundation
import Synchronization

public enum ProgramChange: Sendable, Equatable {
    case updated
    case removed
}

// The file of a program as it was at the start of the program. An update of Nexus replaces the
// file. macOS then refuses each message of the old process to nexusd, because it cannot find the
// code of that process. So a program that runs long compares its file with this value. It then
// does not say that Nexus does not run (bug 2026-11-17).
public struct ExecutableFile: Sendable, Equatable {
    public let path: String
    let identity: FileIdentity
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    public init?(path: String) {
        var status = stat()

        guard stat(path, &status) == 0 else {
            return nil
        }

        self.path = path
        identity = FileIdentity(status)
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
    }

    // bin/nexus is a link to the program in the app. So the path has no links.
    public static func ofThisProcess() -> ExecutableFile? {
        Bundle.main.executableURL.map(RealPath.of).flatMap(ExecutableFile.init(path:))
    }

    public var change: ProgramChange? {
        guard let current = ExecutableFile(path: path) else {
            return .removed
        }

        return current == self ? nil : .updated
    }

    private static let recorded = Mutex<ExecutableFile?>(nil)
    private static let missingSince = Mutex<ContinuousClock.Instant?>(nil)
    public static let missingWait: Duration = .seconds(10)

    // The nexus command records its file at its start. The app and nexusd do not. So only the nexus
    // command gets the errors of a changed program.
    public static func recordStart() {
        let file = ofThisProcess()
        recorded.withLock { $0 = file }
    }

    public static var atStart: ExecutableFile? {
        recorded.withLock { $0 }
    }

    public static var changeSinceStart: ProgramChange? {
        let change = atStart?.change
        return missingSince.withLock { since in settled(change, missingSince: &since, now: .now) }
    }

    // An update can move the old app away before it puts the new one in place. So a missing file
    // counts as an update until it is missing for missingWait.
    static func settled(_ change: ProgramChange?, missingSince: inout ContinuousClock.Instant?, now: ContinuousClock.Instant) -> ProgramChange? {
        guard change == .removed else {
            missingSince = nil
            return change
        }

        let since = missingSince ?? now
        missingSince = since
        return now - since < missingWait ? .updated : .removed
    }
}
