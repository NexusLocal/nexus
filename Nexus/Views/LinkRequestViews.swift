import NexusCore
import NexusIPC
import SwiftUI

// The request and the answer of a request through a public link (group 4, 4f, frame "Dumps ·
// Public link"): the sections "Request headers", "Data" and "Answer" above the tabs of the
// entries. The detail comes from nexusd when the request opens. The values of Cookie and
// Authorization are "Hidden by Nexus" already. The status, the size and the type of the answer
// come from the list also without the detail.
struct LinkRequestData: View {
    @Environment(AppModel.self) private var model
    let request: DumpedRequest

    var body: some View {
        let detail = model.openLinkDetail

        VStack(alignment: .leading, spacing: 14) {
            if let detail {
                LinkHeaders(title: LinkRequestText.requestHeadersTitle, headers: detail.requestHeaders)
                LinkBody(detail: detail)
            }

            LinkAnswer(request: request, detail: detail)

            if detail == nil, model.openLinkDetailProblem == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }

            if let problem = model.openLinkDetailProblem {
                MessageText(problem)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkAnswer: View {
    let request: DumpedRequest
    let detail: ShareRequestDetail?

    var body: some View {
        let status = detail?.status ?? request.status
        let size = detail?.size ?? request.publicLink?.size

        VStack(alignment: .leading, spacing: 6) {
            LinkSectionTitle(text: LinkRequestText.answerTitle)

            VStack(alignment: .leading, spacing: 6) {
                if let status {
                    HeaderLine(key: LinkRequestText.statusKey, value: String(status), keyWidth: 48)
                }

                if let size {
                    HeaderLine(key: LinkRequestText.sizeKey, value: LinkRequestText.size(size), keyWidth: 48)
                }

                if let type = request.publicLink?.contentType {
                    HeaderLine(key: LinkRequestText.typeKey, value: type, keyWidth: 48, truncation: .middle)
                }
            }

            if let headers = detail?.responseHeaders, !headers.isEmpty {
                LinkHeaderLines(headers: headers)
            }
        }
    }
}

private struct LinkSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct LinkHeaders: View {
    let title: String
    let headers: [ShareHeader]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkSectionTitle(text: title)
            LinkHeaderLines(headers: headers)
        }
    }
}

private struct LinkHeaderLines: View {
    let headers: [ShareHeader]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                Text("\(Text(verbatim: "\(header.name): ").foregroundStyle(.secondary))\(Text(verbatim: header.value))")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .entryBox()
    }
}

// The copy gives the body as nexusd sent it, without the indents.
private struct LinkBody: View {
    let detail: ShareRequestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LinkSectionTitle(text: LinkRequestText.dataTitle)
                Spacer(minLength: 8)

                if let text = detail.requestBody, !text.isEmpty {
                    CopyButton(help: LinkRequestText.copyHelp) {
                        text
                    }
                }
            }

            if let text = detail.requestBody, !text.isEmpty {
                Text(verbatim: LinkRequestText.shownBody(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .entryBox()
            }

            if let note = LinkRequestText.bodyNote(body: detail.requestBody, bytes: detail.requestBodyBytes, cut: detail.requestBodyCut) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// The tag in the head of a request through a public link, as in the design "Dumps · Public link".
struct LinkRequestTag: View {
    let host: String

    var body: some View {
        SiteTag(text: LinkRequestText.filterLabel(host: host, linkCount: 1), systemImage: "globe")
            .help(LinkRequestText.markHelp(host: host))
    }
}
