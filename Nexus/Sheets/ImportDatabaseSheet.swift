import SwiftUI

struct ImportDatabaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var instance: String
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var user = "root"
    @State private var password = ""
    @State private var database = "3rdrisk_platform"
    @State private var name = "3rdrisk_platform"
    @State private var replace = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a database")
                .font(.headline)

            Text("Copy a database from another server into Nexus, for example from MAMP PRO. Nexus only reads the other server.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("From") {
                    field("Host", text: $host)
                    field("Port", text: $port)
                        .digitsOnly($port)
                    field("User", text: $user)

                    LabeledContent("Password") {
                        SecureField("Password", text: $password, prompt: Text("No password"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 200)
                    }

                    Picker("Database", selection: $database) {
                        Text("3rdrisk_platform").tag("3rdrisk_platform")
                        Text("shop").tag("shop")
                        Text("crm").tag("crm")
                    }
                }

                Section("Into") {
                    Picker("Instance", selection: $instance) {
                        ForEach(model.databaseInstances) { Text($0.name).tag($0.id) }
                    }

                    field("Name", text: $name)

                    Toggle("Replace the database when it exists", isOn: $replace)
                        .toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            if importing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Copying 1.2 GB of 2.8 GB")
                        Spacer()
                        Text("About 2 minutes left")
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: 0.43)

                    Text("Table audit_logs (14 of 63). You can close this sheet. The import goes on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()

                if importing {
                    Button("Stop import") {
                        importing = false
                    }

                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Import") {
                        importing = true
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // All fields of this form have the same width and start on the left (UX rules).
    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .font(.system(.body, design: .monospaced))
                .frame(width: 200)
        }
    }
}
