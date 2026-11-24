import AppKit
import NexusCore
import NexusIPC
import SwiftUI
import UniformTypeIdentifiers

struct OverviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var webPortsMoved: DoneMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch model.nexusdProblem {
                case .unreachable(let problem):
                    WarningBanner(
                        title: "Nexus cannot reach its background service",
                        message: "\(problem) Nexus tries again every few seconds. Check that Nexus is on in Login Items."
                    ) {
                        Button("Open Login Items") {
                            background.helper.openLoginItemsSettings()
                        }
                    }
                case .otherVersion(let problem):
                    WarningBanner(title: "Nexus cannot read its background service", message: problem) {
                        Button("Start it again") {
                            Task { await model.restartNexusd(from: .window) }
                        }
                        .disabled(model.restartsForNewBuild)
                    }
                case nil:
                    EmptyView()
                }

                if model.waitsForNewNexusd {
                    InfoBanner(text: model.newNexusdBannerText) {
                        Button("Restart Now") {
                            model.restartForNewBuild(from: .window)
                        }
                        .disabled(model.restartsForNewBuild)
                        .help("Starts the new version now. This stops the current work, for example an import or the setup of a workspace.")
                    }
                }

                if let approval = background.approvalNeeded {
                    WarningBanner(title: "Nexus needs your approval", message: approval) {
                        Button("Open Login Items") {
                            background.helper.openLoginItemsSettings()
                        }
                    }
                }

                // The move from Herd frees the ports of the problems below. So it comes first.
                if let movedText = model.herdMovedText {
                    HerdMovedNotice(text: movedText)
                } else if model.showsHerdMoveNotice {
                    HerdMoveNotice()
                }

                ForEach(model.blockedServices, id: \.service.id) { blocked in
                    ProblemBanner(service: blocked.service, holder: blocked.holder)
                }

                let webServerNames = model.webServerNoticeNames

                if let webPortsMoved {
                    DoneBanner(title: webPortsMoved.title, message: webPortsMoved.message) {
                        self.webPortsMoved = nil
                    }
                } else if !webServerNames.isEmpty {
                    OtherWebServersNotice(names: webServerNames) {
                        webPortsMoved = await model.moveWebPortsForOtherApps()
                    }
                }

                if model.agents.showsNotice, AppPreference.isOn(AppPreference.firstRunDone) {
                    AgentsNotice()
                }

                DropArea()

                if !model.activities.isEmpty {
                    ActivityList()
                }

                // Below Activity (owner, 2026-11-17). It shows only while a link starts or is open.
                if !model.activePublicLinks.isEmpty {
                    OverviewPublicLinks()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Services")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            ServiceGroup(title: "Webservers", services: model.versions(of: .webservers))
                            ServiceGroup(title: "PHP", services: model.versions(of: .php))
                            ServiceGroup(title: "Redis, Mail and DNS", services: model.versions(of: .redis) + model.versions(of: .mail) + model.versions(of: .dns))
                        }
                        .frame(maxWidth: .infinity)

                        ServiceGroup(title: "Databases", services: model.databaseInstances)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(20)
        }
        .screenTitle("Overview", subtitle: model.runningSummary)
        .task {
            await model.agents.loadForNotice()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    // The notice can be hidden. So the move stays here while Herd has its files.
                    if model.herdFound {
                        Button("Move from Herd…", systemImage: "tray.and.arrow.down") {
                            model.sheet = .moveFromHerd
                        }

                        Divider()
                    }

                    Button("Stop all services", systemImage: "stop") {
                        model.stopAllServices()
                    }
                    .disabled(!model.hasActiveService)

                    Button("Start stopped services", systemImage: "play") {
                        model.startStoppedServices()
                    }
                    .disabled(model.stoppedByStopAll.isEmpty)

                    Divider()

                    Button("Show logs folder", systemImage: "folder") {
                        NSWorkspace.shared.open(NexusPaths.standard.logs)
                    }

                    Button("Show activity log", systemImage: "doc.text") {
                        NSWorkspace.shared.activateFileViewerSelecting([NexusPaths.standard.activityLog])
                    }
                }
            }
        }
    }
}

// The design is "Overview Coding Agents Notice" in nexus.pen. A user who has Nexus already never
// sees the first run. So this notice shows once. "Set up…" and the close button both hide it for
// good.
private struct AgentsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NoticeBanner(systemImage: "sparkles", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: "Let your coding agent use Nexus") {
            Text("Claude Code, Codex, Cursor and other agents can then see the URL, database, logs and mail of each project.")
        } actions: {
            Button("Set up…") {
                model.agents.hideNotice()
                model.selection = .agents
            }

            HideNoticeButton {
                model.agents.hideNotice()
            }
        }
    }
}

// The design is "Overview Notice Move From Herd" in nexus.pen. The notice shows while Herd has sites
// that did not move. The close button hides it for good. After a move, the second notice shows
// until OK.
private struct HerdMoveNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NoticeBanner(systemImage: "tray.and.arrow.down", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: "Move your sites from Herd") {
            Text(model.herdMoveNoticeText)
        } actions: {
            Button("Move from Herd…") {
                model.sheet = .moveFromHerd
            }
            .buttonStyle(.borderedProminent)

            HideNoticeButton {
                model.hideHerdMoveNotice()
            }
        }
    }
}

private struct HerdMovedNotice: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        NoticeBanner(systemImage: "checkmark.circle", color: .statusGreen, background: AnyShapeStyle(.fill.quaternary), title: "Your sites moved from Herd") {
            Text(text)
        } actions: {
            Button("Show Report") {
                model.showHerdReport()
            }

            Button("OK") {
                model.hideHerdMoved()
            }
        }
    }
}

private struct OtherWebServersNotice: View {
    @Environment(AppModel.self) private var model
    @State private var moving = false
    let names: [String]
    let move: () async -> Void

    var body: some View {
        NoticeBanner(systemImage: "info.circle", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: OtherWebServers.noticeTitle(names)) {
            Text(OtherWebServers.noticeMessage(names))
        } actions: {
            Button(OtherWebServers.moveButtonTitle) {
                moving = true
                Task {
                    await move()
                    moving = false
                }
            }
            .disabled(moving)

            Button("Stop all services") {
                model.stopAllServices()
            }
            .disabled(moving)

            HideNoticeButton {
                model.hideWebServerNotice()
            }
            .disabled(moving)
        }
    }
}

private struct HideNoticeButton: View {
    let hide: () -> Void

    var body: some View {
        Button(action: hide) {
            Image(systemName: "xmark")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Hide this notice")
        .accessibilityLabel("Hide this notice")
    }
}

private struct ProblemBanner: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion
    let holder: PortHolder

    var body: some View {
        WarningBanner(
            title: "\(service.name) cannot start",
            message: holder.bannerText
        ) {
            PortHolderButtons(service: service, holder: holder)

            Button("Change port…") {
                model.sheet = .portInUse(service: service.id, holder: holder)
            }
        }
    }
}

private struct DropArea: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var pointerInside = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentText)

            VStack(alignment: .leading, spacing: 2) {
                Text("Drop a project folder here to add a site")
                    .fontWeight(.semibold)
                Text("Drop a folder of projects to park it, or a WordPress backup to import it.")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Choose folder…") {
                model.sheet = .addSite(folder: nil, manyProjects: false)
            }
        }
        .padding(16)
        .background(Color.accentSoft.opacity(targeted ? 2 : 1), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentText.opacity(targeted ? 1 : 0.6), lineWidth: 1.5)
        }
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(targeted: $targeted, pointerInside: $pointerInside, onFolder: { folder in
            Task {
                let manyProjects = await Task.detached { ProjectFolder.holdsManyProjects(folder) }.value
                model.sheet = .addSite(folder: folder, manyProjects: manyProjects)
            }
        }, onBackup: { backup in
            model.sheet = .importSite(backup: backup)
        }))
    }
}

// Accepts one folder, or one backup of WordPress (3f). It refuses other files and apps while the
// pointer is still over the area. The item provider is read before each await, because the drop
// info is not valid after the drop.
private struct FolderDropDelegate: DropDelegate {
    static let backupSuffixes = [".zip", ".wpress", ".tar.gz", ".tgz", ".tar"]

    @Binding var targeted: Bool
    @Binding var pointerInside: Bool
    let onFolder: (URL) -> Void
    var onBackup: (URL) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [.fileURL]).count == 1
    }

    func dropEntered(info: DropInfo) {
        pointerInside = true

        guard let provider = info.itemProviders(for: [.fileURL]).first else {
            return
        }

        Task {
            let accepted = await item(from: provider) != nil
            targeted = pointerInside && accepted
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: targeted ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        pointerInside = false
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        pointerInside = false

        guard targeted, let provider = info.itemProviders(for: [.fileURL]).first else {
            return false
        }

        targeted = false

        Task {
            switch await item(from: provider) {
            case .folder(let url):
                onFolder(url)
            case .backup(let url):
                onBackup(url)
            case nil:
                break
            }
        }

        return true
    }

    private enum Item {
        case folder(URL)
        case backup(URL)
    }

    private func item(from provider: NSItemProvider) async -> Item? {
        guard let url = try? await provider.loadFileURL() else {
            return nil
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])

        if values?.isDirectory == true {
            return values?.isPackage == true ? nil : .folder(url)
        }

        let name = url.lastPathComponent.lowercased()
        return Self.backupSuffixes.contains(where: name.hasSuffix) ? .backup(url) : nil
    }
}

private extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}

private struct ActivityList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity")
                .font(.headline)

            RowGroup {
                ForEach(model.activities) { activity in
                    HStack(spacing: 12) {
                        Text(activity.title)
                            .lineLimit(1)
                        Spacer()
                        ProgressView(value: activity.progress)
                            .frame(width: 160)
                        Text(activity.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        Button("Cancel") {
                            if let id = activity.taskID {
                                model.stopTask(id)
                            }
                        }
                        .controlSize(.small)
                        .disabled(activity.taskID == nil && model.isLive)
                    }
                }
            }
        }
    }
}

private struct ServiceGroup: View {
    let title: String
    let services: [ServiceVersion]

    var body: some View {
        if !services.isEmpty {
            RowGroup(title: title) {
                ForEach(services) { service in
                    ServiceRow(service: service)
                }
            }
        }
    }
}

private struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion

    var body: some View {
        HStack(spacing: 10) {
            if model.isStarting(service) {
                ProgressView()
                    .controlSize(.mini)
            } else {
                StatusDot(health: service.health)
            }

            Text(service.name)
                .lineLimit(1)
            Spacer()

            if model.isStarting(service) {
                Text("Starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let problem = service.problem {
                Text(problem.summary)
                    .font(.callout)
                    .foregroundStyle(Color.orangeText)
                    .help(ErrorDetails.split(problem.detail).text)
            }

            Text(service.portSummary)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ServiceSwitch(service: service)
                .controlSize(.mini)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .onTapGesture {
            model.show(service)
        }
    }
}
