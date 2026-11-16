import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The old workspaces of one site (owner, 2026-11-15). The design is "Sheet Old Workspaces" and
// "Alert Remove Workspaces" in nexus.pen. No row is chosen when the sheet opens. A row that git
// refuses has a checkbox that is off. The row with changes has the button "Show in Finder". One
// confirmation removes the chosen workspaces with the request of the removal of one workspace.
struct OldWorkspacesSheet: View {
    private static let longestList: CGFloat = 360

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: String

    @State private var list: OldWorkspaceList?
    @State private var problem: String?
    @State private var chosen: Set<String> = []
    @State private var confirms = false
    @State private var errorReport: ErrorReport?
    @State private var listHeight: CGFloat = 0

    // A workspace that nexusd removes now is not a choice.
    private var rows: [OldWorkspace] {
        (list?.workspaces ?? []).filter { !model.removingWorktrees.contains($0.worktree) }
    }

    private var chosenRows: [OldWorkspace] {
        rows.filter { $0.canGo && chosen.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(OldWorkspaces.title(host: host))
                .font(.headline)

            if let list {
                Text(OldWorkspaces.introText(days: list.days, dumpDays: list.dumpDays))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content

            Text(OldWorkspaces.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Choose all that can go") {
                    chosen = Set(rows.filter(\.canGo).map(\.name))
                }
                .disabled(!rows.contains(where: \.canGo))

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(OldWorkspaces.removeButtonTitle(count: chosenRows.count)) {
                    confirms = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenRows.isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 600)
        .task {
            await load()
        }
        .alert(OldWorkspaces.confirmationTitle(count: chosenRows.count), isPresented: $confirms) {
            Button(OldWorkspaces.confirmationButton(count: chosenRows.count), role: .destructive) {
                let names = chosenRows.map(\.name)
                dismiss()
                model.removeOldWorkspaces(names, of: host)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(OldWorkspaces.confirmationMessage(names: chosenRows.map(\.name), dumpDays: list?.dumpDays ?? WorkspaceSettings().dumpDays, hasDatabases: chosenRows.contains(where: \.hasDatabases)))
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
    }

    // git takes up to about 3 seconds for 24 worktrees. So a small progress view shows first.
    @ViewBuilder
    private var content: some View {
        if let problem {
            FailureLabel(message: problem) { errorReport = $0 }
        } else if let list {
            if rows.isEmpty {
                Text(OldWorkspaces.emptyText(host: host, days: list.days))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, workspace in
                            if index > 0 {
                                Divider()
                            }

                            row(workspace)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, Self.longestList))
                .scrollBounceBehavior(.basedOnSize)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }

    private func row(_ workspace: OldWorkspace) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { chosen.contains(workspace.name) },
                set: { isOn in
                    if isOn {
                        chosen.insert(workspace.name)
                    } else {
                        chosen.remove(workspace.name)
                    }
                }
            )) {
                Text(workspace.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!workspace.canGo)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label {
                        Text(workspace.name)
                            .fontWeight(.medium)
                            .foregroundStyle(workspace.canGo ? Color.primary : Color.secondary)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(workspace.activity.text(now: .now))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                let signs = workspace.signs(mainBranch: list?.mainBranch)

                if !signs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(signs, id: \.self) { sign in
                            SiteTag(text: sign.text, tint: sign.isWarning ? .warning : .neutral)
                        }
                    }
                }
            }

            if workspace.changesNotCommitted > 0, !workspace.folderGone {
                Button("Show in Finder") {
                    model.showInFinder(workspace.worktree)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .help((workspace.worktree as NSString).abbreviatingWithTildeInPath)
    }

    private func load() async {
        guard model.isLive else {
            list = AppModel.sampleOldWorkspaceList(host: host)
            return
        }

        switch await model.outcome(of: .oldWorkspaces(host: host)) {
        case .answer(.oldWorkspaces(let answer)):
            list = answer
        case .failure(let message):
            problem = message
        default:
            problem = "nexusd did not send the old workspaces of \(host)."
        }
    }
}
