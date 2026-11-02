import NexusCore
import ServiceManagement

// nexusd runs from Contents/MacOS of the app, so SMAppService finds both plists in the app
// bundle. Removing nexusd itself ends this process.
enum BackgroundServices {
    static func unregisterAll() {
        try? SMAppService.daemon(plistName: "\(NexusIdentifiers.helper).plist").unregister()
        try? SMAppService.agent(plistName: "\(NexusIdentifiers.daemon).plist").unregister()
    }
}
