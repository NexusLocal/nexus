import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var listHeight: CGFloat = 0

    // The list shows every service. The switch of a stopped service can then start it. Above
    // eight rows the list scrolls. This keeps the panel small.
    private let maximumListHeight: CGFloat = 8 * 27

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Nexus")
                        .fontWeight(.semibold)
                    Text(model.runningSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    openSettings()
                    NSApplication.shared.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            if let problem = model.nexusdProblem {
                Notice(text: "Nexus cannot reach its background service", detail: problem) {
                    Button("Open…") {
                        background.helper.openLoginItemsSettings()
                    }
                }
            }

            if let approval = background.approvalNeeded {
                Notice(text: "Nexus needs your approval", detail: approval) {
                    Button("Open…") {
                        background.helper.openLoginItemsSettings()
                    }
                }
            }

            if let blocked = model.blockedService {
                Notice(text: "\(blocked.service.name): port \(blocked.service.shortPortSummary) is in use", detail: blocked.service.problem?.detail ?? "") {
                    Button("Fix…") {
                        open()
                        model.sheet = .portInUse(service: blocked.service.id)
                    }
                }
            }

            if let failure = model.failure, failure.place == .menuBar {
                Notice(text: failure.title, detail: failure.message, showsDetail: true) {
                    Button("Close", systemImage: "xmark") {
                        model.failure = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Services")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    RowGroup {
                        ForEach(model.services) { service in
                            HStack(spacing: 8) {
                                StatusDot(health: service.health)
                                Text(service.name)
                                Spacer()
                                Text(service.shortPortSummary)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                ServiceSwitch(service: service, place: .menuBar)
                                    .controlSize(.mini)
                            }
                            .frame(minHeight: 26)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, maximumListHeight))
                .scrollBounceBehavior(.basedOnSize)
            }

            ForEach(model.activities) { activity in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(activity.shortTitle)
                            .font(.callout)
                        Spacer()
                        Text(activity.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: activity.progress)
                }
            }

            HStack {
                Button {
                    open()
                } label: {
                    Text("Open Nexus")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.large)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func open() {
        openWindow(id: MainWindow.id)
        NSApplication.shared.activate()
    }
}

// One line in the panel. The tooltip has the full text, or the panel shows it under the line.
private struct Notice<Actions: View>: View {
    let text: String
    let detail: String
    var showsDetail = false
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: showsDetail ? .top : .center) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.statusOrange)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .lineLimit(1)

                if showsDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(detail)

            Spacer()
            actions
        }
        .padding(10)
        .background(Color.warningBackground, in: .rect(cornerRadius: 8))
    }
}
