import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model
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

            if let problem = model.problemService, model.portHolder != nil {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusOrange)
                    Text("\(problem.name): port \(problem.shortPortSummary) is in use")
                        .lineLimit(1)
                    Spacer()
                    Button("Fix…") {
                        open()
                        model.sheet = .portInUse(service: problem.id)
                    }
                }
                .padding(10)
                .background(Color.warningBackground, in: .rect(cornerRadius: 8))
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
                                Toggle(service.name, isOn: Binding(
                                    get: { service.isRunning },
                                    set: { model.setRunning($0, service: service.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
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
