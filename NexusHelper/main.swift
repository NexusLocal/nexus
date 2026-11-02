import Foundation
import NexusCore

if CommandLine.arguments.contains("--version") {
    print("NexusHelper \(NexusVersion.current())")
    exit(0)
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: NexusIdentifiers.helper)
listener.delegate = service
listener.resume()

dispatchMain()
