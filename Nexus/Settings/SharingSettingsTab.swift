import NexusCore
import NexusIPC
import SwiftUI

// The help texts of the options of a link (ux-texts.md, "Settings > Sharing"). The confirm sheet
// shows them as the help of each row.
enum SharingHelp {
    static let password = "Visitors type the password before they see a page. Webhooks and other requests that send data do not need it."
    static let hidesErrors = "Visitors see a plain error page. They do not see your code, your settings or tools such as Telescope and Horizon. You still see each error in Nexus."
    static let live = "Visitors load the styles and scripts from Vite on your Mac. They see your newest saved change when they load the page again. Hot reload stays on for you. The first page loads more slowly for visitors."
    static let build = "Nexus runs npm run build and stops Vite while the link is open. Visitors get fast, fixed files. Hot reload is off for you until the link ends. Visitors see a new change in styles or scripts only after Build Again."
    static let requests = "The dump viewer shows each request through a link with its data and its dumps. It helps you check a webhook. The list stays on this Mac. Nexus deletes it when the link ends."
    static let olderVite = "A site with an older Vite version always uses Build. Nexus tells you why when you share it."

    static func vite(_ mode: ShareViteMode) -> String {
        mode == .live ? live : build
    }
}

// Settings > Sharing (owner, 2026-11-17). The design is "Settings Sharing" in nexus.pen. nexusd
// keeps the defaults. A change does not change a link that is open. The row Address has one
// choice until the setup of a domain.
struct SharingSettingsTab: View {
    @Environment(AppModel.self) private var model

    private func option<Value>(_ path: WritableKeyPath<ShareOptions, Value>) -> Binding<Value> {
        Binding(
            get: { model.shareDefaults[keyPath: path] },
            set: { value in
                var defaults = model.shareDefaults
                defaults[keyPath: path] = value
                model.setShareDefaults(defaults)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("The link ends", selection: option(\.duration)) {
                    ForEach(ShareDuration.allCases, id: \.self) { duration in
                        Text(duration.title).tag(duration)
                    }
                }

                Toggle(isOn: option(\.password)) {
                    Text("Ask visitors for a password")
                    Text(SharingHelp.password)
                }

                Toggle(isOn: option(\.hidesErrors)) {
                    Text("Hide error details and debug tools")
                    Text(SharingHelp.hidesErrors)
                }

                Picker(selection: option(\.viteMode)) {
                    ForEach(ShareViteMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Styles and scripts of Vite sites")
                    Text("\(SharingHelp.vite(model.shareDefaults.viteMode))\n\(SharingHelp.olderVite)")
                }

                Toggle(isOn: option(\.keepsRequests)) {
                    Text("Keep a list of the requests")
                    Text(SharingHelp.requests)
                }

                Picker("Address", selection: option(\.address)) {
                    Text(ShareAddressKind.random.title).tag(ShareAddressKind.random)

                    if model.connectedOwnDomain != nil {
                        Text(ShareAddressKind.ownDomain.title).tag(ShareAddressKind.ownDomain)
                    }
                }
            } header: {
                Text("Defaults for new links")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShareText.defaultsFooter)
                    LinkedLine.terms
                        .foregroundStyle(.secondary)
                }
            }

            OwnDomainSection()
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .settingsTabHeight()
    }
}

// Settings > Sharing, the section "Your own domain" (ux-texts.md). The design is the section of
// "Settings Sharing" in nexus.pen. The setup sheet belongs to the Settings window. removal holds the
// note after a Disconnect until the window closes.
struct OwnDomainSection: View {
    @Environment(AppModel.self) private var model
    @State private var showsSetup = false
    @State private var confirmsDisconnect = false
    @State private var removal: OwnDomainRemoval?
    @State private var disconnecting = false

    var body: some View {
        let domain = model.connectedOwnDomain

        Section {
            if let domain {
                LabeledContent(ShareText.OwnDomain.domainRow, value: domain.domain)
                LabeledContent(ShareText.OwnDomain.tunnelRow, value: domain.tunnelName ?? "")
                LabeledContent(ShareText.OwnDomain.addressesRow, value: domain.addresses.isEmpty ? ShareText.OwnDomain.noAddress : domain.addresses.joined(separator: ", "))

                HStack {
                    Spacer()

                    Button(ShareText.OwnDomain.disconnect) {
                        confirmsDisconnect = true
                    }
                    .disabled(disconnecting)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ShareText.OwnDomain.intro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let removal {
                        removalNote(removal)
                    }

                    HStack {
                        Spacer()

                        Button(ShareText.OwnDomain.setUp) {
                            removal = nil
                            showsSetup = true
                        }
                    }
                }
            }
        } header: {
            Text(ShareText.OwnDomain.title)
        }
        .sheet(isPresented: $showsSetup) {
            OwnDomainSheet()
        }
        .alert(ShareText.OwnDomain.disconnectTitle(domain?.domain ?? ""), isPresented: $confirmsDisconnect, presenting: domain) { _ in
            Button("Disconnect", role: .destructive) {
                disconnect()
            }

            Button("Cancel", role: .cancel) {}
        } message: { domain in
            Text(ShareText.OwnDomain.disconnectMessage(domain: domain.domain, tunnel: domain.tunnelName ?? "", records: domain.addresses))
        }
        .onAppear {
            if OwnDomainSheet.debugStep != nil {
                showsSetup = true
            }
        }
    }

    private func removalNote(_ removal: OwnDomainRemoval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkedLine.removeKey

            ForEach(ShareText.OwnDomain.keptLines(records: removal.keptRecords, tunnel: removal.keptTunnel), id: \.self) { line in
                Text(line)
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // A failure shows in the alert of the Settings window.
    private func disconnect() {
        disconnecting = true

        Task {
            removal = await model.disconnectOwnDomain()
            disconnecting = false
        }
    }
}
