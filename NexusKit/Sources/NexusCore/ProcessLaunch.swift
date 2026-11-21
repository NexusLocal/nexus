import Foundation

// Each program inherits the Mach exception ports of Nexus at its start. The start of Sentry has
// ports of its own for a moment, until CrashReports puts the old ports back. The lock keeps each
// start of a program out of that moment (Sentry NEXUS-8).
public enum ProcessLaunch {
    private static let lock = NSLock()

    public static func run(_ process: Process) throws {
        try lock.withLock {
            try process.run()
        }
    }

    public static func withoutStarts<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }
}
