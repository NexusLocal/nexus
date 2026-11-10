import AppKit
import Sparkle

// With automatic install, Sparkle downloads an update without a window and installs it only when
// Nexus quits. Most users seldom quit Nexus. So Nexus asks for a restart as soon as the update is
// ready, and again after an hour when the user chooses "Not now" (owner, 2026-11-10).
final class UpdateReadyPrompt: NSObject, SPUUpdaterDelegate {
    private static let reminderInterval: TimeInterval = 3600

    private var install: (() -> Void)?
    private var version = ""
    private var reminder: Timer?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        install = immediateInstallHandler
        version = item.displayVersionString

        DispatchQueue.main.async { [weak self] in
            self?.ask()
        }

        return true
    }

    func ask() {
        reminder?.invalidate()
        reminder = nil

        guard let install else {
            return
        }

        NSApplication.shared.activate()

        if restartNow() {
            install()
            return
        }

        reminder = Timer.scheduledTimer(withTimeInterval: Self.reminderInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.ask()
            }
        }
    }

    private func restartNow() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A new version of Nexus"
        alert.informativeText = "Nexus downloaded version \(version) for you. Restart Nexus to install it. Your sites stop for a few seconds."
        alert.addButton(withTitle: "Restart and install")
        alert.addButton(withTitle: "Not now").keyEquivalent = "\u{1b}"
        alert.accessoryView = whatsNewLink()

        // macOS does not bring an app to the front by itself, so the window floats above the
        // windows of other apps.
        alert.window.level = .floating

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func whatsNewLink() -> NSButton {
        let link = NSButton(title: "What's new in \(version)", target: self, action: #selector(openReleaseNotes))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.sizeToFit()

        return link
    }

    @objc private func openReleaseNotes() {
        guard let url = URL(string: "https://\(AppUpdater.repository)/releases/tag/v\(version)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    #if DEBUG
    func preview(version: String) {
        self.version = version
        install = {}
        ask()
    }
    #endif
}
