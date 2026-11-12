import AppKit
import NexusCore
import SwiftUI

// The standard About panel of macOS cannot show the licenses in the layout of the frames "About
// Nexus" and "About Nexus · Licenses" in nexus.pen.
struct AboutWindow: View {
    static let id = "about"

    private static let notices = bundledNotices()

    var body: some View {
        VStack(spacing: 0) {
            AboutHeader()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SoftwareSection(projects: Self.notices.projects)
                    LicensesSection(sections: Self.notices.sections)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }

            Divider()

            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .frame(width: 480, height: 640)
    }

    // The build phase "Copy the third-party notices" fails without the file.
    private static func bundledNotices() -> ThirdPartyNotices {
        let file = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md")
        let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return ThirdPartyNotices(markdown: text)
    }
}

private struct AboutHeader: View {
    private var version: String {
        "Version \(NexusVersion.current()) (\(NexusVersion.build()))"
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text(NexusVariant.current.name)
                .font(.title3.weight(.semibold))

            Text(version)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SoftwareSection: View {
    let projects: [ThirdPartyNotices.Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Software in Nexus")
                .font(.headline)

            RowGroup {
                ForEach(projects) { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text("\(project.version) · \(project.license) · \(project.use)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }

            Text("Nexus downloads the services of your sites, such as PHP and MySQL, from NexusLocal/binaries. These programs are not part of the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LicensesSection: View {
    let sections: [ThirdPartyNotices.Section]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Licenses")
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.name)

                        ForEach(section.blocks.indices, id: \.self) { index in
                            LicenseBlock(block: section.blocks[index])
                        }
                    }
                }
            }
        }
    }
}

private struct LicenseBlock: View {
    let block: ThirdPartyNotices.Block

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Self.markdown(text))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        case .text(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(NexusVariant.current.name)") {
            openWindow(id: AboutWindow.id)
        }
    }
}
