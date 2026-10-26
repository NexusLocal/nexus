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
