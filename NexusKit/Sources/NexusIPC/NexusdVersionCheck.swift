import NexusCore

// An update or a move replaces the files of the app, but a running nexusd keeps its old code. A
// nexusd after 0.1.1 starts the new build of its app by itself when no work runs, and it names that
// build in updateBuild. The app then waits. In every other case the app restarts nexusd one time for
// each build of the app, also over more launches of the app. Examples are a nexusd of 0.1.1, and a
// new app in another folder than the app of nexusd. The app waits for running tasks, because a
// restart ends them. A second restart does not help. It only stops the services again.
//
// An event that the app cannot read gives no restart. The app cannot see the running tasks then.
// The app shows the problem with a button, and ReleaseEventTests keep the events of each release
// readable.
public struct NexusdVersionCheck: Sendable, Equatable {
    private let appBuild: String
    private var nexusdIsOld = false
    private var nexusdIsOlder = false
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

    // An older nexusd drops the fields of a newer app without an error. A newer nexusd reads each
    // change of an older app.
    public var waitsForNewNexusd: Bool {
        nexusdIsOlder && !restartDidNotHelp
    }

    public mutating func connectionEnded() {
        restartEnded = restarted
        restartRuns = false
        nexusdIsOlder = false
    }

    public mutating func received(build: String?, updateBuild: String? = nil) {
        nexusdIsOld = build != appBuild
        nexusdIsOlder = NexusVersion.isOlder(build, than: appBuild)
        nexusdStartsThisBuild = updateBuild == appBuild

        if !nexusdIsOld {
            restartRuns = false
        }
    }

    public mutating func takeRestart(tasksRun: Bool) -> Bool {
        guard nexusdIsOld, !nexusdStartsThisBuild, !restarted, !tasksRun else {
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
        case .fromAgent(_, let request):
            request.isSafeForAnOlderNexusd
        default:
            onlyReads
        }
    }
}
