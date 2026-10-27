import NexusCore
import Observation
import ServiceManagement

@Observable
final class BackgroundServices {
    let daemon = BackgroundServiceRegistration.daemon()
    let helper = BackgroundServiceRegistration.helper()

    func registerIfNeeded() {
        daemon.registerIfNeeded()
        helper.registerIfNeeded()
    }

    func refresh() {
        daemon.refresh()
        helper.refresh()
    }

    // The text for a banner when the user must turn Nexus on in Login Items.
    var approvalNeeded: String? {
        let place = "Turn on Nexus in System Settings > General > Login Items & Extensions."

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
// System Settings. nexusd does not.
@Observable
final class BackgroundServiceRegistration {
    private let service: SMAppService
    private let name: String

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    static func daemon() -> BackgroundServiceRegistration {
        BackgroundServiceRegistration(service: .agent(plistName: "\(NexusIdentifiers.daemon).plist"), name: "Background service")
    }

    static func helper() -> BackgroundServiceRegistration {
        BackgroundServiceRegistration(service: .daemon(plistName: "\(NexusIdentifiers.helper).plist"), name: "Helper for DNS")
    }

    private init(service: SMAppService, name: String) {
        self.service = service
        self.name = name
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

    func refresh() {
        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
