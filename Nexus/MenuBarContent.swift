import AppKit
import NexusCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Nexus \(NexusVersion.current())")

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
