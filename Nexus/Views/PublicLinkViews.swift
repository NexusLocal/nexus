import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// A line with linked words, as in the design. Nexus shows no logo of Cloudflare.
struct LinkedLine: View {
    let text: String
    let words: String
    let url: URL

    // The terms line of Settings > Sharing and of the confirm sheet (owner, 2026-11-17).
    static let terms = LinkedLine(text: ShareText.terms, words: "terms of Cloudflare", url: ShareText.termsURL)

    // The line about the key of Nexus at Cloudflare (ux-texts.md, "Own domain").
    static let removeKey = LinkedLine(text: ShareText.OwnDomain.removeKey, words: ShareText.OwnDomain.removeKeyLink, url: ShareText.OwnDomain.apiTokensURL)

    var body: some View {
        Text(line)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var line: AttributedString {
        var line = AttributedString(text)

        if let range = line.range(of: words) {
            line[range].link = url
            line[range].foregroundColor = Color.accentText
        }

        return line
    }
}

// The bar at the top of the Site screen while a link of the site or of one of its workspaces is
// open (ux-texts.md, "While the link is open"). The design is "Site · Public link" in nexus.pen.
// A form gives an empty section its own space. So the bar is the footer of an empty section, as
// SiteUseNexusSection.
struct PublicLinkBar: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    var body: some View {
        let links = model.activeLinks(of: site).filter { $0.state == .open }

        if !links.isEmpty {
            Section {
            } footer: {
                VStack(spacing: 8) {
                    ForEach(links, id: \.host) { link in
                        NoticeBanner(systemImage: PublicLinkMark.systemImage, color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: ShareText.publicUntil(link.host, endsAt: link.endsAt)) {
                            PublicAddressLink(link: link, showsScheme: true)
                        } actions: {
                            Button("Copy") {
                                copyToPasteboard(link.url ?? "")
                            }

                            Button("Stop") {
                                model.stopShare(host: link.host)
                            }
                        }
                    }
                }
            }
        }
    }
}

// The globe mark of a site row and a workspace row while a link is active (design "Public Link
// Marks · Sidebar and Workspaces"). The help names each link. The design uses a globe with land.
// The sites keep the plain globe of the sidebar.
struct PublicLinkMark: View {
    static let systemImage = "globe.europe.africa"

    let links: [ShareInfo]

    var body: some View {
        if !links.isEmpty {
            Image(systemName: Self.systemImage)
                .imageScale(.small)
                .foregroundStyle(Color.accentText)
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private var help: String {
        links.map { link in
            link.state == .open ? ShareText.publicUntil(link.host, endsAt: link.endsAt) : ShareText.opening(link.host)
        }
        .joined(separator: "\n")
    }
}

// The public address as a link that opens in the browser. A link that starts has no address yet.
// The label never holds the address, because the tracker writes the label to activity.log.
struct PublicAddressLink: View {
    let link: ShareInfo
    var showsScheme = false

    var body: some View {
        if let text = link.url, let url = URL(string: text) {
            Link(showsScheme ? text : url.host() ?? text, destination: url)
                .foregroundStyle(Color.accentText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
                .accessibilityLabel("Public link of \(link.host)")
        } else {
            Text(ShareText.opensNow)
                .foregroundStyle(.secondary)
        }
    }
}

// The section "Public links" of the menu bar panel (owner, 2026-11-17). The design is "Menu Bar
// Panel · Public link" with its versions "Row menu" and "Many public links". It lists at most 5
// links. More links give one row with their count. A failure shows in the panel.
struct MenuBarPublicLinks: View {
    static let maximumRows = 5

    @Environment(AppModel.self) private var model
    let showAll: () -> Void

    var body: some View {
        let links = model.activePublicLinks

        VStack(alignment: .leading, spacing: 6) {
            Text("Public links")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            RowGroup {
                if links.count > Self.maximumRows {
                    HStack(spacing: 8) {
                        Image(systemName: PublicLinkMark.systemImage)
                            .foregroundStyle(Color.accentText)
                        Text(ShareText.openLinks(links.count))
                        Spacer()
                    }
                } else {
                    ForEach(links, id: \.host) { link in
                        row(link)
                    }
                }
            }

            HStack {
                Spacer()

                if links.count > Self.maximumRows {
                    Button("Show All", action: showAll)
                }

                Button("Stop all") {
                    model.stopAllShares(from: .menuBar)
                }
            }
            .controlSize(.small)
        }
    }

    private func row(_ link: ShareInfo) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(link.host)
                        .lineLimit(1)
                    Spacer()
                    Text(ShareText.until(link.endsAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PublicAddressLink(link: link)
                    .font(.caption)
            }

            Button("Stop") {
                model.stopShare(host: link.host, from: .menuBar)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .contextMenu {
            Button("Copy Link") {
                copyToPasteboard(link.url ?? "")
            }
            .disabled(link.url == nil)

            Button("Stop") {
                model.stopShare(host: link.host, from: .menuBar)
            }
        }
    }
}

// The section "Public links" of the Overview below Activity (owner, 2026-11-17). The design is
// "Overview · Public links". "Stop all" sits on the line of the title.
struct OverviewPublicLinks: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Public links")
                    .font(.headline)

                Spacer()

                Button("Stop all") {
                    model.stopAllShares()
                }
                .controlSize(.small)
            }

            RowGroup {
                ForEach(model.activePublicLinks, id: \.host) { link in
                    HStack(spacing: 12) {
                        Image(systemName: PublicLinkMark.systemImage)
                            .foregroundStyle(Color.accentText)

                        Text(link.host)
                            .lineLimit(1)
                            .frame(minWidth: 160, alignment: .leading)

                        PublicAddressLink(link: link)
                            .font(.callout)

                        Spacer()

                        Text(ShareText.until(link.endsAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button("Copy") {
                            copyToPasteboard(link.url ?? "")
                        }
                        .controlSize(.small)
                        .disabled(link.url == nil)

                        Button("Stop") {
                            model.stopShare(host: link.host)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

extension NSImage {
    // The menu bar icon with a globe next to it while a link is active (design "Menu Bar Panel ·
    // Public link"). The image stays a template. So macOS gives it the color of the menu bar.
    // AppKit can call the drawing block on any thread (NSImage.h). So the block gets only values
    // and makes the two images itself.
    static let menuBarIconWithGlobe: NSImage = {
        let symbolName = PublicLinkMark.systemImage
        let iconSize = NSImage(named: "MenuBarIcon")?.size ?? NSSize(width: 16, height: 16)
        let globeSize = NSImage.globeImage(symbolName)?.size ?? NSSize(width: 13, height: 13)
        let gap: CGFloat = 4
        let size = NSSize(width: iconSize.width + gap + globeSize.width, height: max(iconSize.height, globeSize.height))

        let image = NSImage(size: size, flipped: false) { @Sendable _ in
            let icon = NSImage(named: "MenuBarIcon")
            let globe = NSImage.globeImage(symbolName)

            icon?.draw(in: NSRect(x: 0, y: (size.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            globe?.draw(in: NSRect(x: iconSize.width + gap, y: (size.height - globeSize.height) / 2, width: globeSize.width, height: globeSize.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = NexusVariant.current.name
        return image
    }()

    private nonisolated static func globeImage(_ symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }
}
