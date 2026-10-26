import AppKit
import NexusCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let daemon: DaemonRegistration

    var body: some View {
        Text("Nexus \(NexusVersion.current())")
        Text(daemon.summary)

        if daemon.needsApproval {
            Button("Open Login Items Settings") {
                daemon.openLoginItemsSettings()
            }
        }

        Divider()

        Button("Open Nexus") {
            openWindow(id: MainWindow.id)
            NSApplication.shared.activate()
        }

        Divider()

        Button("Quit Nexus") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
