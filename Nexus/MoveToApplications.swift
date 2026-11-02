import AppKit
import NexusCore

// This runs before the first window. So Nexus registers no background service from a place that
// goes away (see AppLocation). A debug build runs from the build folder and never asks.
enum MoveToApplications {
    static var willAsk: Bool {
        #if DEBUG
        false
        #else
        AppLocation.isTemporary(Bundle.main.bundleURL)
        #endif
    }

    static func askIfNeeded() {
        guard willAsk else {
            return
        }

        let bundle = Bundle.main.bundleURL

        NSApplication.shared.activate()

        guard userAgrees(toMove: bundle) else {
            exit(0)
        }

        do {
            let app = try AppLocation.move(bundle, to: AppLocation.applications)
            quitOtherInstances()

            if !open(app) {
                warn("Nexus cannot start", "Nexus is now in Applications. Open it from there.")
            }
        } catch {
            warn("Nexus cannot move to Applications", "\(error.localizedDescription) Drag Nexus to Applications in the disk image window.")
        }

        exit(0)
    }

    private static func userAgrees(toMove bundle: URL) -> Bool {
        let installed = AppLocation.target(of: bundle, in: AppLocation.applications)
        let replaces = FileManager.default.fileExists(atPath: installed.path(percentEncoded: false))
        let reason = "Nexus runs from the disk image now. It stops working when you close the disk image."

        let alert = NSAlert()
        alert.messageText = "Move Nexus to Applications?"
        alert.informativeText = replaces ? "\(reason) The Nexus in Applications goes to the Trash." : reason
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")

        return alert.runModal() == .alertFirstButtonReturn
    }

    // An older Nexus can still run from the copy that is now in the Trash.
    private static func quitOtherInstances() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: NexusIdentifiers.app)

        for other in others where other != .current {
            other.terminate()
        }
    }

    // The open command starts a second instance, because this instance is still running.
    private static func open(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-n", app.path(percentEncoded: false)]

        guard (try? process.run()) != nil else {
            return false
        }

        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    private static func warn(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
