import Foundation
import NexusCore
import NexusIPC
import NexusMail
import NexusRuntime
import NexusSupervisor

// The mail service (Phase 3). nexusd listens on the SMTP port itself while the mail package is
// installed, also while Mailpit is stopped. Mailpit is the inbox. While it does not run, each mail
// waits in the outbox, and Mailpit gets the waiting mails at its next start.
extension NexusEngine {
    static let mailPortKeys: Set<String> = [ServiceCatalog.smtpPortKey, ServiceCatalog.inboxPortKey, ServiceCatalog.mailpitSMTPPortKey]
    static let mailpitStartWait: Duration = .seconds(10)

    func mailRuntime() async -> InstalledRuntime? {
        await newestRuntime(named: "mailpit")
    }

    // A port in use gives the choice of D31, as for the other services.
    func startMailReceiver() async throws {
        guard mailReceiver == nil, let runtime = await mailRuntime() else {
            return
        }

        guard let port = try await ports(for: runtime)[ServiceCatalog.smtpPortKey] else {
            return
        }

        do {
            mailReceiver = try await boundReceiver(port: port)
            mailReceiverConflict = nil
        } catch let conflict as PortConflict {
            mailReceiverConflict = conflict
            throw conflict
        }
    }

    func stopMailReceiver() {
        mailReceiver?.stop()
        mailReceiver = nil
    }

    // macOS lets a program bind 127.0.0.1 while another program listens on all addresses of the
    // same port, as Homebrew Mailpit does. So the port is checked first, as the supervisor checks
    // the ports of a service.
    private func boundReceiver(port: Int) async throws -> SMTPReceiver {
        let router = mailRouter
        let receiver = SMTPReceiver(port: port) { router.deliver($0) }

        guard await PortInspector.becomesFree(port) else {
            throw await receiverConflict(port: port)
        }

        do {
            try receiver.start()
        } catch {
            throw await receiverConflict(port: port)
        }

        return receiver
    }

    private func receiverConflict(port: Int) async -> PortConflict {
        PortConflict(service: ServiceCatalog.mailID, port: port, owner: PortInspector.owner(of: port), suggestedPort: await suggestedPort(after: port), portKey: ServiceCatalog.smtpPortKey)
    }

    // The receiver moves at once. It binds the new port before it frees the old one, so a port in
    // use leaves the receiver where it is.
    func setSMTPPort(_ port: Int) async throws -> String {
        guard mailReceiver?.port != port else {
            return "nexusd receives mail on port \(port) already."
        }

        let receiver = try await boundReceiver(port: port)

        do {
            try await stateStore.update { $0.ports[ServiceCatalog.smtpPortKey] = port }
        } catch {
            receiver.stop()
            throw error
        }

        stopMailReceiver()
        mailReceiver = receiver
        mailReceiverConflict = nil

        let problems = await writePHPMailLines()
        return (["nexusd receives mail on port \(port)."] + problems).joined(separator: "\n")
    }

    // The receiver has a port before the mail package is installed, because PHP gives its mail to
    // that port also without the package (3b).
    func smtpPort(in state: EngineState) async throws -> Int {
        if let port = state.ports[ServiceCatalog.smtpPortKey] {
            return port
        }

        return try await stateStore.port(for: ServiceCatalog.smtpPortKey, standard: ServiceCatalog.smtpStandardPort)
    }

    // Each PHP version names the port in its sendmail_path. A running PHP reads it again at once.
    private func writePHPMailLines() async -> [String] {
        await rewritePHPConfigs().map { "PHP \($0.line) still sends mail to the old port. \(ErrorText.plain($0.error))" }
    }

    // nexus sendmail reads the limits from the outbox folder, because it also runs without nexusd.
    func applyMailSettings(_ settings: MailSettings) {
        let limits = MailOutbox.Limits(
            count: settings.outboxMails,
            bytes: settings.outboxBytes,
            age: TimeInterval(settings.outboxDays * 86_400),
            whenFull: settings.whenFull == .refuseNew ? .refuseNew : .removeOldest
        )

        mailRouter.setLimits(limits)
        try? mailRouter.outbox.saveLimits(limits)
    }

    // Mailpit reads the size of the inbox at its start. So a new size restarts a running Mailpit.
    func setMailSettings(_ settings: MailSettings) async throws -> String {
        if let problem = settings.problem {
            throw RuntimeError.unsupported(problem)
        }

        let old = await stateStore.current().mailSettings
        try await stateStore.update { $0.mailSettings = settings }
        applyMailSettings(settings)

        guard settings.inboxMails != old.inboxMails, await supervisor.state(of: ServiceCatalog.mailID)?.isActive == true else {
            return "The settings of the mail service are changed."
        }

        _ = try await restart(ServiceCatalog.mailID)
        return "The settings of the mail service are changed. Mailpit started again. The inbox keeps the newest \(settings.inboxMails) mails."
    }

    func mailStatus() async throws -> MailStatus {
        let state = await stateStore.current()
        let runtime = await mailRuntime()
        var registry: [String: Int] = [:]

        if let runtime {
            registry = try await ports(for: runtime)
        }

        let supervised = await supervisor.status().first { $0.id == ServiceCatalog.mailID }
        let outbox = mailRouter.outbox
        let summary = outbox.summary()
        var running = false

        if case .running = supervised?.state {
            running = true
        }

        return MailStatus(
            installed: runtime != nil,
            running: running,
            receiving: mailReceiver != nil,
            smtpPort: mailReceiver?.port ?? state.ports[ServiceCatalog.smtpPortKey],
            inboxPort: running ? supervised?.ports.first : registry[ServiceCatalog.inboxPortKey],
            waiting: summary.count,
            waitingBytes: summary.bytes,
            removed: outbox.removedCount(),
            refused: outbox.refusedCount(),
            outboxFolder: outbox.folder.path(percentEncoded: false),
            settings: state.mailSettings
        )
    }

    // The mails that Mailpit refused go too, because nothing else removes them.
    func clearOutbox() -> String {
        let outbox = mailRouter.outbox
        let waiting = outbox.removeAll()
        let refused = outbox.removeRefused()
        outbox.resetRemovedCount()
        servicesChanged()

        let parts = [waiting > 0 ? Self.count(waiting, "waiting mail") : nil, refused > 0 ? Self.count(refused, "refused mail") : nil].compactMap { $0 }
        return parts.isEmpty ? "The outbox is empty." : "Nexus removed \(EnglishList.joined(parts))."
    }

    // The receiver turns the folder of a PHP script into the host of its site or workspace.
    func updateMailFolders() async {
        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)
        let all = sites + workspaceSites(state, resolved: sites).sites
        let folders = Dictionary(all.map { (RealPath.of($0.folder), $0.host) }) { first, _ in first }

        mailRouter.setSiteFolders(folders)
    }

    // The receiver starts with the package. A port in use does not stop the install.
    func receiveMail(after installed: String) async -> String {
        do {
            try await startMailReceiver()
            return installed
        } catch {
            return "\(installed)\nnexusd does not receive mail yet. \(ErrorText.plain(error))"
        }
    }

    // The SMTP port of Mailpit is for nexusd only, so the message does not name it.
    func mailStartMessage() async throws -> String? {
        let status = try await mailStatus()

        guard let smtp = status.smtpPort, let inbox = status.inboxPort else {
            return nil
        }

        return "The mail service runs. nexusd receives mail on port \(smtp). The inbox is http://127.0.0.1:\(inbox)/"
    }

    // The mail service shows the port of the receiver and the port of the inbox. The SMTP port of
    // Mailpit is for nexusd only.
    func shownPorts(_ ports: [Int], of runtime: InstalledRuntime) async throws -> [Int] {
        guard runtime.name == "mailpit" else {
            return ports
        }

        let registry = try await self.ports(for: runtime)
        let smtp = mailReceiver?.port ?? registry[ServiceCatalog.smtpPortKey]
        return [smtp, ports.first ?? registry[ServiceCatalog.inboxPortKey]].compactMap { $0 }
    }

    // A receiver that does not listen is a problem while Mailpit runs, and a port conflict while it
    // is stopped.
    func mailDetails(running: Bool) -> (problem: String?, conflict: PortConflict?) {
        guard mailReceiver == nil else {
            return (nil, nil)
        }

        let reason = mailReceiverConflict?.description ?? "The receiver of nexusd does not run."
        return running ? ("nexusd does not receive mail. \(reason)", nil) : (nil, mailReceiverConflict)
    }

    // Mailpit gets the waiting mails after each start, also after a restart by the supervisor. The
    // route sends new mail to the outbox while Mailpit does not run.
    func mailServiceChanged() async {
        guard case .running(let pid, _) = await supervisor.state(of: ServiceCatalog.mailID),
              let port = await supervisor.status().first(where: { $0.id == ServiceCatalog.mailID })?.ports.last else {
            mailRouter.setInbox(port: nil)
            mailpitWithWaitingMails = nil
            mailRetry?.cancel()
            mailRetry = nil
            return
        }

        guard pid != mailpitWithWaitingMails else {
            return
        }

        mailpitWithWaitingMails = pid
        mailRouter.setInbox(port: port)
        deliverWaitingMail(port: port)
        retryWaitingMail()
    }

    func setMailRetryInterval(_ interval: Duration) {
        mailRetryInterval = interval
    }

    // Each try reads only the names in the outbox folder while the outbox is empty.
    private func retryWaitingMail() {
        mailRetry?.cancel()
        let router = mailRouter
        let interval = mailRetryInterval

        mailRetry = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)

                guard !Task.isCancelled, router.currentInboxPort != nil, router.outbox.summary().count > 0 else {
                    continue
                }

                let result = router.deliverWaiting()
                await self.waitingMailDelivered(result)
            }
        }
    }

    // The supervisor marks Mailpit as running before Mailpit listens. So the delivery waits for
    // its SMTP port first.
    private func deliverWaitingMail(port: Int) {
        let router = mailRouter
        let wait = Self.mailpitStartWait

        Task.detached {
            let deadline = ContinuousClock.now + wait
            while !PortInspector.acceptsConnections(port), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }

            let result = router.deliverWaiting()
            await self.waitingMailDelivered(result)
        }
    }

    private func waitingMailDelivered(_ result: MailRouter.DeliveryResult) {
        if result.delivered > 0 {
            activity?.write("mail", "Mailpit got \(Self.count(result.delivered, "waiting mail"))")
        }

        if result.refused > 0 {
            activity?.write("mail", "Mailpit refused \(Self.count(result.refused, "waiting mail")). See \(mailRouter.outbox.refusedFolder.path(percentEncoded: false))")
        }

        servicesChanged()
    }
}
