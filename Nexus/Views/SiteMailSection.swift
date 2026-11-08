import NexusCore
import NexusIPC
import SwiftUI

// Where the main checkout of a site sends its mail (Phase 3, 3c). Nexus changes the .env of a main
// checkout only after "Send mail to Nexus…" or "Use the old mail settings…" (D44). Both ask
// first. A workspace always sends to Nexus.
struct SiteMailSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem
    @State private var mail: SiteMail?
    @State private var checked = false
    @State private var changing = false
    @State private var asksToSend = false
    @State private var asksToRestore = false
    @State private var asksToTurnOff = false

    // The design of a WordPress site is "Site Mail Section · WordPress" in nexus.pen (Phase 4, 3h).
    private var pluginsToTurnOff: [WordPressMailPlugin] {
        mail?.mailPlugins.filter(\.canTurnOff) ?? []
    }

    private var pluginNames: String {
        EnglishList.joined(pluginsToTurnOff.map(\.name))
    }

    // A theme or a file that also sends mail stays on after the click.
    private var turnOffText: String {
        let rest = (mail?.mailPlugins ?? []).filter { !$0.canTurnOff }
        let after = rest.isEmpty
            ? " WordPress then gives each mail to PHP. Nexus catches it there."
            : " \(EnglishList.joined(rest.map(\.description)).prefix(1).uppercased())\(EnglishList.joined(rest.map(\.description)).dropFirst()) can still send mail itself."

        return "WP-CLI turns off the \(pluginsToTurnOff.count == 1 ? "plugin" : "plugins") in this copy of the site.\(after) The live site does not change."
    }

    var body: some View {
        Section {
            LabeledContent("Sends mail to") {
                HStack {
                    if mail?.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusOrange)
                    } else if mail?.sendsToNexus == true {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.statusGreen)
                    }

                    Text(summary)
                        .foregroundStyle(mail?.warning == nil ? Color.secondary : Color.orangeText)
                        .fixedSize()

                    if mail?.canSendToNexus == true {
                        Button("Send mail to Nexus…") {
                            asksToSend = true
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(changing)
                    }

                    if mail?.canRestore == true {
                        Button("Use the old mail settings…") {
                            asksToRestore = true
                        }
                        .fixedSize()
                        .disabled(changing)
                    }

                    if !pluginsToTurnOff.isEmpty {
                        Button("Turn off \(pluginNames)…") {
                            asksToTurnOff = true
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(changing)
                    }
                }
            }
        } header: {
            HStack {
                Text("Mail")
                Spacer()
                Button("Show mails") {
                    model.showMails(of: site.host)
                }
            }
        } footer: {
            if let warning = mail?.warning {
                MessageText(warning, title: "The mail of \(site.host)")
            } else if let problem = mail?.problem {
                MessageText("Nexus cannot read the mail settings of this site. \(problem)", title: "Nexus cannot read the mail settings of \(site.host)")
            } else {
                Text(footer)
            }
        }
        .task(id: "\(site.host) \(site.php) \(site.kind.rawValue) \(model.wordPressChanges)") {
            await load()
        }
        .sheet(isPresented: $asksToSend) {
            SendMailToNexusSheet(host: site.host, changes: mail?.changes ?? []) {
                change { await model.sendMailToNexus(site) }
            }
        }
        .alert("Use the old mail settings of \(site.host)?", isPresented: $asksToRestore) {
            Button("Use the old settings") {
                change { await model.restoreMailSettings(site) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nexus puts back the old values from the comment lines in the .env. It removes the keys that it added. The mail of this site then goes where it went before Nexus.")
        }
        .alert("Turn off \(pluginNames) in this copy of \(site.host)?", isPresented: $asksToTurnOff) {
            Button("Turn off") {
                let folders = pluginsToTurnOff.map(\.folder)
                change { await model.turnOffMailPlugins(site, folders: folders) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(turnOffText)
        }
    }

    private var summary: String {
        guard checked else {
            return "Checking…"
        }

        guard let mail, mail.problem == nil else {
            return "Unknown"
        }

        if mail.sendsToNexus {
            return "The inbox of Nexus (Mailpit)"
        }

        if let destination = mail.destination {
            return destination
        }

        return site.kind == .node ? "No SMTP keys in the env files" : "Not the inbox of Nexus"
    }

    // A workspace of a WordPress site runs no PHP until it is isolated (Phase 4, 3e). So it sends no
    // mail yet.
    private var footer: String {
        if site.isWordPress {
            return "WordPress gives each mail to PHP. PHP gives it to Nexus. Each mail gets the tag \(site.host) in the inbox."
        }

        let oldSettings = mail?.canRestore == true ? " The .env keeps the old mail settings as comment lines." : ""
        return "Each mail of this site gets the tag \(site.host) in the inbox.\(oldSettings) A workspace of this site always sends its mail to Nexus, with the host of the workspace as its tag."
    }

    private func load() async {
        mail = await model.siteMail(of: site)
        checked = true
    }

    private func change(_ action: @escaping () async -> Bool) {
        changing = true

        Task {
            if await action() {
                await load()
            }

            changing = false
        }
    }
}
