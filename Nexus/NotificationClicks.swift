import AppKit
import NexusCore
import UserNotifications

// A click on a notification opens the screen of the notification (owner, 2026-11-14). The app
// gives the model at its launch, so a click also works while Nexus runs only in the menu bar. The
// main window gives the action that opens it, the first time that it shows. Before that, a reopen
// event of the app opens the window. A sheet or an alert in the window keeps the screen as it is.
// The click then only brings the window to the front. macOS calls the delegate outside the main
// actor. So the conformance is nonisolated. The delegate must be there before the launch ends.
final class NotificationClicks: NSObject, nonisolated UNUserNotificationCenterDelegate {
    static let shared = NotificationClicks()

    private var model: AppModel?
    private var openMainWindow: (() -> Void)?

    func connect(_ model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    func connect(openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let target = NotificationTarget(userInfo: content.userInfo)
        let title = content.title
        await open(target, title: title)
    }

    func open(_ target: NotificationTarget?, title: String) {
        ActivityTracker.log.write("notification", title)

        let busy = model.map { windowIsBusy($0, alertTitle: title) } ?? true

        if let openMainWindow {
            openMainWindow()
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }

        NSApplication.shared.activate()

        guard !busy, let model, let target else {
            return
        }

        model.show(target)
    }

    private func windowIsBusy(_ model: AppModel, alertTitle: String) -> Bool {
        if model.windowHasDialog {
            return true
        }

        // The alert of a failed import has the title of its notification. That alert does not
        // stop the click (owner, 2026-11-14).
        if let failure = model.windowFailure {
            return failure.title != alertTitle
        }

        let mainWindow = NSApplication.shared.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }
        return NSApplication.shared.modalWindow != nil || mainWindow?.attachedSheet != nil
    }
}
