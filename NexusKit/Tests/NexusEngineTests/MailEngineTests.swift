import Darwin
import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusMail
import NexusRuntime
import NexusSupervisor
import Synchronization
import Testing
@testable import NexusEngine

// The mail service of Phase 3. The fake Mailpit listens only on its inbox port. A test that needs
// the SMTP port of Mailpit starts its own receiver there after the start of the service.
extension NexusEngineTests {
    private struct MailPorts {
        let smtp: Int
        let inbox: Int
        let mailpit: Int
    }

    // The three ports are held at the same time while they are chosen, so they differ.
    private func mailPorts() -> MailPorts {
        let holders = (0..<3).map { _ in SMTPReceiver(port: 0) { _ in .accepted } }
        holders.forEach { try? $0.start() }
        defer { holders.forEach { $0.stop() } }
        return MailPorts(smtp: holders[0].port, inbox: holders[1].port, mailpit: holders[2].port)
    }

    // A real Mailpit replaces the fake one when the test gives its path.
    private func makeMailEngine(root: URL, ports: MailPorts, realMailpit: URL? = nil, state: EngineState = EngineState(), runtimes: [(name: String, line: String)] = []) throws -> NexusEngine {
        var state = state
        state.ports.merge([ServiceCatalog.smtpPortKey: ports.smtp, ServiceCatalog.inboxPortKey: ports.inbox, ServiceCatalog.mailpitSMTPPortKey: ports.mailpit]) { _, new in new }
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("mailpit", "1")] + runtimes)

        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        let bin = paths.runtime("mailpit", line: "1").appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let mailpit = bin.appending(path: "mailpit")

        if let realMailpit {
            try FileManager.default.copyItem(at: realMailpit.resolvingSymlinksInPath(), to: mailpit)
            return engine
        }

        try Data("#!/bin/sh\nexec /usr/bin/nc -lk 127.0.0.1 \"${4##*:}\"\n".utf8).write(to: mailpit)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mailpit.path(percentEncoded: false))
        return engine
    }

    private func outbox(of root: URL) -> MailOutbox {
        MailOutbox(folder: NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory)).mailOutbox)
    }

    private func mail(_ subject: String) -> MailMessage {
        MailMessage(from: "shop@example.com", recipients: ["customer@example.com"], user: "shop.test", data: Data("Subject: \(subject)\r\n\r\nHello\r\n".utf8))
    }

    private func status(of id: String, in engine: NexusEngine) async -> ServiceStatus? {
        guard case .services(let services) = await engine.handle(.status) else {
            return nil
        }

        return services.first { $0.id == id }
    }

    @Test func aSendmailFromTheProjectFolderOfASiteOnPublicGetsTheTagOfTheSite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "shop", directoryHint: .isDirectory)
        let publicFolder = project.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: publicFolder, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        let router = await engine.mailRouter

        await engine.publishSites()
        let tagged = await eventually { router.tag(for: RealPath.of(project)) == "shop.test" }

        #expect(tagged)
        #expect(router.tag(for: "\(RealPath.of(publicFolder))/index.php") == "shop.test")
        #expect(router.tag(for: RealPath.of(root)) == nil)
    }

    @Test func aSendmailFromTheFolderOfASiteGetsThatSiteAndNotTheSiteOnItsPublicFolder() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "p", directoryHint: .isDirectory)
        let publicFolder = project.appending(path: "public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "composer.json"))
        var state = EngineState()
        state.sites = [Site(host: "a.test", folder: publicFolder, php: "8.5"), Site(host: "b.test", folder: project, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state)
        let router = await engine.mailRouter

        await engine.publishSites()
        let tagged = await eventually { router.tag(for: RealPath.of(project)) != nil }

        #expect(tagged)
        #expect(router.tag(for: RealPath.of(project)) == "b.test")
        #expect(router.tag(for: "\(RealPath.of(publicFolder))/index.php") == "a.test")
    }

    @Test func theMailServiceShowsTheSMTPPortAndTheInbox() {
        let catalog = ServiceCatalog(paths: NexusPaths(root: URL(filePath: "/Nexus", directoryHint: .isDirectory)))
        let runtime = InstalledRuntime(name: "mailpit", line: "1", version: "1.33.0", revision: 1, sha256: "", installedAt: .now,
                                       folder: URL(filePath: "/Nexus/runtimes/mailpit/1", directoryHint: .isDirectory))

        let definition = catalog.definition(for: runtime, ports: ["smtp": 11025, "inbox": 18025, "mailpit-smtp": 11026], inboxMails: 500)

        #expect(definition?.id == "mail")
        #expect(definition?.executable.path(percentEncoded: false) == "/Nexus/runtimes/mailpit/1/bin/mailpit")
        #expect(definition?.ports == [18025, 11026])
        #expect(definition?.arguments == [
            "--smtp", "127.0.0.1:11026",
            "--listen", "127.0.0.1:18025",
            "--database", "/Nexus/data/mailpit-1/mailpit.db",
            "--max", "500",
            "--smtp-max-recipients", "1000",
            "--smtp-auth-accept-any",
            "--smtp-auth-allow-insecure",
            "--tags-username",
            "--disable-version-check",
        ])
        #expect(catalog.portRequirements(for: runtime).map(\.standard) == [1025, 8025, 1026])
    }

    @Test func nexusdReceivesMailWhileMailpitIsStoppedAndKeepsItInTheOutbox() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)

        try await whileRunning(engine) {
            await engine.startEnabledServices()

            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("Reset your password"))
            let service = await status(of: "mail", in: engine)
            let waiting = outbox(of: root).waiting()

            #expect(service?.ports == [ports.smtp, ports.inbox])
            #expect(service?.state == .stopped)
            #expect(waiting.count == 1)
            #expect(try waiting.first.map { try outbox(of: root).read($0).user } == "shop.test")
        }
    }

    @Test func mailpitGetsTheWaitingMailsAtItsStartAndTheNewMailAtOnce() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)
        let received = ReceivedMailList()

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("First"))

            let started = await engine.handle(.start(service: "mail"))
            let mailpitSMTP = SMTPReceiver(port: ports.mailpit) { received.append($0) }
            try mailpitSMTP.start()
            defer { mailpitSMTP.stop() }
            let delivered = await eventually { received.count == 1 }
            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("Second"))

            guard case .done = started else {
                Issue.record("Mailpit did not start: \(started)")
                return
            }
            #expect(delivered)
            #expect(received.count == 2)
            #expect(received.users == ["shop.test", "shop.test"])
            #expect(outbox(of: root).waiting().isEmpty)
        }
    }

    @Test func aMailThatReachesTheOutboxWhileMailpitRunsGoesToMailpitSoon() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)
        let received = ReceivedMailList()

        try await whileRunning(engine) {
            await engine.setMailRetryInterval(.milliseconds(100))
            await engine.startEnabledServices()
            _ = await engine.handle(.start(service: "mail"))
            let mailpitSMTP = SMTPReceiver(port: ports.mailpit) { received.append($0) }
            try mailpitSMTP.start()
            defer { mailpitSMTP.stop() }

            _ = try outbox(of: root).store(mail("From an old port"))
            let delivered = await eventually { received.count == 1 }

            #expect(delivered)
            #expect(outbox(of: root).waiting().isEmpty)
        }
    }

    @Test func theStopOfMailpitKeepsTheReceiver() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            _ = await engine.handle(.start(service: "mail"))
            let stopped = await engine.handle(.stop(service: "mail"))

            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("Welcome"))

            #expect(stopped == .done(message: "mail stopped."))
            #expect(outbox(of: root).waiting().count == 1)
        }
    }

    @Test func anSMTPPortInUseGivesAPortConflictUntilANewPort() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)
        let listener = try listen(on: ports.smtp)
        defer { close(listener) }
        let newPort = freePort()

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let response = await engine.handle(.start(service: "mail"))
            let moved = await engine.handle(.setPort(service: "smtp", port: newPort))
            let service = try await engine.serviceList()

            guard case .portInUse(let conflict) = response else {
                Issue.record("no port conflict: \(response)")
                return
            }
            #expect(conflict.service == "mail")
            #expect(conflict.portKey == "smtp")
            #expect(conflict.description.hasSuffix("nexus port smtp \(conflict.suggestedPort)"))
            #expect(moved == .done(message: "nexusd receives mail on port \(newPort)."))
            #expect(service.services.first { $0.id == "mail" }?.portConflict == nil)
            #expect(PortInspector.acceptsConnections(newPort))
        }
    }

    // Runs only when NEXUS_MAILPIT names a mailpit binary.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_MAILPIT"] != nil))
    func aRealMailpitGetsTheMailWithTheTagAlsoAfterItWaited() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let mailpit = URL(filePath: try #require(ProcessInfo.processInfo.environment["NEXUS_MAILPIT"]))
        let engine = try makeMailEngine(root: root, ports: ports, realMailpit: mailpit)
        let api = try #require(URL(string: "http://127.0.0.1:\(ports.inbox)/api/v1/messages"))

        func tags() async throws -> [[String]] {
            let (data, _) = try await URLSession.shared.data(from: api)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let messages = object?["messages"] as? [[String: Any]] ?? []
            return messages.map { $0["Tags"] as? [String] ?? [] }
        }

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("Waited"))

            let started = await engine.handle(.start(service: "mail"))
            let delivered = await eventually { outbox(of: root).waiting().isEmpty }
            try SMTPClient(port: ports.smtp, timeout: 5).send(MailMessage(from: "a@example.com", recipients: ["b@example.com"], user: "fix.shop.test", data: Data("Subject: Direct\r\n\r\nHi\r\n".utf8)))
            let all = try await tags()
            let api = MailpitAPI(port: ports.inbox)
            let ofWorkspace = try await api.page(tag: "fix.shop.test")
            let everything = try await api.page()
            let allTags = try await api.tags()
            let latest = try await api.message(id: "latest")

            guard case .done = started else {
                Issue.record("Mailpit did not start: \(started)")
                return
            }
            #expect(delivered)
            #expect(all.sorted { $0.joined() < $1.joined() } == [["fix.shop.test"], ["shop.test"]])
            #expect(ofWorkspace.messages.map(\.subject) == ["Direct"])
            #expect(ofWorkspace.total == 1)
            #expect(everything.total == 2)
            #expect(allTags.sorted() == ["fix.shop.test", "shop.test"])
            #expect(everything.messages.contains { $0.snippet.contains("Hi") })
            #expect(latest.subject == "Direct")
            #expect(latest.text.contains("Hi"))
            #expect(latest.headers["Subject"] == ["Direct"])

            try await api.removeAll()
            #expect(try await api.messages().isEmpty)
        }
    }

    // The socket of PHP-FPM must fit in 103 bytes, so this root is short.
    @Test func eachPHPVersionSendsItsMailToTheSMTPPortAndMovesWithIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports, runtimes: [("php", "8.5")])
        let ini = await engine.paths.phpConfigFolder(line: "8.5").appending(path: "conf.d/00-nexus.ini")
        let command = await engine.paths.bin.appending(path: "nexus").path(percentEncoded: false)
        let newPort = freePort()

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            _ = try await engine.writePHPConfig(line: "8.5", state: await engine.stateStore.current())
            let before = try String(contentsOf: ini, encoding: .utf8)

            _ = await engine.handle(.setPort(service: "smtp", port: newPort))
            let after = try String(contentsOf: ini, encoding: .utf8)

            #expect(before.contains("sendmail_path = \"'\(command)' sendmail -S 127.0.0.1:\(ports.smtp) -t -i\"\n"))
            #expect(before.contains("mail.add_x_header = On\n"))
            #expect(after.contains("sendmail -S 127.0.0.1:\(newPort) -t -i\"\n"))
        }
    }

    @Test func aWaitingMailFromTheFolderOfASiteGetsTheHostOfThatSite() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        let shop = site("shop.test", in: projects)
        try FileManager.default.createDirectory(at: shop.folder.appending(path: "public"), withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [shop]
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports, state: state)
        let received = ReceivedMailList()
        var message = mail("Reset")
        message = MailMessage(from: message.from, recipients: message.recipients, user: RealPath.of(shop.folder) + "/public", data: message.data)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            try SMTPClient(port: ports.smtp, timeout: 5).send(message)

            _ = await engine.handle(.start(service: "mail"))
            let mailpitSMTP = SMTPReceiver(port: ports.mailpit) { received.append($0) }
            try mailpitSMTP.start()
            defer { mailpitSMTP.stop() }
            let delivered = await eventually { received.count == 1 }

            #expect(delivered)
            #expect(received.users == ["shop.test"])
        }
    }

    @Test func theSettingsGiveTheLimitsToTheOutboxAndRefuseAValueOutsideItsRange() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeMailEngine(root: root, ports: mailPorts())
        var settings = MailSettings()
        settings.outboxMails = 20
        settings.whenFull = .refuseNew
        var tooLarge = settings
        tooLarge.outboxBytes = 3 * 1024 * MailSettings.megabyte

        let refused = await engine.handle(.setMailSettings(tooLarge))
        let changed = await engine.handle(.setMailSettings(settings))
        let limits = outbox(of: root).storedLimits()

        #expect(refused == .failure(message: "The outbox can use from 10 MB to 2 GB."))
        #expect(changed == .done(message: "The settings of the mail service are changed."))
        #expect(await engine.stateStore.current().mailSettings == settings)
        #expect(limits == MailOutbox.Limits(count: 20, bytes: 100 * MailSettings.megabyte, age: 7 * 86_400, whenFull: .refuseNew))
        #expect(await engine.mailRouter.currentLimits == limits)
    }

    @Test func aNewSizeOfTheInboxStartsMailpitAgainWithIt() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeMailEngine(root: root, ports: mailPorts())
        var settings = MailSettings()
        settings.inboxMails = 2000

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            _ = await engine.handle(.start(service: "mail"))
            let before = await engine.supervisor.state(of: "mail")

            let changed = await engine.handle(.setMailSettings(settings))
            let after = await engine.supervisor.state(of: "mail")
            let arguments = try await engine.serviceDefinition("mail")?.arguments ?? []

            #expect(changed == .done(message: "The settings of the mail service are changed. Mailpit started again. The inbox keeps the newest 2000 mails."))
            #expect(before != after)
            #expect(arguments.contains("2000"))
        }
    }

    @Test func theStatusCountsTheWaitingMailsAndTheClearRemovesThem() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("One"))
            try SMTPClient(port: ports.smtp, timeout: 5).send(mail("Two"))

            let status = try await engine.mailStatus()
            let cleared = await engine.handle(.clearOutbox)
            let empty = try await engine.mailStatus()

            #expect(status.installed)
            #expect(!status.running)
            #expect(status.receiving)
            #expect(status.smtpPort == ports.smtp)
            #expect(status.inboxPort == ports.inbox)
            #expect(status.waiting == 2)
            #expect(cleared == .done(message: "Nexus removed 2 waiting mails."))
            #expect(empty.waiting == 0)
        }
    }

    @Test func theMailServiceNamesItsThreePorts() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeMailEngine(root: root, ports: mailPorts())

        let response = await engine.handle(.setPort(service: "mail", port: 2525))

        #expect(response == .failure(message: "The mail service has three ports. Run: nexus port smtp <port>, nexus port inbox <port>, or: nexus port mailpit-smtp <port>"))
    }

    @Test func theRemovalOfTheMailPackageStopsTheReceiver() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = mailPorts()
        let engine = try makeMailEngine(root: root, ports: ports)

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let listened = PortInspector.acceptsConnections(ports.smtp)

            _ = await engine.handle(.remove(name: "mailpit", line: "1"))

            #expect(listened)
            #expect(!PortInspector.acceptsConnections(ports.smtp))
        }
    }

    @Test func theRestorePutsTheOldMailSettingsBackInTheEnvOfALaravelSite() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = site("shop.test", in: root.appending(path: "projects", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: shop.folder.appending(path: "bootstrap"), withIntermediateDirectories: true)
        try Data().write(to: shop.folder.appending(path: "artisan"))
        try Data().write(to: shop.folder.appending(path: "bootstrap/app.php"))
        let env = shop.folder.appending(path: ".env")
        let old = "APP_NAME=Shop\nMAIL_HOST=smtp.postmarkapp.com\n"
        try Data(EnvRewrite.applyKeepingOldValues(to: old, keys: ["MAIL_HOST": "127.0.0.1", "MAIL_USERNAME": "shop.test"]).utf8).write(to: env)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: env.path(percentEncoded: false))
        var state = EngineState()
        state.sites = [shop]
        let engine = try makeSiteEngine(root: root, state: state)

        let response = await engine.handle(.restoreMailSettings(host: "shop.test"))
        let again = await engine.handle(.restoreMailSettings(host: "shop.test"))

        #expect(response == .done(message: "shop.test uses its old mail settings again. Nexus put back the old values of MAIL_HOST in its .env. Nexus removed MAIL_USERNAME from its .env. A queue worker reads the old values after a restart."))
        #expect(try String(contentsOf: env, encoding: .utf8) == old)
        #expect(NexusEngine.permissions(of: env.path(percentEncoded: false)) == 0o640)
        #expect(again == .failure(message: "The .env of shop.test has no old mail settings from before Nexus."))
        #expect(await engine.stateStore.current().declinedMailTags == ["shop.test"])
    }

    @Test func theChangesOfSendMailToNexusFollowTheLinesOfTheEnvAndANewKeyComesLast() {
        let text = "MAIL_PORT=587\n# MAIL_USERNAME=old\nMAIL_HOST=smtp.postmarkapp.com\n"

        let changes = NexusEngine.mailChanges(["MAIL_HOST": "127.0.0.1", "MAIL_PORT": "1025", "MAIL_USERNAME": "shop.test", "MAIL_MAILER": "smtp"], in: text)

        #expect(changes == [
            EnvKeyChange(key: "MAIL_PORT", value: "1025", isNew: false),
            EnvKeyChange(key: "MAIL_HOST", value: "127.0.0.1", isNew: false),
            EnvKeyChange(key: "MAIL_MAILER", value: "smtp", isNew: true),
            EnvKeyChange(key: "MAIL_USERNAME", value: "shop.test", isNew: true),
        ])
    }
}

final class ReceivedMailList: Sendable {
    private let messages = Mutex<[MailMessage]>([])

    func append(_ message: MailMessage) -> MailAcceptance {
        messages.withLock { $0.append(message) }
        return .accepted
    }

    var count: Int {
        messages.withLock { $0.count }
    }

    var users: [String?] {
        messages.withLock { $0.map(\.user) }
    }
}
