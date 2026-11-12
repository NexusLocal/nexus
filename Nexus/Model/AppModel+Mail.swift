import AppKit
import NexusCore
import NexusIPC
import NexusMail

// The mail service (Phase 3, 3d). nexusd gives the state of the outbox and the settings. The
// inbox comes straight from the API of Mailpit on 127.0.0.1, so a new mail shows within a second.
extension AppModel {
    static let mailRefresh: Duration = .seconds(1)
    static let mailNotificationCheck: Duration = .seconds(3)

    var mailService: ServiceVersion? {
        versions(of: .mail).first
    }

    var mailPackage: PackageItem? {
        packages.first { $0.package == "mailpit" }
    }

    var inboxPort: Int? {
        mailService?.ports.first { $0.key == ServiceID.inboxPortKey }?.number
    }

    private var mailpit: MailpitAPI? {
        guard let mailService, mailService.isRunning, let inboxPort else {
            return nil
        }

        return MailpitAPI(port: inboxPort)
    }

    // The Mail screen reads the inbox again each second while it shows.
    func watchMail() async {
        while !Task.isCancelled {
            await refreshMail()
            try? await Task.sleep(for: Self.mailRefresh)
        }
    }

    func refreshMail() async {
        guard isLive else {
            return
        }

        if case .answer(.mailStatus(let status))? = await outcome(of: .mailStatus) {
            mailStatus = status
        }

        guard let mailpit else {
            mails = []
            mailCount = 0
            mailProblem = nil
            return
        }

        do {
            let page = try await mailpit.page(tag: mailFilter, limit: 200)
            mails = page.messages
            mailCount = page.total
            mailTags = try await mailpit.tags()
            mailProblem = nil

            if openMailID == nil, let first = mails.first {
                showMail(first.id)
            }
        } catch {
            mailProblem = "Nexus cannot read the inbox of Mailpit. \(error.localizedDescription)"
        }
    }

    func filterMail(by tag: String?) {
        mailFilter = tag
        openMailID = nil
        openMail = nil
        Task { await refreshMail() }
    }

    func showMail(_ id: String) {
        openMailID = id

        guard isLive else {
            openMail = Self.sampleMail(id)
            return
        }

        Task {
            guard let mailpit else {
                return
            }

            do {
                let message = try await mailpit.message(id: id)

                if openMailID == id {
                    openMail = message
                }
            } catch {
                mailProblem = "Nexus cannot read this mail. \(error.localizedDescription)"
            }
        }
    }

    func clearInbox() {
        guard isLive else {
            mails = []
            openMail = nil
            return
        }

        Task {
            do {
                try await mailpit?.removeAll()
                openMailID = nil
                openMail = nil
                await refreshMail()
            } catch {
                failure = ActionFailure(title: "The inbox is not empty", message: error.localizedDescription, place: .window)
            }
        }
    }

    func removeOpenMail() {
        if let openMailID {
            removeMail(openMailID)
        }
    }

    // A removal of the open mail opens the next mail of the list, as Mail does.
    func removeMail(_ id: String) {
        let index = mails.firstIndex { $0.id == id }
        let next = index.flatMap { mails.dropFirst($0 + 1).first ?? mails.prefix($0).last }?.id

        guard isLive else {
            mails.removeAll { $0.id == id }
            mailCount = mails.count
            openNext(after: id, next: next)
            return
        }

        Task {
            do {
                try await mailpit?.remove(ids: [id])
                openNext(after: id, next: next)
                await refreshMail()
            } catch {
                failure = ActionFailure(title: "The mail is not removed", message: error.localizedDescription, place: .window)
            }
        }
    }

    private func openNext(after removed: String, next: String?) {
        guard openMailID == removed else {
            return
        }

        openMailID = nil
        openMail = nil

        if let next {
            showMail(next)
        }
    }

    func clearOutbox() {
        send(.clearOutbox, failure: "Nexus did not remove the waiting mails", place: .window) { [weak self] _ in
            Task { await self?.refreshMail() }
        }
    }

    func acknowledgeRemovedMails() {
        send(.acknowledgeRemovedMails, failure: "Nexus did not reset the count of the removed mails", place: .window) { [weak self] _ in
            Task { await self?.refreshMail() }
        }
    }

    func openInMailpit() {
        if let inboxPort, let url = URL(string: "http://127.0.0.1:\(inboxPort)/") {
            NSWorkspace.shared.open(url)
        }
    }

    // macOS opens an attachment from a temporary copy, as Mail does.
    func openAttachment(_ attachment: MailpitAPI.Attachment, of mail: MailpitAPI.Message) {
        Task {
            do {
                guard let mailpit else {
                    return
                }

                let data = try await mailpit.attachment(attachment, of: mail.id)
                let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus Mail/\(mail.id)/\(attachment.part)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = attachment.file.isEmpty ? "attachment" : (attachment.file as NSString).lastPathComponent
                let file = folder.appending(path: name)
                try data.write(to: file)
                NSWorkspace.shared.open(file)
            } catch {
                failure = ActionFailure(title: "\(attachment.file) did not open", message: error.localizedDescription, place: .window)
            }
        }
    }

    // Where the main checkout of a site sends its mail (3c). The probe can take some seconds.
    func siteMail(of site: SiteItem) async -> SiteMail? {
        guard isLive else {
            return site.host == "shop.test"
                ? SiteMail(sendsToNexus: false, warning: "This site sends mail through smtp.postmarkapp.com. So a mail can reach a real person.", canSendToNexus: true, destination: "smtp.postmarkapp.com", changes: Self.sampleMailChanges(user: site.host))
                : SiteMail(sendsToNexus: true, canRestore: true)
        }

        guard case .answer(.siteMail(let mail))? = await outcome(of: .siteMail(host: site.host)) else {
            return nil
        }

        return mail
    }

    func sendMailToNexus(_ site: SiteItem) async -> Bool {
        guard isLive else {
            return true
        }

        return await perform(.sendMailToNexus(host: site.host), failure: "\(site.host) does not send its mail to Nexus", place: .window) != nil
    }

    func restoreMailSettings(_ site: SiteItem) async -> Bool {
        guard isLive else {
            return true
        }

        return await perform(.restoreMailSettings(host: site.host), failure: "\(site.host) does not use its old mail settings", place: .window) != nil
    }

    private static func sampleMailChanges(user: String) -> [EnvKeyChange] {
        [
            EnvKeyChange(key: "MAIL_HOST", value: "127.0.0.1", isNew: false),
            EnvKeyChange(key: "MAIL_PORT", value: "1025", isNew: false),
            EnvKeyChange(key: "MAIL_PASSWORD", value: "", isNew: false),
            EnvKeyChange(key: "MAIL_USERNAME", value: user, isNew: true),
        ]
    }

    func showMails(of host: String) {
        filterMail(by: host)
        selection = .service(.mail)
    }

    func saveMailSettings(_ settings: MailSettings) {
        send(.setMailSettings(settings), failure: "The settings of the mail service did not change", place: .settings) { [weak self] _ in
            Task { await self?.refreshMail() }
        }
    }

    // A notification for each new mail is a setting of the app, off by default (3d). The check
    // runs while the app runs, also without the Mail screen. The first check only remembers the
    // newest mail, so the mails of before do not give notifications.
    func watchNewMail() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.mailNotificationCheck)
                await self?.notifyNewMail()
            }
        }
    }

    private func notifyNewMail() async {
        guard AppPreference.isOn(AppPreference.notifyNewMail), let mailpit, let newest = try? await mailpit.messages(limit: 10) else {
            newestNotifiedMail = nil
            return
        }

        defer { newestNotifiedMail = newest.first?.id }

        guard let seen = newestNotifiedMail else {
            return
        }

        for mail in newest.prefix(while: { $0.id != seen }).reversed() {
            let tag = mail.tags.first.map { " for \($0)" } ?? ""
            Notifier.post("New mail\(tag)", "\(mail.subject)\n\(mail.from)", setting: AppPreference.notifyNewMail)
        }
    }
}
