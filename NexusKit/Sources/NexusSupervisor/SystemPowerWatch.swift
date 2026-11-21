import Foundation
import IOKit
import IOKit.pwr_mgt

// The sleep and the wake of macOS for nexusd (group 4, 4b). nexusd is no app. So it uses
// IORegisterForSystemPower on a dispatch queue. Swift does not import the message macros of IOKit.
// So this file has their values. macOS waits up to 30 seconds for an answer to a question about
// sleep. So the watch allows each sleep at once. nexusd takes no power assertion (decision 6).
public final class SystemPowerWatch: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case willSleep
        case didWake
    }

    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.power")
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    public init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    // false when macOS gives no port. Then nexusd has only the check each minute.
    public func start() -> Bool {
        queue.sync {
            guard rootPort == 0 else {
                return true
            }

            let context = Unmanaged.passUnretained(self).toOpaque()
            let port = IORegisterForSystemPower(context, &notificationPort, { context, _, message, argument in
                guard let context else {
                    return
                }

                Unmanaged<SystemPowerWatch>.fromOpaque(context).takeUnretainedValue().handle(message, argument: argument)
            }, &notifier)

            guard port != 0, let notificationPort else {
                return false
            }

            rootPort = port
            IONotificationPortSetDispatchQueue(notificationPort, queue)
            return true
        }
    }

    public func stop() {
        queue.sync {
            close()
        }
    }

    // The last release can come in a callback on the queue. So this does not wait for the queue.
    deinit {
        close()
    }

    private func close() {
        guard rootPort != 0 else {
            return
        }

        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)

        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }

        rootPort = 0
        notificationPort = nil
        notifier = 0
    }

    // The event of a message. canSystemSleep gives nil. The watch allows that sleep.
    static func event(for message: UInt32) -> Event? {
        switch message {
        case systemWillSleep: .willSleep
        case systemHasPoweredOn: .didWake
        default: nil
        }
    }

    // The callback runs on the queue of the watch.
    private func handle(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        if message == Self.canSystemSleep || message == Self.systemWillSleep {
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        }

        if let event = Self.event(for: message) {
            onEvent(event)
        }
    }
}
