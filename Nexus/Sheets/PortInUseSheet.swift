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

            Text("\(service.name) cannot start. This program uses port \(String(holder.port)):")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 2) {
                Text(verbatim: "\(holder.app) · \(holder.process) · process \(holder.processNumber)")
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

                Button("Quit \(holder.app)") {
                    dismiss()
                    model.quit(holder, andStart: service)
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

private struct FullWidthButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}
