import AppKit
import NexusCore

// Writes what the user does to the activity log, so a problem can be traced later (owner). It uses
// the name of a control and of a window. It never reads a value or a key press, so typed text and
// passwords stay out of the log.
enum ActivityTracker {
    nonisolated static let log = ActivityLog(file: NexusPaths.standard.activityLog, source: "app")

    private static let textRoles: Set<NSAccessibility.Role> = [.staticText, .textField, .textArea]
    private static var clickMonitor: Any?

    static func start() {
        log.write("launch", "Nexus \(NexusVersion.current()) build \(NexusVersion.build()), \(ProcessInfo.processInfo.operatingSystemVersionString)")

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            logClick(event)
            return event
        }

        let center = NotificationCenter.default

        // The queue is the main queue. So the menu item is safe to read on the main actor, although
        // the compiler cannot see that.
        center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { notification in
            nonisolated(unsafe) let item = notification.userInfo?["MenuItem"] as? NSMenuItem

            MainActor.assumeIsolated {
                if let item {
                    log.write("menu", item.title)
                }
            }
        }

        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow

            MainActor.assumeIsolated {
                if let window {
                    log.write("window", window.title.isEmpty ? "A window without a title" : window.title)
                }
            }
        }

        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            log.write("stop", "Nexus quits")
            log.waitForWrites()
        }
    }

    private static func logClick(_ event: NSEvent) {
        let window = event.window?.title ?? ""
        let place = "the point \(Int(event.locationInWindow.x)), \(Int(event.locationInWindow.y))"

        log.write("click", "\(nameOfClickedControl() ?? place) in window \"\(window)\"")
    }

    // SwiftUI often gives the name to a parent of the element under the pointer.
    private static func nameOfClickedControl() -> String? {
        var element = NSApplication.shared.accessibilityHitTest(NSEvent.mouseLocation) as? any NSAccessibilityProtocol

        for _ in 0..<4 {
            guard let current = element, current.accessibilityRole() != .window else {
                return nil
            }

            if let name = controlName(of: current) {
                return name
            }

            element = current.accessibilityParent() as? any NSAccessibilityProtocol
        }

        return nil
    }

    private static func controlName(of element: any NSAccessibilityProtocol) -> String? {
        // The name of a text can be its content, such as a value of a .env file.
        if let role = element.accessibilityRole(), textRoles.contains(role) {
            return nil
        }

        let name = [element.accessibilityLabel(), element.accessibilityTitle()].compactMap { $0 }.first { !$0.isEmpty }
        return name.map { "\"\($0)\"" }
    }
}
