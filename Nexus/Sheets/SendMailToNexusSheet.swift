import NexusCore
import NexusIPC
import SwiftUI

// "Send mail to Nexus…" asks first (Phase 3, 3c). The sheet names each key that Nexus writes into
// the .env of the main checkout, with its new value.
struct SendMailToNexusSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    let changes: [EnvKeyChange]
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send the mail of \(host) to Nexus?")
                .font(.headline)

            Text("Nexus changes these keys in the .env of the main checkout. Each mail then goes to the inbox of Nexus, with the tag \(host).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
                    ForEach(changes, id: \.key) { change in
                        EnvKeyRow(change)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            Text("The old values stay in the .env as comment lines that start with \"\(EnvFile.commentStart)\". \"Use the old mail settings…\" on the Site screen puts them back. A queue worker reads the new values after a restart.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Send mail to Nexus") {
                    dismiss()
                    send()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
