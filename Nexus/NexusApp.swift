import SwiftUI

@main
struct NexusApp: App {
    @State private var daemon = BackgroundServiceRegistration.daemon()
    @State private var helper = BackgroundServiceRegistration.helper()

    var body: some Scene {
        Window("Nexus", id: MainWindow.id) {
            MainWindow()
                .task {
                    daemon.registerIfNeeded()
                    helper.registerIfNeeded()
                }
        }

        MenuBarExtra("Nexus", systemImage: "server.rack") {
            MenuBarContent(daemon: daemon, helper: helper)
                .onAppear {
                    daemon.refresh()
                    helper.refresh()
                }
        }
    }
}
