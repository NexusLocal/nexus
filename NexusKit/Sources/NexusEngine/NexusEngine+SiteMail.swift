import Foundation
import NexusCore
import NexusIPC
import NexusLaravel
import NexusRuntime

// Where the main checkout of a site sends its mail (Phase 3, 3c). A site without Laravel sends
// mail() through nexus sendmail, the sendmail_path of the PHP of Nexus. A Laravel site uses its
// mailer, so the probe reads config/mail.php. A Node.js app names its mail server in its env files.
extension NexusEngine {
    func siteMail(host: String) async -> SiteMail {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.host == host }) else {
            return SiteMail(sendsToNexus: false, problem: "Nexus has no site \(host).")
        }

        var canRestore = false

        do {
            let port = try await smtpPort(in: state)

            if site.kind == .node {
                let folder = RealPath.of(URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory))
                let values = try Self.nodeEnvFiles(in: folder).reduce(into: [String: String]()) { all, file in
                    all.merge(EnvFile.values(in: file.text)) { _, later in later }
                }
                let route = NodeMail.route(values, nexusPort: port)
                return SiteMail(sendsToNexus: route == .nexus, warning: route?.warning, destination: route?.destination)
            }

            if site.kind == .php, PHPProject.type(of: site).isWordPress {
                return await wordPressMail(host: site.host)
            }

            guard site.kind == .php, let root = laravelRoot(of: site) else {
                return SiteMail(sendsToNexus: site.kind == .php)
            }

            // The probe does not need the text of the .env. So a .env that is no UTF-8 text still
            // gives the route.
            let folder = RealPath.of(root)
            let text = (try? Self.envText(of: "\(folder)/.env")) ?? ""
            canRestore = EnvRewrite.hasOldValues(in: text)

            let configuration = try await self.configuration(of: site, folder: folder)
            let route = LaravelMail.route(configuration, nexusPort: port)
            let keys = LaravelMail.nexusKeys(configuration, user: site.host, nexusPort: port)
            let warning = route.warning ?? (route == .nexus ? LaravelMail.encryptionWarning(configuration) : nil)
            let sendsToNexus = route == .nexus && warning == nil
            let canSendToNexus = !keys.keys.isEmpty && keys.problems.isEmpty

            return SiteMail(
                sendsToNexus: sendsToNexus,
                warning: warning,
                canSendToNexus: canSendToNexus,
                destination: route.destination,
                changes: Self.mailChanges(keys.keys, in: text),
                canRestore: canRestore,
                missesTag: sendsToNexus && canSendToNexus && LaravelMail.changesUserName(keys.keys, in: configuration),
                tagDeclined: state.declinedMailTags.contains(site.host)
            )
        } catch {
            return SiteMail(sendsToNexus: false, problem: ErrorText.plain(error), canRestore: canRestore)
        }
    }

    // The keys go into the .env of the main checkout, with the host of the site as the user name.
    // So each mail gets the host as its tag. The old line of each key stays as a comment line.
    // restoreMailSettings puts it back from there. The other lines stay.
    func sendMailToNexus(host: String) async throws -> String {
        let state = await stateStore.current()
        let (site, folder) = try laravelSite(host, in: state, else: "PHP of Nexus sends the mail() of this site to the mail service already.")
        let configuration = try await self.configuration(of: site, folder: folder)
        let nexus = LaravelMail.nexusKeys(configuration, user: site.host, nexusPort: try await smtpPort(in: state))

        guard nexus.problems.isEmpty else {
            throw RuntimeError.unsupported("Nexus did not change the .env of \(host). \(nexus.problems.joined(separator: " "))")
        }

        guard !nexus.keys.isEmpty else {
            return "\(host) sends its mail to the mail service of Nexus already."
        }

        let file = try envFile(in: folder, of: host)
        try Self.write(EnvRewrite.applyKeepingOldValues(to: try Self.envText(of: file), keys: nexus.keys), to: file)
        try await stateStore.update { $0.declinedMailTags.remove(host) }

        let changed = EnglishList.joined(nexus.keys.keys.sorted())
        return "\(host) sends its mail to the mail service of Nexus now. Nexus changed \(changed) in its .env. The old values stay there as comment lines. A queue worker reads the new values after a restart."
    }

    // The way back of "Send mail to Nexus". Each old line comes back. Each line that Nexus added
    // goes out. The comment lines of Nexus go out too.
    func restoreMailSettings(host: String) async throws -> String {
        let (_, folder) = try laravelSite(host, in: await stateStore.current(), else: "Nexus did not change its mail settings.")
        let file = try envFile(in: folder, of: host)
        let restore = EnvRewrite.restoringOldValues(in: try Self.envText(of: file))

        guard !restore.restored.isEmpty || !restore.removed.isEmpty else {
            throw RuntimeError.unsupported("The .env of \(host) has no old mail settings from before Nexus.")
        }

        try Self.write(restore.text, to: file)
        try await stateStore.update { $0.declinedMailTags.insert(host) }

        let restored = restore.restored.isEmpty ? [] : ["Nexus put back the old values of \(EnglishList.joined(restore.restored)) in its .env."]
        let removed = restore.removed.isEmpty ? [] : ["Nexus removed \(EnglishList.joined(restore.removed)) from its .env."]
        return (["\(host) uses its old mail settings again."] + restored + removed + ["A queue worker reads the old values after a restart."]).joined(separator: " ")
    }

    // The keys in the order of their lines in the .env. A new key comes last, as
    // EnvRewrite.applyKeepingOldValues adds it.
    static func mailChanges(_ keys: [String: String], in text: String) -> [EnvKeyChange] {
        var firstLine: [String: Int] = [:]

        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            for key in EnvFile.values(in: line).keys where firstLine[key] == nil {
                firstLine[key] = index
            }
        }

        return keys
            .sorted { (firstLine[$0.key] ?? .max, $0.key) < (firstLine[$1.key] ?? .max, $1.key) }
            .map { EnvKeyChange(key: $0.key, value: $0.value, isNew: firstLine[$0.key] == nil) }
    }

    private func laravelSite(_ host: String, in state: EngineState, else reason: String) throws -> (site: Site, folder: String) {
        guard let site = resolvedSites(state).map(\.site).first(where: { $0.host == host }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        guard site.kind == .php, let root = laravelRoot(of: site) else {
            throw RuntimeError.unsupported("\(host) is no Laravel application. \(reason)")
        }

        return (site, RealPath.of(root))
    }

    private func envFile(in folder: String, of host: String) throws -> String {
        let file = "\(folder)/.env"

        guard FileManager.default.fileExists(atPath: file) else {
            throw RuntimeError.unsupported("\(host) has no .env file, so Nexus cannot change its mail settings.")
        }

        return file
    }

    // wp-config.php often has 0600 or 0640. It keeps them.
    static func write(_ text: String, to file: String) throws {
        try FileText.write(text, to: URL(filePath: file))
    }

    private func laravelRoot(of site: Site) -> URL? {
        LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory))
    }
}
