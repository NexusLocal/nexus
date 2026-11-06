import NexusCore
import NexusIPC
import SwiftUI

// Settings > Mail (Phase 3, 3b and 3d). nexusd keeps the limits of the outbox and the size of the
// inbox. The notification for each new mail is a setting of the app. Each limit has a range and no
// limit can be off, so the outbox and the inbox cannot fill the disk.
struct MailSettingsTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreference.notifyNewMail) private var notifyNewMail = false
    @State private var settings = MailSettings()

    private func setting<Value>(_ path: WritableKeyPath<MailSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: path] },
            set: { value in
                settings[keyPath: path] = value
                save()
            }
        )
    }

    // The field shows megabytes. nexusd keeps bytes.
    private var outboxMegabytes: Binding<Int> {
        Binding(
            get: { settings.outboxBytes / MailSettings.megabyte },
            set: { value in
                settings.outboxBytes = value * MailSettings.megabyte
                save()
            }
        )
    }

    // A value outside its range comes back as an alert. The fields then show the settings of nexusd
    // again.
    private func save() {
        guard model.isLive else {
            return
        }

        model.send(.setMailSettings(settings), failure: "The settings of the mail service did not change", place: .settings) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        if case .mailStatus(let status) = await model.perform(.mailStatus, failure: "Nexus cannot read the settings of the mail service", place: .settings) {
            settings = status.settings
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("When the outbox is full", selection: setting(\.whenFull)) {
                    Text("Remove the oldest mail").tag(MailSettings.WhenFull.removeOldest)
                    Text("Refuse new mail").tag(MailSettings.WhenFull.refuseNew)
                }

                NumberRow(title: "Keep at most", value: setting(\.outboxMails), unit: "mails")
                NumberRow(title: "Use at most", value: outboxMegabytes, unit: "MB")
                NumberRow(title: "Keep a mail for at most", value: setting(\.outboxDays), unit: "days")
            } header: {
                Text("Outbox")
            } footer: {
                Text("The outbox keeps each mail while Mailpit does not run. No limit can be off. So the outbox cannot fill the disk. The ranges are 10 to 10000 mails, 10 MB to 2 GB and 1 to 90 days. \"Refuse new mail\" keeps the first mails of a fault, for example a loop that sends a mail for each request.")
            }

            Section {
                NumberRow(title: "Keep the newest", value: setting(\.inboxMails), unit: "mails")

                Toggle("Send a notification for each new mail", isOn: $notifyNewMail)
                    .toggleStyle(.switch)
            } header: {
                Text("Inbox")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mailpit removes the oldest mails above this number, from 100 to 50000. A change starts Mailpit again.")

                    if notifyNewMail {
                        NotificationsBlockedNote()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: notifyNewMail) {
            if notifyNewMail {
                Task { await model.requestNotificationPermission() }
            }
        }
        .task {
            await load()
        }
    }
}

// A number that nexusd gets when the user presses Return or leaves the field.
private struct NumberRow: View {
    let title: String
    @Binding var value: Int
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)

                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
    }
}
