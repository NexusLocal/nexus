import Observation
import ServiceManagement

@Observable
final class DaemonRegistration {
    private let service = SMAppService.agent(plistName: "nl.roodfruit.nexus.daemon.plist")

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var summary: String {
        switch status {
        case .enabled: "Background service is on"
        case .requiresApproval: "Background service needs approval in System Settings"
        case .notRegistered: "Background service is off"
        case .notFound: "Background service is missing from the app"
        @unknown default: "Background service state is unknown"
        }
    }

    func registerIfNeeded() {
        status = service.status

        guard status != .enabled else {
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

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
