import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    private var services: [ServiceVersion] {
        model.services.filter { $0.kind != .dns && ($0.isRunning || $0.problem != nil) }
    }

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

                RowGroup {
                    ForEach(services) { service in
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
