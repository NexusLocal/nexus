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
    private var nexusdStartsThisBuild = false
    private var restarted: Bool
    // The old nexusd still sends events while it stops its services. Only an event after the end
    // of its connection can show that the restart did not help.
    private var restartEnded: Bool

    public init(appBuild: String, lastRestartBuild: String? = nil) {
        self.appBuild = appBuild
        restarted = lastRestartBuild == appBuild
        restartEnded = restarted
    }

    public var restartDidNotHelp: Bool {
        nexusdIsOld && restartEnded && !nexusdStartsThisBuild
    }

    public mutating func connectionEnded() {
        restartEnded = restarted
    }

    public mutating func received(build: String?, updateBuild: String? = nil) {
        nexusdIsOld = build != appBuild
        nexusdStartsThisBuild = updateBuild == appBuild
    }

    public mutating func takeRestart(tasksRun: Bool) -> Bool {
        guard nexusdIsOld, !nexusdStartsThisBuild, !restarted, !tasksRun else {
            return false
        }

        restarted = true
        return true
    }
}
