import SwiftUI

@main
struct NexusApp: App {
    @State private var daemon = DaemonRegistration()

    var body: some Scene {
        Window("Nexus", id: MainWindow.id) {
            MainWindow()
                .task { daemon.registerIfNeeded() }
        }

        MenuBarExtra("Nexus", systemImage: "server.rack") {
            MenuBarContent(daemon: daemon)
        }
    }
}
