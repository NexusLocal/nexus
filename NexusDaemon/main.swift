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
if let contents = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent() {
    let command = contents.appending(path: "Helpers/nexus")

    if FileManager.default.isExecutableFile(atPath: command.path(percentEncoded: false)) {
        try? CommandLinks.write(in: paths.bin, command: command)
    }
}

let engine = NexusEngine(
    paths: paths,
    helper: HelperClient(),
    certificateAuthority: CertificateAuthority(paths: paths),
    unregister: BackgroundServices.unregisterAll
)
let service = DaemonService(engine: engine)
let listener = NSXPCListener(machServiceName: NexusIdentifiers.daemon)
listener.delegate = service
listener.resume()

Task {
    await engine.startEnabledServices()
}

// launchd sends SIGTERM when the user logs out or turns the service off. nexusd then stops every
// service, so no database keeps running without its supervisor.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        await engine.shutdown()
        exit(0)
    }
}
termination.resume()

dispatchMain()
