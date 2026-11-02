import AppKit
import SwiftUI

struct PortInUseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let service: ServiceVersion
    let holder: PortHolder

    @State private var newPort = 0

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            Text("Port \(String(holder.port)) is in use.")
                .font(.headline)

            Text("\(service.name) cannot start. \(holder.explanation)")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 2) {
                Text(verbatim: holder.processLine)
                    .fontWeight(.semibold)
                Text(holder.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(.fill.quaternary, in: .rect(cornerRadius: 8))

            HStack {
                Text("New port")
                PortField(port: $newPort)
            }

            VStack(spacing: 8) {
                Button("Use port \(newPort.formatted(.number.grouping(.never)))") {
                    dismiss()
                    model.start(service, movingPortOf: holder, to: newPort)
                }
                .keyboardShortcut(.defaultAction)

                PortHolderButtons(service: service, holder: holder) {
                    dismiss()
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(FullWidthButtonStyle())
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            newPort = holder.suggestedPort
        }
    }
}

// A sheet closes before the action. The window of the manager app opens on top of the sheet, so
// that action keeps the sheet open.
struct PortHolderButtons: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion
    let holder: PortHolder
    var beforeAction: () -> Void = {}

    var body: some View {
        if holder.canStop {
            Button(model.stopTitle(of: holder)) {
                beforeAction()
                model.stop(holder, andStart: service)
            }
        } else {
            if model.managerAppURL(of: holder) != nil {
                Button("Open \(holder.app)") {
                    model.openManagerApp(of: holder)
                }
            }

            Button("Try again") {
                beforeAction()
                model.setRunning(true, service: service)
            }
        }
    }
}

private struct FullWidthButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}
