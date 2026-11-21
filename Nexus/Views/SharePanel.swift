import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import NexusCore
import NexusIPC
import SwiftUI

// The Share button in the toolbar of the Site screen (design "Share Button States" in nexus.pen).
// Without a link it opens the confirm sheet (decision 3). It opens its panel for a link that
// starts or is open. It also opens its panel after a start that failed. The icon of each state
// comes from the design.
struct ShareButton: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    private var showsPanel: Binding<Bool> {
        Binding(
            get: { model.sharePanelHost == site.host },
            set: { shown in
                model.sharePanelHost = shown ? site.host : nil
            }
        )
    }

    var body: some View {
        let state = model.linkState(of: site.host)

        Button {
            if state == .none {
                model.askToShare(host: site.host)
            } else {
                model.sharePanelHost = site.host
            }
        } label: {
            label(of: state)
        }
        .labelStyle(.titleAndIcon)
        .popover(isPresented: showsPanel, arrowEdge: .bottom) {
            SharePanel(host: site.host)
                .environment(model)
        }
    }

    @ViewBuilder
    private func label(of state: PublicLinkState) -> some View {
        switch state {
        case .none:
            Label(ShareText.shareButton, systemImage: PublicLinkMark.systemImage)
        case .starting:
            Label {
                Text(ShareText.linkOpensButton)
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
        case .open:
            Label {
                Text(ShareText.publicButton)
            } icon: {
                Image(systemName: PublicLinkMark.systemImage)
                    .foregroundStyle(Color.accentText)
            }
        case .failed:
            Label {
                Text(ShareText.shareButton)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.statusOrange)
            }
        }
    }
}

// The panel of the Share button. It shows the steps of the start, the open link or the reason of
// a start that failed. It closes when the host has no link anymore.
struct SharePanel: View {
    private static let steps: [ShareStep] = [.downloadCloudflared, .buildAssets, .openLink]

    @Environment(AppModel.self) private var model
    let host: String

    @State private var firstStep: ShareStep?
    @State private var showsWhy = false

    var body: some View {
        let state = model.linkState(of: host)

        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .none:
                EmptyView()
            case .starting(let step):
                starting(step)
            case .open(let link):
                open(link)
            case .failed(let reason):
                failed(reason)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onChange(of: state == .none, initial: true) {
            if model.linkState(of: host) == .none {
                model.sharePanelHost = nil
            }
        }
        .onChange(of: currentStep, initial: true) {
            if firstStep == nil {
                firstStep = currentStep
            }
        }
    }

    private var currentStep: ShareStep? {
        if case .starting(let step) = model.linkState(of: host) {
            return step
        }

        return nil
    }

    // The steps from the first step that the panel saw. The build shows only for a link with Build
    // of a site with Vite (4e).
    @ViewBuilder
    private func starting(_ step: ShareStep?) -> some View {
        Text(ShareText.opening(host))
            .fixedSize(horizontal: false, vertical: true)

        if let step, let start = Self.steps.firstIndex(of: firstStep ?? step), let current = Self.steps.firstIndex(of: step) {
            let builds = model.publicLink(host: host)?.buildsAssets == true
            let shown = Self.steps.indices.filter { $0 >= start && (Self.steps[$0] != .buildAssets || builds) }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown, id: \.self) { index in
                    HStack(spacing: 8) {
                        TaskStepIcon(state: index < current ? .done : index == current ? .running : .waiting)
                            .frame(width: 16)

                        Text(ShareText.stepTitle(Self.steps[index]))
                            .foregroundStyle(index > current ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        HStack {
            Spacer()

            Button("Stop") {
                model.stopShare(host: host)
            }
        }
    }

    @ViewBuilder
    private func open(_ link: ShareInfo) -> some View {
        let url = link.url ?? ""

        VStack(alignment: .leading, spacing: 8) {
            PublicAddressLink(link: link, showsScheme: true)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    copyToPasteboard(url)
                }

                Button("Open") {
                    model.openInBrowser(url)
                }
            }
        }

        HStack(alignment: .top, spacing: 12) {
            QRCodeImage(text: url)

            VStack(alignment: .leading, spacing: 6) {
                PanelLine(key: ShareText.endsKey) {
                    Text(ShareText.endValue(link.endsAt))
                }

                PanelLine(key: ShareText.visitorsKey) {
                    TimelineView(.everyMinute) { context in
                        Text(ShareText.visitors(link.visitors, lastVisit: link.lastVisit, now: context.date))
                    }
                }

                if link.usesVite {
                    PanelLine(key: ShareText.stylesKey) {
                        Text(link.options.viteMode.title)
                    }
                }

                if let password = link.password {
                    Text(ShareText.passwordLine(password))
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        if let liveBlocked = link.liveBlocked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Visitors get a build of the styles and scripts. Hot reload is off until the link ends.")
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Why?") {
                        showsWhy.toggle()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }

                if showsWhy {
                    Text(liveBlocked)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }

        Divider()

        HStack {
            if let count = model.requestCount(of: link) {
                Button(ShareText.requestsButton(count)) {
                    model.sharePanelHost = nil
                    model.showLinkRequests(host: link.host)
                }
            }

            if link.buildsAssets {
                let rebuilding = model.rebuildingShares.contains(link.host)

                Button {
                    model.rebuildShare(host: link.host)
                } label: {
                    HStack(spacing: 6) {
                        if rebuilding {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Text("Build Again")
                    }
                }
                .disabled(rebuilding)
            }

            Spacer()

            Button("Stop") {
                model.stopShare(host: link.host)
            }
            .foregroundStyle(Color.redText)
        }
    }

    // A start that failed (design "Share Button States"). Try Again opens the confirm sheet with the
    // defaults.
    @ViewBuilder
    private func failed(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(Color.statusRed)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(ShareText.notOpenedTitle)
                    .font(.headline)

                MessageText(reason, color: .secondary)
            }
        }

        HStack {
            Spacer()

            Button(ShareText.tryAgain) {
                model.clearShareFailure(host: host)
                model.sharePanelHost = nil
                model.askToShare(host: host)
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// A line of the share panel: a small key above its value (design "Site · Public link").
private struct PanelLine<Value: View>: View {
    let key: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            value
        }
    }
}

// The QR code of a link for a phone (ux-texts.md). CoreImage makes it. The image scales without
// interpolation. So its edges stay sharp. The white square keeps a quiet zone around the code. So
// a phone can read it in the dark look too. The size comes from the design.
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(6)
                .background(.white, in: .rect(cornerRadius: 6))
                .accessibilityLabel("QR code of the link")
        }
    }

    private static let context = CIContext()
    private static var last: (text: String, image: NSImage)?

    // The image of the last address stays. So a new draw of the panel makes no new image.
    static func image(for text: String) -> NSImage? {
        if let last, last.text == text {
            return last.image
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else {
            return nil
        }

        let made = NSImage(cgImage: image, size: output.extent.size)
        last = (text, made)
        return made
    }
}
