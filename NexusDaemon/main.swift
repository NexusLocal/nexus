import Foundation
import NexusCore
import NexusEngine
import NexusIPC
import NexusTLS

if CommandLine.arguments.contains("--version") {
    print("nexusd \(NexusVersion.current())")
    exit(0)
}

let paths = NexusPaths.standard
try? paths.createFolders()

// nexusd is in Contents/MacOS of the app. The nexus command is in Contents/Helpers. A start from
// a moved app gives the links the new place. The name of the folder must match exactly: the file
// system ignores capitals. So MacOS/nexus is the app itself.
let contents = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()

if let contents {
    let command = contents.appending(path: "Helpers/nexus")

    if CommandLinks.canPoint(to: command) {
        try? CommandLinks.write(in: paths.bin, command: command)
    }
}

let activity = ActivityLog(file: paths.activityLog, source: "nexusd")
activity.write("launch", "nexusd \(NexusVersion.current()) build \(NexusVersion.build())")
ErrorDetails.write(to: paths.errorLog)

let engine = NexusEngine(
    paths: paths,
    helper: HelperClient(),
    certificateAuthority: CertificateAuthority(paths: paths),
    activity: activity,
    unregister: BackgroundServices.unregisterAll
)
let service = DaemonService(engine: engine, activity: activity)
let listener = NSXPCListener(machServiceName: NexusIdentifiers.daemon)
listener.delegate = service
listener.resume()

Task {
    await engine.startEnabledServices()
}

// nexusd stops every service first, so no database keeps running without its supervisor.
@Sendable func stop(_ reason: String) async {
    activity.write("stop", reason)
    await engine.shutdown()
    activity.waitForWrites()
    exit(0)
}

// Only a build in an app bundle can get an update. launchd starts the new build after the exit.
if let app = contents?.deletingLastPathComponent(), app.pathExtension == "app" {
    Task {
        await engine.restartAfterUpdates(of: app) { newBuild in
            await stop("nexusd stops for build \(newBuild) of the app")
        }
    }
}

// launchd sends SIGTERM when the user logs out or turns the service off.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        await stop("nexusd stops")
    }
}
termination.resume()

dispatchMain()
