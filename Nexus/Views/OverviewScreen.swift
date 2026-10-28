import AppKit
import NexusCore
import SwiftUI
import UniformTypeIdentifiers

struct OverviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch model.nexusdProblem {
                case .unreachable(let problem):
                    Banner(
                        title: "Nexus cannot reach its background service",
                        message: "\(problem) Nexus tries again every few seconds. Check that Nexus is on in Login Items."
                    ) {
                        Button("Open Login Items") {
                            background.helper.openLoginItemsSettings()
                        }
                    }
                case .otherVersion(let problem):
                    Banner(title: "Nexus cannot read its background service", message: problem) {
                        Button("Start it again") {
                            model.restartNexusd(from: .window)
                        }
                    }
                case nil:
                    EmptyView()
                }

                if let approval = background.approvalNeeded {
                    Banner(title: "Nexus needs your approval", message: approval) {
                        Button("Open Login Items") {
                            background.helper.openLoginItemsSettings()
                        }
                    }
                }

                if let blocked = model.blockedService {
                    ProblemBanner(service: blocked.service, holder: blocked.holder)
                }

                DropArea()

                if !model.activities.isEmpty {
                    ActivityList()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Services")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            ServiceGroup(title: "Webservers", services: model.versions(of: .webservers))
                            ServiceGroup(title: "PHP", services: model.versions(of: .php))
                            ServiceGroup(title: "Redis and DNS", services: model.versions(of: .redis) + model.versions(of: .dns))
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
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
                }
            }
        }
    }
}

private struct ProblemBanner: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion
    let holder: PortHolder

    var body: some View {
        Banner(
            title: "\(service.name) cannot start",
            message: "Port \(holder.port) is in use by \(holder.process) of \(holder.app) (process \(holder.processNumber))."
        ) {
            Button("Quit \(holder.app)") {
                model.quit(holder, andStart: service)
            }
            Button("Change port…") {
                model.sheet = .portInUse(service: service.id, holder: holder)
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(Color.statusOrange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            actions
        }
        .padding(12)
        .background(Color.warningBackground, in: .rect(cornerRadius: 10))
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
                Text("Drop a folder of projects to park it. Each project in it becomes a site.")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Choose folder…") {
                model.sheet = .addSite
            }
        }
        .padding(16)
        .background(Color.accentSoft.opacity(targeted ? 2 : 1), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentText.opacity(targeted ? 1 : 0.6), lineWidth: 1.5)
        }
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(targeted: $targeted, pointerInside: $pointerInside) { _ in
            model.sheet = .addSite
        })
    }
}

// Accepts one folder. It refuses files and apps while the pointer is still over the area.
// The item provider is read before each await, because the drop info is not valid after the drop.
private struct FolderDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    @Binding var pointerInside: Bool
    let onFolder: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [.fileURL]).count == 1
    }

    func dropEntered(info: DropInfo) {
        pointerInside = true

        guard let provider = info.itemProviders(for: [.fileURL]).first else {
            return
        }

        Task {
            let isFolder = await folder(from: provider) != nil
            targeted = pointerInside && isFolder
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
            if let url = await folder(from: provider) {
                onFolder(url)
            }
        }

        return true
    }

    private func folder(from provider: NSItemProvider) async -> URL? {
        guard let url = try? await provider.loadFileURL() else {
            return nil
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true ? url : nil
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
                        Button("Cancel") {}
                            .controlSize(.small)
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
            StatusDot(health: service.health)
            Text(service.name)
                .lineLimit(1)
            Spacer()

            if let problem = service.problem {
                Text(problem.summary)
                    .font(.callout)
                    .foregroundStyle(Color.orangeText)
                    .help(problem.detail)
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
