import AppKit
import NexusCore
import NexusCrashReports
import SwiftUI

// A message of nexusd that names an entry in errors.log (owner, 2026-11-07). The design is "Sheet
// Error Details", "Alert Action Failed" and the third state of "Site Mail Section · WordPress".
struct ErrorReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let place: ActionPlace

    var text: String {
        ErrorDetails.split(message).text
    }

    var entryID: String? {
        ErrorDetails.split(message).id
    }

    // A message names its subject in its first sentence, for example "Nexus cannot read the mail
    // settings of this site".
    init(message: String, title: String? = nil, place: ActionPlace) {
        let text = ErrorDetails.split(message).text
        self.title = title ?? text.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? text
        self.message = message
        self.place = place
    }
}

// The text of a message without its reference. A reference gives the button "Details…".
// In a sheet, showDetails shows the details on top of that sheet, because a window shows one sheet.
struct MessageText: View {
    @Environment(AppModel.self) private var model
    let message: String
    var title: String?
    var color: Color = .orangeText
    var place: ActionPlace = .window
    var showDetails: ((ErrorReport) -> Void)?

    init(_ message: String, title: String? = nil, color: Color = .orangeText, place: ActionPlace = .window, showDetails: ((ErrorReport) -> Void)? = nil) {
        self.message = message
        self.title = title
        self.color = color
        self.place = place
        self.showDetails = showDetails
    }

    var body: some View {
        let parts = ErrorDetails.split(message)

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(parts.text)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if parts.id != nil {
                Button("Details…") {
                    let report = ErrorReport(message: message, title: title, place: place)

                    if let showDetails {
                        showDetails(report)
                    } else {
                        model.errorReport = report
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

// The red failure line of a sheet. The details show on top of that sheet.
struct FailureLabel: View {
    let message: String
    let showDetails: (ErrorReport) -> Void

    var body: some View {
        Label {
            MessageText(message, color: .redText, showDetails: showDetails)
        } icon: {
            Image(systemName: "xmark.circle")
                .foregroundStyle(Color.redText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// The buttons of a failure alert. "Details…" shows only for a message with an entry in errors.log.
// The window that shows the alert shows the details too. The main window also shows the failures
// of the background and of a closed first run.
struct FailureAlertButtons: View {
    @Environment(AppModel.self) private var model
    let failure: ActionFailure
    let place: ActionPlace

    var body: some View {
        Button("OK") {}

        if ErrorDetails.split(failure.message).id != nil {
            Button("Details…") {
                model.errorReport = ErrorReport(message: failure.message, title: failure.title, place: place)
            }
        }
    }
}

extension View {
    // Each window shows the details of its own messages.
    func errorDetailsSheet(model: AppModel, place: ActionPlace) -> some View {
        sheet(item: Binding(get: { model.errorReport?.place == place ? model.errorReport : nil }, set: { model.errorReport = $0 })) { report in
            ErrorDetailsSheet(report: report)
        }
    }
}

struct ErrorDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: ErrorReport
    @State private var entry: ErrorDetails.Entry?
    @State private var additional = ""
    @State private var sending = false
    @State private var sent = false
    @State private var sendProblem: String?

    private var output: String {
        entry.map { "\($0.header)\n\($0.output)" } ?? "Nexus has no details of this error. The entry in errors.log can be gone already."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title)
                .font(.headline)

            Text(report.text)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 190)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            TextField("Additional information (optional)", text: $additional, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .disabled(sent)

            Text("Nexus keeps the full output in logs/errors.log, next to the activity log. \"Send report\" sends this output, the additional information, the last 25 lines of the activity log and the versions of Nexus and macOS to the developers of Nexus through Sentry. Nexus hides passwords and the name of your home folder. Sentry stores no IP address and no location.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let sendProblem {
                Text(sendProblem)
                    .foregroundStyle(Color.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(report.title)\n\(report.text)\n\n\(output)", forType: .string)
                }

                Button("Show log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([NexusPaths.standard.errorLog])
                }

                Spacer()

                Button(sent ? "Report sent" : sending ? "Sending…" : "Send report") {
                    send()
                }
                .disabled(sending || sent)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            if let id = report.entryID {
                entry = ErrorDetails.entry(id, in: NexusPaths.standard.errorLog)
            }
        }
    }

    private func send() {
        sending = true
        sendProblem = nil

        Task {
            do {
                try await ErrorReporter.send(title: report.title, message: report.text, output: output, additional: additional, place: "\(report.place)")
                sent = true
                ActivityTracker.log.write("report", "Sent a report: \(report.title)")
            } catch {
                sendProblem = "Nexus could not send the report. \(error.localizedDescription) Use \"Copy\" and make an issue on github.com/NexusLocal/nexus."
            }

            sending = false
        }
    }
}

// Sends one report to Sentry, only after a click on "Send report" (owner, 2026-11-07). The SDK of
// Sentry sends only crashes (CrashReports), so a failed program goes only through this report.
enum ErrorReporter {
    static let dsn = CrashReports.dsn
    static let activityLines = 25

    struct SendError: LocalizedError {
        let errorDescription: String?
    }

    static func send(title: String, message: String, output: String, additional: String, place: String) async throws {
        guard let components = URLComponents(string: dsn), let key = components.user, let host = components.host, let project = components.path.split(separator: "/").last,
              let endpoint = URL(string: "https://\(host)/api/\(project)/envelope/") else {
            throw SendError(errorDescription: "The address of the reports is not valid.")
        }

        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let now = Date.now.formatted(.iso8601)
        let version = NexusVersion.current()
        let build = NexusVersion.build()
        let additionalText = privateText(additional.trimmingCharacters(in: .whitespacesAndNewlines))
        var extra: [String: String] = ["place": place]

        if !additionalText.isEmpty {
            extra["additional_information"] = additionalText
        }

        let event: [String: Any] = [
            "event_id": eventID,
            "timestamp": now,
            "platform": "other",
            "level": "error",
            "logger": "nexus.report",
            "release": "nexus@\(version)+\(build)",
            // The documented way to ask Sentry not to infer the IP address. Sentry still derives a
            // location from the connection. Only "Prevent Storing of IP Addresses" in the
            // organization nexuslocal stops that.
            "sdk": ["name": "nexus.app", "version": version, "settings": ["infer_ip": "never"]],
            "environment": isDebugBuild ? "development" : "production",
            "logentry": ["formatted": privateText("\(title): \(message)")],
            "tags": ["nexus.version": version, "nexus.build": build, "has_additional_information": additionalText.isEmpty ? "no" : "yes"],
            "contexts": [
                "os": ["name": "macOS", "version": ProcessInfo.processInfo.operatingSystemVersionString],
                "app": ["app_name": "Nexus", "app_version": version, "app_build": build],
            ],
            "extra": extra,
        ]

        var body = Data()
        body.append(try JSONSerialization.data(withJSONObject: ["event_id": eventID, "sent_at": now, "dsn": dsn]))
        body.append(Data("\n".utf8))
        appendItem(try JSONSerialization.data(withJSONObject: event), header: ["type": "event", "content_type": "application/json"], to: &body)
        appendItem(Data(privateText(output).utf8), header: ["type": "attachment", "filename": "output.txt", "content_type": "text/plain"], to: &body)
        appendItem(Data(privateText(activityTail()).utf8), header: ["type": "attachment", "filename": "activity.txt", "content_type": "text/plain"], to: &body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue("Sentry sentry_version=7, sentry_key=\(key), sentry_client=nexus-app/\(version)", forHTTPHeaderField: "X-Sentry-Auth")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw SendError(errorDescription: "Sentry did not accept the report.")
        }
    }

    private static func appendItem(_ payload: Data, header: [String: String], to body: inout Data) {
        var itemHeader: [String: Any] = header
        itemHeader["length"] = payload.count

        if let headerData = try? JSONSerialization.data(withJSONObject: itemHeader) {
            body.append(headerData)
            body.append(Data("\n".utf8))
            body.append(payload)
            body.append(Data("\n".utf8))
        }
    }

    // The activity log holds no typed text or values. Its last lines show what the user did before
    // the error.
    static func activityTail() -> String {
        let file = NexusPaths.standard.activityLog
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(activityLines).joined(separator: "\n")
    }

    // Passwords and the path of the home folder stay on this Mac.
    static func privateText(_ text: String) -> String {
        ActivityLog.withoutSecrets(text).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
