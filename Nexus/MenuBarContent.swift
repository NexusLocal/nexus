import AppKit
import NexusCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let daemon: BackgroundServiceRegistration
    let helper: BackgroundServiceRegistration

    var body: some View {
        Text("Nexus \(NexusVersion.current())")
        Text(daemon.summary)
        Text(helper.summary)

        if daemon.needsApproval || helper.needsApproval {
            Button("Open Login Items Settings") {
                helper.openLoginItemsSettings()
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
