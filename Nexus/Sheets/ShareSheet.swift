import NexusCore
import NexusIPC
import SwiftUI

// The confirm sheet of a link (decision 3). The design is "Sheet Share Site" with its versions
// "Warnings" and "Vite Build" in nexus.pen. The options start with the defaults of Settings >
// Sharing. A change here applies to this link only (owner, 2026-11-17). A site with an old Vite
// version gets Build. Live is off there. The row Address shows only with an own domain (4h).
struct ShareSheet: View {
    // --share-preview of a debug launch with --sample.
    static var debugPreview: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let host: String

    // SwiftUI has a type SharePreview too. So the name has its module.
    @State private var preview: NexusIPC.SharePreview?
    @State private var problem: String?
    @State private var options = ShareOptions.standard
    @State private var label = ""
    @State private var editsLabel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share \(host)?")
                .font(.headline)

            Text(ShareText.warning)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let preview {
                if let refusal = preview.refusal {
                    MessageText(refusal)
                }

                warnings(preview)
                optionsForm(preview)
                notes(preview)
            } else if let problem {
                MessageText(problem)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            HStack {
                Button("Change the defaults in Settings > Sharing.") {
                    UserDefaults.standard.set(SettingsTab.sharing.rawValue, forKey: SettingsWindow.tabKey)
                    openSettings()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Share") {
                    share()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || preview?.refusal != nil || labelProblem != nil)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await load()
        }
    }

    // The warnings of the design "Sheet Share Site · Warnings", in the order of nexusd.
    @ViewBuilder
    private func warnings(_ preview: NexusIPC.SharePreview) -> some View {
        let shown = preview.warnings.filter { warning in warning.applies(to: options) }

        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.self) { warning in
                    Label {
                        Text(warning.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.statusOrange)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.warningBackground, in: .rect(cornerRadius: 8))
        }
    }

    // The rows in the order of ux-texts.md. The help of the rows without a line in the design is a
    // tooltip.
    private func optionsForm(_ preview: NexusIPC.SharePreview) -> some View {
        Form {
            Section {
                Picker("The link ends", selection: $options.duration) {
                    ForEach(ShareDuration.allCases, id: \.self) { duration in
                        Text(duration.title).tag(duration)
                    }
                }

                if let domain = preview.ownDomain {
                    addressRows(domain)
                }

                Toggle("Ask visitors for a password", isOn: $options.password)
                    .help(SharingHelp.password)

                Toggle("Hide error details and debug tools", isOn: $options.hidesErrors)
                    .help(SharingHelp.hidesErrors)

                if preview.usesVite {
                    Picker(selection: viteMode(preview)) {
                        ForEach(ShareViteMode.allCases, id: \.self) { mode in
                            Text(mode.title)
                                .tag(mode)
                                .selectionDisabled(mode == .live && preview.liveBlocked != nil)
                        }
                    } label: {
                        Text("Styles and scripts")
                        viteHelp(preview)
                    }
                }

                Toggle("Keep a list of the requests", isOn: $options.keepsRequests)
                    .help(SharingHelp.requests)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollDisabled(true)
        .padding(.horizontal, -20)
        .fixedSize(horizontal: false, vertical: true)
    }

    // The row Address of ux-texts.md: a new random address or the address on the own domain. The
    // pencil shows a field for the label with the domain after it. A label with a problem opens the
    // field, because Share is off then.
    @ViewBuilder
    private func addressRows(_ domain: String) -> some View {
        LabeledContent("Address") {
            HStack(spacing: 6) {
                Picker("Address", selection: $options.address) {
                    Text(ShareAddressKind.random.title).tag(ShareAddressKind.random)
                    Text(OwnDomainName.address(label: OwnDomainName.label(label), domain: domain)).tag(ShareAddressKind.ownDomain)
                }
                .labelsHidden()
                .fixedSize()

                if options.address == .ownDomain {
                    Button {
                        editsLabel.toggle()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(ShareText.OwnDomain.editLabel)
                    .help(ShareText.OwnDomain.editLabel)
                }
            }
        }

        if options.address == .ownDomain, editsLabel || labelProblem != nil {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Spacer()

                    TextField(ShareText.OwnDomain.editLabel, text: $label)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                    Text(".\(domain)")
                        .foregroundStyle(.secondary)
                }

                if let labelProblem {
                    MessageText(labelProblem)
                }
            }
        }
    }

    // The domain of the address, only for an address on the own domain.
    private var ownDomain: String? {
        options.address == .ownDomain ? preview?.ownDomain : nil
    }

    // The problem of the label, only for an address on the own domain.
    private var labelProblem: String? {
        guard ownDomain != nil else {
            return nil
        }

        return OwnDomainName.labelProblem(OwnDomainName.label(label))
    }

    // An old Vite version keeps Build. The design shows its reason in the row of Vite.
    private func viteMode(_ preview: NexusIPC.SharePreview) -> Binding<ShareViteMode> {
        Binding(
            get: { options.viteMode },
            set: { mode in
                if mode == .live, preview.liveBlocked != nil {
                    return
                }

                options.viteMode = mode
            }
        )
    }

    private func viteHelp(_ preview: NexusIPC.SharePreview) -> Text {
        guard let liveBlocked = preview.liveBlocked else {
            return Text(SharingHelp.vite(options.viteMode))
        }

        return Text("\(SharingHelp.vite(options.viteMode))\n\n\(Image(systemName: "info.circle")) \(liveBlocked)")
    }

    @ViewBuilder
    private func notes(_ preview: NexusIPC.SharePreview) -> some View {
        if let alsoReaches = ShareText.alsoReaches(preview.extraHosts) {
            Text(alsoReaches)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Label {
            Text(ownDomain.map(ShareText.sleepHelp(ownDomain:)) ?? ShareText.sleepHelp)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "moon")
        }
        .foregroundStyle(.secondary)

        LinkedLine.terms
            .foregroundStyle(.secondary)
    }

    // A link that opened in the meantime shows at once. An example is a link of nexus share. Its
    // options do not change (overview, IPC).
    private func load() async {
        let answer = await model.sharePreview(host: host)

        if let link = answer.preview?.openLink, link.state.isActive {
            dismiss()
            model.showLink(of: link.host)
            return
        }

        problem = answer.problem
        preview = answer.preview

        if let preview {
            options = preview.defaults
            label = preview.label ?? ""
        }
    }

    // The app sends each value of the sheet. A row that the sheet does not show sends nil. nexusd
    // then takes the default.
    private func share() {
        guard let preview else {
            return
        }

        dismiss()
        model.startShare(ShareStart(host: preview.host, duration: options.duration, password: options.password, hidesErrors: options.hidesErrors, viteMode: preview.usesVite ? options.viteMode : nil, keepsRequests: options.keepsRequests, address: preview.ownDomain == nil ? nil : options.address, label: ownDomain.map { _ in OwnDomainName.label(label) }))
    }
}
