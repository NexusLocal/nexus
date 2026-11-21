import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The setup of the own domain (group 4, 4h). The design is "Sheet Own Domain" in nexus.pen with the
// steps 1 Domain, 1 Not on Cloudflare, 2 Connect and 3 Connected. nexusd runs the login. The sheet
// shows its state from SiteList.ownDomain. The texts of ux-texts.md win over a frame (contract 4h).
struct OwnDomainSheet: View {
    enum Step: String {
        case domain
        case notOnCloudflare = "not-on-cloudflare"
        case connect
        case connected
    }

    // --own-domain-sheet of a debug launch with --sample.
    static var debugStep: Step?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.domain
    @State private var domain = ""
    @State private var problem: String?
    @State private var problemTitle: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch step {
            case .domain, .notOnCloudflare:
                domainStep
            case .connect:
                connectStep
            case .connected:
                connectedStep
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: appear)
        .onChange(of: ownState) { _, state in
            if state == .connected, step == .connect {
                step = .connected
            }
        }
    }

    // The setup or the connection of the domain of this sheet. The sheet ignores a setup of another
    // domain, for example a setup that nexus share started.
    private var ownState: OwnDomainState? {
        model.ownDomain?.state(of: domain)
    }

    private var stepNumber: Int {
        switch step {
        case .domain, .notOnCloudflare: 1
        case .connect: 2
        case .connected: 3
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: PublicLinkMark.systemImage)
                .foregroundStyle(Color.accentText)

            Text(ShareText.OwnDomain.title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(ShareText.OwnDomain.step(stepNumber))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    // MARK: Step 1

    private var domainStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ShareText.OwnDomain.whichDomain)
                .font(.headline)

            TextField("", text: $domain, prompt: Text("example.com"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(check)

            Text(ShareText.OwnDomain.domainHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if step == .notOnCloudflare {
                Label {
                    Text(ShareText.OwnDomain.notOnCloudflare(domain))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusOrange)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.warningBackground, in: .rect(cornerRadius: 8))
            }

            problemText

            HStack {
                Spacer()

                cancelButton

                if step == .notOnCloudflare {
                    Button(ShareText.OwnDomain.openCloudflare) {
                        NSWorkspace.shared.open(ShareText.OwnDomain.cloudflareURL)
                    }

                    Button(ShareText.OwnDomain.checkAgain, action: check)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || domain.isEmpty)
                } else {
                    Button(ShareText.OwnDomain.continueButton, action: check)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || domain.isEmpty)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Step 2

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ShareText.OwnDomain.connectTitle)
                .font(.headline)

            switch ownState {
            case .connecting(let page)?:
                if let page {
                    Text(ShareText.OwnDomain.waitsForCloudflare(domain))
                        .fixedSize(horizontal: false, vertical: true)

                    buttons {
                        Button(ShareText.OwnDomain.openPageAgain) {
                            if let url = URL(string: page) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)

                    buttons {}
                }
            case .failed(let text, let keyMade)?:
                MessageText(text, place: .settings)

                if keyMade {
                    LinkedLine.removeKey
                        .foregroundStyle(.secondary)
                }

                buttons {
                    Button("Try Again", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            default:
                Text(ShareText.OwnDomain.connectHelp(domain))
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text(ShareText.OwnDomain.keyNote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

                problemText

                buttons {
                    Button(ShareText.OwnDomain.openCloudflare, action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            }
        }
    }

    // MARK: Step 3

    private var connectedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(Color.statusGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ShareText.OwnDomain.connectedTitle)
                        .font(.headline)

                    Text(ShareText.OwnDomain.connectedHelp(domain))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()

                Button(ShareText.OwnDomain.done) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    // MARK: The parts

    @ViewBuilder
    private var problemText: some View {
        if let problem {
            MessageText(problem, title: problemTitle, place: .settings)
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel, action: cancel)
            .keyboardShortcut(.cancelAction)
    }

    private func buttons<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            Spacer()

            cancelButton
            trailing()
        }
        .padding(.top, 4)
    }

    // A setup that runs or that failed shows at once. A debug launch opens the step of the frame.
    private func appear() {
        if let debugStep = Self.debugStep {
            domain = "example.com"
            step = debugStep
            return
        }

        if let info = model.ownDomain, model.connectedOwnDomain == nil {
            domain = info.domain
            step = .connect
        }
    }

    // A domain without name servers stays in step 1 with text 2. No answer of 1.1.1.1 goes on to
    // step 2. The login of Cloudflare shows only the domains of the account.
    private func check() {
        guard !busy, !domain.isEmpty else {
            return
        }

        busy = true
        problem = nil
        problemTitle = nil
        let asked = domain

        Task {
            let answer = await model.checkOwnDomain(asked)
            busy = false

            let check: OwnDomainCheck

            switch answer {
            case .notADomain:
                problem = ShareText.OwnDomain.notADomain
                return
            case .failed(let message):
                problem = message
                problemTitle = ShareText.OwnDomain.checkFailedTitle(asked)
                return
            case .checked(let checked):
                check = checked
            }

            domain = check.domain

            switch check.usesCloudflare {
            case false? where check.nameservers.isEmpty:
                step = .domain
                problem = ShareText.OwnDomain.noNameservers(check.domain)
            case false?:
                step = .notOnCloudflare
            case true?, nil:
                step = .connect
            }
        }
    }

    // cloudflared opens the browser. The state of nexusd then shows the next part of step 2.
    private func connect() {
        busy = true
        problem = nil

        Task {
            let failure = await model.connectOwnDomain(domain)
            busy = false

            if let failure {
                problem = failure
            }
        }
    }

    // Only step 2 has a setup of the sheet.
    private func cancel() {
        if step == .connect, let state = ownState, state != .connected {
            model.cancelOwnDomain()
        }

        dismiss()
    }
}
