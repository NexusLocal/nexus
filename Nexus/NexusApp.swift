import SwiftUI

@main
struct NexusApp: App {
    var body: some Scene {
        Window("Nexus", id: MainWindow.id) {
            MainWindow()
        }

        MenuBarExtra("Nexus", systemImage: "server.rack") {
            MenuBarContent()
        }
    }
}
