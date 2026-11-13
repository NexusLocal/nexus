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

        return "\(name) · \(Count.text(model.mailCount, "mail")) in the inbox"
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
                    model.checkPackagesOnClick()
                }
                .disabled(model.checkingPackages)

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
                    WarningBanner(title: "\(Count.text(waiting, "mail")) wait for the mail service", message: "Mailpit is stopped. nexusd keeps each new mail in the outbox. The inbox gets them at the next start.") {
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
                    WarningBanner(title: "Nexus removed \(Count.text(removed, "mail")) from the outbox", message: "The outbox was full. So the oldest mails went. Change the limits in Settings > Mail.") {
                        Button("Mail settings…") {
                            UserDefaults.standard.set(SettingsTab.mail.rawValue, forKey: SettingsWindow.tabKey)
                            openSettings()
                        }

                        Button("OK") {
                            model.acknowledgeRemovedMails()
                        }
                    }
                }

                if refused > 0 {
                    WarningBanner(title: "Mailpit refused \(Count.text(refused, "mail"))", message: "Nexus keeps them with the reason in the folder refused, next to the outbox.") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(NexusPaths.standard.mail.appending(path: "refused", directoryHint: .isDirectory))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .confirmationDialog("Remove the waiting mails?", isPresented: $confirmsRemoval) {
                Button("Remove \(Count.text(waiting, "mail"))", role: .destructive) {
                    model.clearOutbox()
                }
            } message: {
                Text("The inbox does not get these mails. The mails that Mailpit refused go too.")
            }
        }
    }
}

private struct MailForm: View {
    @Environment(AppModel.self) private var model
    @Binding var service: ServiceVersion
    @State private var confirmsClear = false

    var body: some View {
        Form {
            PackageCheckSection(service: service)
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

// The Delete key removes the open mail, as in Mail.
private struct MailBrowser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ListDetailView(items: model.mails, openID: model.openMailID, listWidth: 320, open: { model.showMail($0) }, remove: { model.removeOpenMail() }) { mail, selected in
            MailRow(mail: mail, selected: selected)
                .contextMenu {
                    Button("Remove", systemImage: "trash") {
                        model.removeMail(mail.id)
                    }
                }
        } detail: {
            MailDetail()
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
                MailTag(tag: mail.tags.first)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.accentSoft : Color.clear)
        .contentShape(.rect)
    }
}

// The tag of Mailpit is the host of a site or a workspace. Mailpit does not say which, so the
// sites of the app tell.
struct MailTag: View {
    @Environment(AppModel.self) private var model
    let tag: String?

    private var isWorkspace: Bool {
        guard let tag else {
            return false
        }

        return model.allSites.flatMap(\.workspaces).contains { $0.hosts?.contains(tag) == true }
    }

    var body: some View {
        SiteTag(text: tag, isWorkspace: isWorkspace)
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

                    HeaderLine(key: "From", value: mail.from)
                    HeaderLine(key: "To", value: mail.to.joined(separator: ", "))

                    if !mail.cc.isEmpty {
                        HeaderLine(key: "Cc", value: mail.cc.joined(separator: ", "))
                    }

                    HeaderLine(key: "Date", value: MailText.date(mail.date))
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
                            HeaderLine(key: key, value: value, keyWidth: 170)
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

// The HTML of a mail runs without JavaScript and without a store of its own. A click on a link
// opens the browser, as a mail app does. The appearance of the web view follows the setting
// "Appearance of mails inside Nexus". So a mail with its own dark colors uses them.
private struct MailHTMLView: NSViewRepresentable {
    let html: String
    @AppStorage(AppPreference.mailAppearance) private var appearance = MailAppearance.auto
    @Environment(\.colorScheme) private var colorScheme

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
        let dark = appearance.isDark(in: colorScheme)

        guard context.coordinator.shown != html || context.coordinator.shownDark != dark else {
            return
        }

        context.coordinator.shown = html
        context.coordinator.shownDark = dark
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.loadHTMLString(MailHTML.forDisplay(html, dark: dark), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?
        var shownDark: Bool?

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
                ? "Install the mail service to read \(Count.text(waiting, "mail")). The mails wait in the outbox for \(days) days."
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
        parsed(text)?.listTime ?? ""
    }

    static func date(_ text: String) -> String {
        parsed(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}
