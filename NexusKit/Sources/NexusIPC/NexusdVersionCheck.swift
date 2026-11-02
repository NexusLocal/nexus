// An update or a move replaces the files of the app, but a running nexusd keeps its old code. So
// the app restarts nexusd one time for each build of the app, also over more launches of the app.
// It waits for running tasks, because a restart ends them. A second restart does not help. It only
// stops the services again.
public struct NexusdVersionCheck: Sendable, Equatable {
    private let appBuild: String
    private var nexusdIsOld = false
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
        nexusdIsOld && restartEnded
    }

    public mutating func connectionEnded() {
        restartEnded = restarted
    }

    public mutating func received(build: String?) {
        nexusdIsOld = build != appBuild
    }

    public mutating func receivedUnreadableEvent() {
        nexusdIsOld = true
    }

    public mutating func takeRestart(tasksRun: Bool) -> Bool {
        guard nexusdIsOld, !restarted, !tasksRun else {
            return false
        }

        restarted = true
        return true
    }
}
