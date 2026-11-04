import Foundation
import NexusCore

// What nexusd needs to start again after an update of its app.
struct UpdateCheck: Sendable {
    let app: URL
    let running: String
    let restart: @Sendable (String) async -> Void
}

// An update replaces the files of the app, but a running nexusd keeps its old code. Only nexusd
// knows all the work that it does. The app does not, for example while it cannot read the events
// of an older nexusd. So nexusd watches the build of the app on disk itself. When the build
// changes, nexusd stops at the first moment that no work runs. launchd then starts the new build,
// because the plist of nexusd has KeepAlive.
extension NexusEngine {
    // The work that a stop would end or break. A write of the web configuration is no work here:
    // the next start writes it again.
    var isBusy: Bool {
        guard runningTasks.isEmpty, openRequests == 0 else {
            return true
        }

        guard !settingUpWorkspaces, runningCommand == nil, cloningServers.isEmpty else {
            return true
        }

        guard removingServers.isEmpty, removingWorktrees.isEmpty, databaseRemovalRun == nil else {
            return true
        }

        guard copyTargets.isEmpty, installTargets.isEmpty, updatingServices.isEmpty else {
            return true
        }

        return !emptyingRedisIndexes.isEmpty || corepackInstall != nil
    }

    // restart gets the new build. It must stop the services and end the process. runningBuild is
    // for the tests.
    public func restartAfterUpdates(
        of app: URL,
        every interval: Duration = .seconds(10),
        runningBuild: String? = nil,
        restart: @escaping @Sendable (String) async -> Void
    ) {
        updateCheck = UpdateCheck(app: app, running: runningBuild ?? NexusVersion.build(), restart: restart)
        updateWatch?.cancel()
        updateWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.checkForUpdate()
            }
        }
    }

    // A new connection of the app checks at once, so the app after an update does not wait for the
    // next round. A build that is not there, for example in the middle of an update, is no new
    // build. updateBuild tells the app that nexusd starts this build after its work.
    func checkForUpdate() {
        guard let check = updateCheck, !stoppingForUpdate else {
            return
        }

        let onDisk = NexusVersion.buildOnDisk(ofAppAt: check.app).flatMap { $0 == check.running ? nil : $0 }

        if updateBuild != onDisk {
            updateBuild = onDisk
            servicesChanged()
        }

        guard let onDisk, !isBusy else {
            return
        }

        // nexusd refuses each new request from now on, and the watches start no new setup or
        // removal. So no new work starts during the stop.
        stoppingForUpdate = true
        stopWatchingWorktrees()
        parkedWatcher?.stop()
        parkedWatcher = nil

        // The stop runs outside the watch, because shutdown() ends the watch. A task that is
        // canceled ends each wait of the stop at once.
        Task.detached {
            await check.restart(onDisk)
        }
    }
}
