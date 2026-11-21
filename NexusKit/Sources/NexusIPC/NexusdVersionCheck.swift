import Foundation
import NexusCore

// An update or a move replaces the files of the app, but a running nexusd keeps its old code. A
// nexusd after 0.1.1 starts the new build of its app by itself when no work runs. It names that
// build in updateBuild. The app cannot see all the work of an older nexusd. So the app waits for
// it, but at most longestWait (owner, 2026-11-16). Then the app restarts it. A mistake in an older
// nexusd then cannot keep it running. Another nexusd gets the restart of the app after its tasks.
// Examples are a nexusd of 0.1.1 and a nexusd of the app in another folder. The app restarts
// nexusd one time for each build of the app, also over more launches of the app. A second restart
// does not help. It only stops the services again.
//
// An event that the app cannot read gives no restart. The app cannot see the running tasks then.
// The app shows the problem with a button, and ReleaseEventTests keep the events of each release
// readable.
public struct NexusdVersionCheck: Sendable, Equatable {
    public static let longestWait: TimeInterval = 600

    private let appBuild: String
    private var nexusdIsOld = false
    private var nexusdIsOlder = false
    // A new connection to the same older nexusd keeps the time.
    private var olderSince: Date?
    private var nexusdStartsThisBuild = false
    private var restarted: Bool
    // The old nexusd still sends events while it stops its services. Only an event after the end
    // of its connection can show that the restart did not help.
    private var restartEnded: Bool
    public private(set) var restartRuns = false

    public init(appBuild: String, lastRestartBuild: String? = nil) {
        self.appBuild = appBuild
        restarted = lastRestartBuild == appBuild
        restartEnded = restarted
    }

    public var restartDidNotHelp: Bool {
        nexusdIsOld && restartEnded && !nexusdStartsThisBuild
    }

    // A nexusd up to 0.6.3 drops the fields of a newer app without an error. A later nexusd refuses
    // them with unreadableRequest. A newer nexusd reads each change of an older app.
    public var waitsForNewNexusd: Bool {
        nexusdIsOlder && !restartDidNotHelp
    }

    public var restartDeadline: Date? {
        guard waitsForNewNexusd, !restarted else {
            return nil
        }

        return olderSince?.addingTimeInterval(Self.longestWait)
    }

    public mutating func connectionEnded() {
        restartEnded = restarted
        restartRuns = false
        nexusdIsOlder = false
    }

    public mutating func received(build: String?, updateBuild: String? = nil, at now: Date = .now) {
        nexusdIsOld = build != appBuild
        nexusdIsOlder = NexusVersion.isOlder(build, than: appBuild)
        nexusdStartsThisBuild = updateBuild == appBuild
        olderSince = nexusdIsOlder ? olderSince ?? now : nil

        if !nexusdIsOld {
            restartRuns = false
        }
    }

    public mutating func takeRestart(tasksRun: Bool, at now: Date = .now) -> Bool {
        guard nexusdIsOld, !restarted else {
            return false
        }

        if let restartDeadline, now >= restartDeadline {
            return beginRestart()
        }

        guard !nexusdStartsThisBuild, !tasksRun else {
            return false
        }

        return beginRestart()
    }

    // The restart counts before launchctl ends, because the connection of the old nexusd can end
    // first. A second restart while one runs would stop the new nexusd again.
    public mutating func beginRestart() -> Bool {
        guard !restartRuns else {
            return false
        }

        restartRuns = true
        restarted = true
        return true
    }

    // The failed restart still counts in this launch. So the app does not try again and again by
    // itself.
    public mutating func restartFailed() {
        restartRuns = false
    }
}

extension NexusRequest {
    // These requests carry no struct that can get new fields. The stop of a task can end the work
    // that nexusd waits for.
    public var isSafeForAnOlderNexusd: Bool {
        switch self {
        case .stopTask, .start, .stop, .restart, .stopAll, .startStopped, .stopWorkspace, .retryWorkspace, .restartApp:
            true
        case .startWorkspace(_, _, let keepAwake):
            keepAwake == nil
        // An older nexusd cannot decode a case of the public links, also not a read (group 4).
        case .shares, .sharePreview, .startShare, .stopShare, .stopAllShares, .setShareDefaults, .rebuildShare, .shareRequest, .checkOwnDomain, .connectOwnDomain, .cancelOwnDomain, .disconnectOwnDomain:
            false
        case .clearLinkRequests:
            false
        case .fromAgent(_, let request):
            request.isSafeForAnOlderNexusd
        default:
            onlyReads
        }
    }
}
