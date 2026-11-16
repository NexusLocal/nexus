import AppKit
import NexusCore
import NexusIPC

// Old workspaces (owner, 2026-11-15). nexusd decides which notification is due and keeps its time
// in its state. The switch "When workspaces are old" of Settings > General is a setting of the app.
// While it is off, the app does not ask. macOS shows no notification while Nexus is the active
// app. So the app asks only while another app is active. The next hour tries again.
extension AppModel {
    static let oldWorkspacesCheck: Duration = .seconds(3600)

    func watchOldWorkspaces() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.oldWorkspacesCheck)
                await self?.notifyOldWorkspaces()
            }
        }
    }

    private func notifyOldWorkspaces() async {
        guard isLive, AppPreference.isOn(AppPreference.notifyOldWorkspaces), !NSApplication.shared.isActive else {
            return
        }

        guard case .answer(.oldWorkspaceNotices(let notices)) = await outcome(of: .oldWorkspaceNotices) else {
            return
        }

        for notice in notices {
            Notifier.post(OldWorkspaces.title(host: notice.host), OldWorkspaces.notificationBody(names: notice.names, days: notice.days), target: .oldWorkspaces(site: notice.host), setting: AppPreference.notifyOldWorkspaces)
        }
    }

    // The sheet closes at once. The rows show "Removing" until git removed the worktrees. The dumps
    // then show in the activity list.
    func removeOldWorkspaces(_ names: [String], of host: String) {
        guard let site = site(host) else {
            return
        }

        let workspaces = site.workspaces.filter { names.contains($0.name) }

        guard !workspaces.isEmpty else {
            return
        }

        removeAndShowRefusals(workspaces, of: site)
    }
}
