import NexusCore
import Observation
import ServiceManagement

@Observable
final class BackgroundServices {
    let daemon = BackgroundServiceRegistration.daemon()
    let helper = BackgroundServiceRegistration.helper()
    let login = BackgroundServiceRegistration.login()

    var isAllowed: Bool {
        daemon.isEnabled && helper.isEnabled
    }

    var needsApproval: Bool {
        daemon.needsApproval || helper.needsApproval
    }

    var registrationError: String? {
        daemon.lastError ?? helper.lastError
    }

    func registerIfNeeded() {
        daemon.registerIfNeeded()
        helper.registerIfNeeded()
    }

    func refresh() {
        daemon.refresh()
        helper.refresh()
        login.refresh()
    }

    // The text for a banner when the user must turn Nexus on in Login Items.
    var approvalNeeded: String? {
        let place = "Turn on \(NexusVariant.current.name) in System Settings > General > Login Items & Extensions."

        if daemon.needsApproval {
            return "\(place) Without it, no service runs."
        }

        if helper.needsApproval {
            return "\(place) Without it, macOS does not send the names of your sites to Nexus."
        }

        return nil
    }
}

// Registers one of the two launchd jobs in the app bundle: the agent nexusd, and the helper
// daemon that writes /etc/resolver and /etc/hosts. The helper needs the approval of the user in
// System Settings. nexusd does not. The login item opens the app at login (D5).
@Observable
final class BackgroundServiceRegistration {
    private let service: SMAppService
    private let name: String
    private let label: String?

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    static func daemon() -> BackgroundServiceRegistration {
        BackgroundServiceRegistration(service: .agent(plistName: "\(NexusIdentifiers.daemon).plist"), name: "Background service", label: NexusIdentifiers.daemon)
    }

    static func helper() -> BackgroundServiceRegistration {
        BackgroundServiceRegistration(service: .daemon(plistName: "\(NexusIdentifiers.helper).plist"), name: "Helper for DNS")
    }

    static func login() -> BackgroundServiceRegistration {
        BackgroundServiceRegistration(service: .mainApp, name: "Start at login")
    }

    private init(service: SMAppService, name: String, label: String? = nil) {
        self.service = service
        self.name = name
        self.label = label
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var summary: String {
        switch status {
        case .enabled: "\(name) is on"
        case .requiresApproval: "\(name) needs approval in System Settings"
        case .notRegistered: "\(name) is off"
        case .notFound: "\(name) is missing from the app"
        @unknown default: "\(name) state is unknown"
        }
    }

    func registerIfNeeded() {
        status = service.status

        #if DEBUG
        renewLaunchRecordAfterABuild()
        #endif

        guard status != .enabled, status != .requiresApproval else {
            return
        }

        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        status = service.status
    }

    #if DEBUG
    // The launch record of the Nexus Dev nexusd can hold the code hash of the build that macOS
    // registered. After the next build macOS then refuses each start of nexusd ("needs LWCR
    // update", exit 78), and a toggle in Login Items does not help. Another copy of Nexus Dev, for
    // example a build in another folder, can also register nexusd. When that copy is gone, each
    // start fails with exit 78 too. A new registration writes the record of this build. nexusd
    // needs no approval of the user. A release has the stable signature of the team and one
    // place, so it never needs this.
    private func renewLaunchRecordAfterABuild() {
        guard let label, status == .enabled else {
            return
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else {
            return
        }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard text.contains("spawn failed"), text.contains("needs LWCR update") || text.contains("last exit code = 78") else {
            return
        }

        ActivityTracker.log.write("background", "Nexus Dev registers nexusd again, because macOS kept the launch record of an older build")
        try? service.unregister()
        try? service.register()
        status = service.status
    }
    #endif

    func refresh() {
        let current = service.status

        if current != status {
            status = current
        }
    }

    // An item that waits for approval counts as on. The user then turns it on in System
    // Settings.
    var isOn: Bool {
        isEnabled || needsApproval
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
