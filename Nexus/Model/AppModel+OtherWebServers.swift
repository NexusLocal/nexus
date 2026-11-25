import AppKit
import NexusCore
import NexusIPC

extension AppModel {
    var webServerNoticeNames: [String] {
        guard let nginx = service(ServiceID.nginx), nginx.isActive else {
            return []
        }

        // The notice of the move from Herd or Valet offers more than other ports. After a move, the
        // app gave its ports to Nexus. So the app is not in this notice then.
        let movesFromApp = showsHerdMoveNotice || herdMovedText != nil || herdSitesMoved
        let hidden = movesFromApp ? hiddenWebServerNotice.union([moveSource.name]) : hiddenWebServerNotice
        return OtherWebServers.noticeNames(installed: otherWebServers, hidden: hidden, nginxPorts: nginx.ports.map(\.number))
    }

    func findOtherWebServers() {
        let found = OtherWebServers.installed(
            home: NSHomeDirectory(),
            hasApp: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )

        if found != otherWebServers {
            otherWebServers = found
        }
    }

    func hideWebServerNotice() {
        hideWebServerNotice(of: otherWebServers)
    }

    func hideWebServerNotice(of names: [String]) {
        hiddenWebServerNotice.formUnion(names)
        UserDefaults.standard.set(hiddenWebServerNotice.sorted(), forKey: AppPreference.hiddenWebServerNotice)
    }

    func moveWebPortsForOtherApps() async -> DoneMessage? {
        let names = otherWebServers
        let moved = OtherWebServers.movedWebPorts

        if client == nil {
            setSampleWebPorts(http: moved.http, https: moved.https)
        } else if await perform(.setWebPorts(http: moved.http, https: moved.https), failure: "nginx did not get ports \(moved.http) and \(moved.https)", place: .window) == nil {
            return nil
        }

        return DoneMessage(title: OtherWebServers.movedTitle, message: OtherWebServers.movedMessage(names, exampleHost: allSites.first?.host))
    }

    func setSampleWebPorts(http: Int, https: Int) {
        guard let index = services.firstIndex(where: { $0.id == ServiceID.nginx }) else {
            return
        }

        services[index].ports = [ServicePort(name: "HTTP", number: http, key: "http"), ServicePort(name: "HTTPS", number: https, key: "https")]
    }
}
