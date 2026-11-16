import NexusCore
import NexusIPC
import SwiftUI

// The items of the menu of a workspace row (owner, 2026-11-15). The "..." button and a right click
// on the row show them. "Stop when idle", "Stop Now" and "Start" come above a divider. A locked
// worktree keeps them. git keeps a locked worktree also with --force. So "Remove Workspace…" is off
// there, and its help says why.
struct WorkspaceRowMenu: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceInfo
    let site: SiteItem

    private var stopsWhenIdle: Binding<Bool> {
        Binding(
            get: { workspace.stopsWhenIdle },
            set: { stops in
                Task { await model.setKeepAwake(!stops, workspace, of: site) }
            }
        )
    }

    var body: some View {
        Toggle("Stop when idle", isOn: stopsWhenIdle)
            .disabled(model.isRemoving(workspace))

        if workspace.runState == .stopped {
            Button("Start") {
                Task { await model.startWorkspace(workspace, of: site) }
            }
            .disabled(model.isRemoving(workspace))
        } else {
            Button("Stop Now") {
                Task { await model.stopWorkspace(workspace, of: site) }
            }
            .disabled(workspace.shownRunState != .running || model.isRemoving(workspace))
        }

        Divider()

        Button("Remove Workspace…", systemImage: "trash", role: .destructive) {
            model.askToRemove(workspace, of: site)
        }
        .disabled(workspace.locked != nil || model.isRemoving(workspace))
        .help(workspace.locked.map { WorkspaceRemovalText.lockedHelp(reason: $0) } ?? "")
    }
}

// The "..." button at the end of a workspace row. The design is "Site Workspaces Section · Rows
// and menu" in nexus.pen. The row has no room for the title of MoreMenu, so it shows only the icon.
struct WorkspaceMenuButton: View {
    let workspace: WorkspaceInfo
    let site: SiteItem

    var body: some View {
        MoreMenu {
            WorkspaceRowMenu(workspace: workspace, site: site)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}
