import AppKit
import NexusCore
import NexusIPC
import NexusMail
import SwiftUI
import WebKit

// The Mail screen (Phase 3, 3d): the rows of the service, the notices of the outbox and the inbox
// of Mailpit in the design of Nexus. "Open in Mailpit" gives the other tools of Mailpit.
struct MailScreen: View {
    @Environment(AppModel.self) private var model

    // Each event of nexusd replaces the list of services, so the binding looks up the service each
    // time.
    private func binding(to service: ServiceVersion) -> Binding<ServiceVersion> {
        Binding(
            get: { model.service(service.id) ?? service },
            set: { changed in
                if let index = model.services.firstIndex(where: { $0.id == service.id }) {
                    model.services[index] = changed
                }
            }
        )
    }

    var body: some View {
        Group {
            if let service = model.mailService {
                VStack(spacing: 0) {
                    MailNotices(service: service)
                    MailForm(service: binding(to: service))
                }
            } else {
                MailNotInstalled()
            }
        }
        .screenTitle("Mail", subtitle: subtitle)
        .toolbar {
            if let service = model.mailService {
                MailToolbar(model: model, service: service)
            }
        }
        .task {
            await model.watchMail()
        }
    }

    private var subtitle: String {
        guard let service = model.mailService else {
            return "Not installed"
        }

        let name = "\(service.name) \(service.version)"

        guard service.isRunning else {
            return "\(name) · stopped"
        }

        return "\(name) · \(model.mailCount == 1 ? "1 mail" : "\(model.mailCount) mails") in the inbox"
    }
}

private struct MailToolbar: ToolbarContent {
    let model: AppModel
    let service: ServiceVersion

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.openInMailpit()
            } label: {
                Label("Open in Mailpit", systemImage: "arrow.up.forward.app")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!service.isRunning)
            .help("Mailpit has more tools, for example the HTML check of a mail.")
        }

        ToolbarItem(placement: .primaryAction) {
            MoreMenu {
                Button("Check for updates", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.checkPackages() }
                }

                if let package = model.package(of: service) {
                    Divider()

                    Button("Remove \(service.name)…", systemImage: "trash", role: .destructive) {
                        model.removal = .package(package)
                    }
                }
            }
        }
    }
}

// The notices above the form: mail that waits, mail that the limits removed, mail that Mailpit
// refused, and a port in use.
private struct MailNotices: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let service: ServiceVersion
    @State private var confirmsRemoval = false

    private var status: MailStatus? {
        model.mailStatus
    }

    var body: some View {
        let waiting = status?.waiting ?? 0
        let removed = status?.removed ?? 0
        let refused = status?.refused ?? 0
        let holder = service.problem?.portHolder

        if waiting > 0 && !service.isRunning || removed > 0 || refused > 0 || holder != nil {
            VStack(spacing: 8) {
                if let holder {
                    WarningBanner(title: "The mail service cannot start", message: holder.bannerText) {
                        PortHolderButtons(service: service, holder: holder)

                        Button("Change port…") {
                            model.sheet = .portInUse(service: service.id, holder: holder)
                        }
                    }
                }

                if waiting > 0, !service.isRunning {
                    WarningBanner(title: "\(Self.mails(waiting)) wait for the mail service", message: "Mailpit is stopped. nexusd keeps each new mail in the outbox. The inbox gets them at the next start.") {
                        Button("Remove…") {
                            confirmsRemoval = true
                        }

                        Button("Start") {
                            model.setRunning(true, service: service)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if removed > 0 {
                    WarningBanner(title: "Nexus removed \(Self.mails(removed)) from the outbox", message: "The outbox was full. So the oldest mails went. Change the limits in Settings > Mail.") {
                        Button("Mail settings…") {
                            UserDefaults.standard.set("mail", forKey: SettingsWindow.tabKey)
                            openSettings()
                        }

                        Button("OK") {
                            model.acknowledgeRemovedMails()
                        }
                    }
                }

                if refused > 0 {
                    WarningBanner(title: "Mailpit refused \(Self.mails(refused))", message: "Nexus keeps them with the reason in the folder refused, next to the outbox.") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(NexusPaths.standard.mail.appending(path: "refused", directoryHint: .isDirectory))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .confirmationDialog("Remove the waiting mails?", isPresented: $confirmsRemoval) {
                Button("Remove \(Self.mails(waiting))", role: .destructive) {
                    model.clearOutbox()
                }
            } message: {
                Text("The inbox does not get these mails. The mails that Mailpit refused go too.")
            }
        }
    }

    static func mails(_ count: Int) -> String {
        count == 1 ? "1 mail" : "\(count) mails"
    }
}

private struct MailForm: View {
    @Environment(AppModel.self) private var model
    @Binding var service: ServiceVersion
    @State private var confirmsClear = false

    var body: some View {
        Form {
            StateSection(service: $service)

            Section {
                if !service.isRunning {
                    Text("Start the mail service to read the inbox. New mail waits in the outbox until then.")
                        .foregroundStyle(.secondary)
                } else if let problem = model.mailProblem {
                    MessageText(problem)
                } else if model.mails.isEmpty {
                    Text(model.mailFilter.map { "The inbox has no mail of \($0)." } ?? "The inbox is empty. A mail of a site shows here within a second.")
                        .foregroundStyle(.secondary)
                } else {
                    // The browser fills the whole row, so it gets the rounded corners of the group.
                    MailBrowser()
                        .frame(height: 460)
                        .clipShape(.rect(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                }
            } header: {
                HStack {
                    Text("Inbox")
                    Spacer()
                    MailFilter()
                    Button("Clear inbox…") {
                        confirmsClear = true
                    }
                    .disabled(!service.isRunning || model.mails.isEmpty)
                }
            } footer: {
                Text("The inbox keeps the newest \(String(model.mailStatus?.settings.inboxMails ?? MailSettings().inboxMails)) mails. A filter shows the mails of one site or workspace. \"Open in Mailpit\" gives the HTML check and the other tools of Mailpit.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove all mails from the inbox?", isPresented: $confirmsClear) {
            Button("Clear inbox", role: .destructive) {
                model.clearInbox()
            }
        } message: {
            Text("You cannot get these mails back.")
        }
    }
}

private struct MailFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Filter", selection: Binding(get: { model.mailFilter ?? "" }, set: { model.filterMail(by: $0.isEmpty ? nil : $0) })) {
            Text("All sites and workspaces").tag("")

            if !model.mailTags.isEmpty {
                Divider()
            }

            ForEach(Array(Set(model.mailTags + [model.mailFilter].compactMap { $0 })).sorted(), id: \.self) { tag in
                Text(tag).tag(tag)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// The list takes the focus with a click on a mail. The arrow keys then open the mail above or
// below, and the Delete key removes the open mail, as in Mail. The focus is on the rows and not
// on the scroll view, because a focused scroll view uses the arrow keys to scroll.
private struct MailBrowser: View {
    // The Delete key of a Mac gives U+007F. KeyEquivalent.delete is U+0008.
    private static let backspace = KeyEquivalent("\u{7F}")

    @Environment(AppModel.self) private var model
    @FocusState private var listHasFocus: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.mails) { mail in
                            MailRow(mail: mail, selected: mail.id == model.openMailID)
                                .id(mail.id)
                                .onTapGesture {
                                    listHasFocus = true
                                    model.showMail(mail.id)
                                }
                                .contextMenu {
                                    Button("Remove", systemImage: "trash") {
                                        model.removeMail(mail.id)
                                    }
                                }

                            Divider()
                        }
                    }
                    .focusable(interactions: .edit)
                    .focused($listHasFocus)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.upArrow, .downArrow, .delete, .deleteForward, Self.backspace]) { press in
                        switch press.key {
                        case .upArrow: model.showMail(movingBy: -1)
                        case .downArrow: model.showMail(movingBy: 1)
                        default: model.removeOpenMail()
                        }

                        return .handled
                    }
                }
                .onChange(of: model.openMailID) { _, id in
                    if let id {
                        reader.scrollTo(id)
                    }
                }
            }
            .frame(width: 320)

            Divider()

            MailDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MailRow: View {
    @Environment(AppModel.self) private var model
    let mail: MailpitAPI.Summary
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(MailText.sender(mail.from))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(MailText.time(mail.created))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(mail.subject.isEmpty ? "No subject" : mail.subject)
                .lineLimit(1)

            HStack {
                Text(mail.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)

                if let tag = mail.tags.first {
                    MailTag(tag: tag)
                } else {
                    Text("No site")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.accentSoft : Color.clear)
        .contentShape(.rect)
    }
}

// The tag is the host of a site or a workspace. A workspace gets the branch icon.
struct MailTag: View {
    @Environment(AppModel.self) private var model
    let tag: String

    private var isWorkspace: Bool {
        model.allSites.flatMap(\.workspaces).contains { $0.hosts?.contains(tag) == true }
    }

    var body: some View {
        HStack(spacing: 3) {
            if isWorkspace {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
            }

            Text(tag)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color.accentText)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.accentSoft, in: .rect(cornerRadius: 4))
    }
}

private enum MailTab: String, CaseIterable, Identifiable {
    case html = "HTML"
    case text = "Text"
    case headers = "Headers"
    case files = "Files"

    var id: Self { self }
}

private struct MailDetail: View {
    @Environment(AppModel.self) private var model
    @State private var tab = MailTab.html

    var body: some View {
        if let mail = model.openMail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(mail.subject.isEmpty ? "No subject" : mail.subject)
                            .font(.headline)
                            .textSelection(.enabled)
                        Spacer()

                        ForEach(mail.tags, id: \.self) { MailTag(tag: $0) }

                        Button("Remove", systemImage: "trash") {
                            model.removeMail(mail.id)
                        }
                        .labelStyle(.iconOnly)
                        .controlSize(.small)
                        .help("Remove this mail from the inbox.")
                    }

                    MailHeaderLine(key: "From", value: mail.from)
                    MailHeaderLine(key: "To", value: mail.to.joined(separator: ", "))

                    if !mail.cc.isEmpty {
                        MailHeaderLine(key: "Cc", value: mail.cc.joined(separator: ", "))
                    }

                    MailHeaderLine(key: "Date", value: MailText.date(mail.date))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                Picker("View", selection: $tab) {
                    ForEach(MailTab.allCases) { tab in
                        Text(tab == .files ? "Files (\(mail.attachments.count))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                content(of: mail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(mail.id)
            .onAppear {
                tab = mail.html.isEmpty ? .text : .html
            }
        } else {
            Text("Choose a mail.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(of mail: MailpitAPI.Message) -> some View {
        switch tab {
        case .html:
            if mail.html.isEmpty {
                Text("This mail has no HTML part.")
                    .foregroundStyle(.secondary)
            } else {
                MailHTMLView(html: mail.html)
            }
        case .text:
            ScrollView {
                Text(mail.text.isEmpty ? "This mail has no text part." : mail.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .headers:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mail.headers.keys.sorted(), id: \.self) { key in
                        ForEach(Array((mail.headers[key] ?? []).enumerated()), id: \.offset) { _, value in
                            MailHeaderLine(key: key, value: value, keyWidth: 170)
                        }
                    }
                }
                .padding(16)
            }
        case .files:
            if mail.attachments.isEmpty {
                Text("This mail has no files.")
                    .foregroundStyle(.secondary)
            } else {
                List(mail.attachments) { file in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(file.file.isEmpty ? "Attachment" : file.file)
                        Spacer()
                        Text("\(file.type) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                            .foregroundStyle(.secondary)
                        Button("Open") {
                            model.openAttachment(file, of: mail)
                        }
                    }
                }
            }
        }
    }
}

private struct MailHeaderLine: View {
    let key: String
    let value: String
    var keyWidth: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: keyWidth, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// The HTML of a mail runs without JavaScript and without a store of its own. A click on a link
// opens the browser, as a mail app does.
private struct MailHTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != html else {
            return
        }

        context.coordinator.shown = html
        view.loadHTMLString(MailHTML.withDefaultFont(html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                return .allow
            }

            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

private struct MailNotInstalled: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.mailStatus?.waiting ?? 0
        let days = model.mailStatus?.settings.outboxDays ?? MailSettings().outboxDays

        ContentUnavailableView {
            Label("The mail service is not installed", systemImage: "envelope")
        } description: {
            Text(waiting > 0
                ? "Install the mail service to read \(MailNotices.mails(waiting)). The mails wait in the outbox for \(days) days."
                : "Install Mailpit to catch the mail of each site. No mail leaves the Mac.")
        } actions: {
            if let package = model.mailPackage {
                Button("Install") {
                    model.install(package)
                }
                .buttonStyle(.borderedProminent)
                .disabled(package.isDownloading)
            } else {
                Button("Open Packages") {
                    model.selection = .packages
                }
            }
        }
        .task {
            await model.refreshMail()
        }
    }
}

// The sender without the address, and the time of a mail in the words of the list.
enum MailText {
    static func sender(_ from: String) -> String {
        guard let open = from.firstIndex(of: "<"), open > from.startIndex else {
            return from.isEmpty ? "No sender" : from
        }

        return from[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func parsed(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }

    static func time(_ text: String) -> String {
        guard let date = parsed(text) else {
            return ""
        }

        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func date(_ text: String) -> String {
        parsed(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}
