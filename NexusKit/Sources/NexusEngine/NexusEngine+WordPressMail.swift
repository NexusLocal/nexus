import Foundation
import NexusCore
import NexusIPC
import NexusRuntime

// A WordPress site sends its mail through sendmail_path to the inbox of Nexus, unless code of the
// site sends it itself (Phase 4, 3h). The general check finds that code: WP-CLI loads the site and
// asks which code changes the way that WordPress sends mail. It finds an unknown plugin, a
// mu-plugin, a theme or another file too. During the check WP-Cron does not run and wp_mail() sends
// nothing. So a due event cannot mail a customer while the check runs. Without WP-CLI, Nexus checks
// only the known plugins in the database. A check that fails gives no green state. Without a
// wp-config.php WordPress does not run. So it sends no mail either.
extension NexusEngine {
    func wordPressMail(host: String) async -> SiteMail {
        switch await mailCheck(host: host) {
        case .unknown(let reason):
            return SiteMail(sendsToNexus: false, problem: "Nexus cannot check the mail code of this site. \(reason) A plugin can then send mail to real people.")
        case .checked(let found) where found.plugins.isEmpty:
            return SiteMail(sendsToNexus: true)
        case .checked(let found):
            let names = found.plugins.map { plugin in
                plugin.folder == WordPressMailPlugins.wpMailSMTP ? "\(plugin.name) (\(Self.mailerTitle(found.mailer)))" : plugin.name
            }

            return SiteMail(sendsToNexus: false, warning: Self.mailPluginWarning(found.plugins), destination: names.joined(separator: ", "), mailPlugins: found.plugins)
        }
    }

    // The user confirmed these plugins. A plugin that does not send mail now stays as it is.
    func turnOffMailPlugins(host: String, folders: [String]) async throws -> String {
        guard case .checked(let found) = await mailCheck(host: host), let core = found.core else {
            throw RuntimeError.unsupported("Nexus cannot check the mail code of \(host) now.")
        }

        let plugins = found.plugins.filter { folders.contains($0.folder) && $0.canTurnOff }

        guard !plugins.isEmpty, plugins.count == folders.count else {
            throw RuntimeError.unsupported("The mail plugins of \(host) changed. Open the Site screen again.")
        }

        let single = plugins.filter { $0.kind == .plugin }
        let network = plugins.filter { $0.kind == .networkPlugin }
        var turnedOff: [String] = []

        for (group, extra) in [(single, [String]()), (network, ["--network"])] where !group.isEmpty {
            let names = EnglishList.joined(group.map(\.name))
            let done = turnedOff.isEmpty ? "" : " Nexus turned off \(EnglishList.joined(turnedOff)) already."
            let wpCLI = try await wpCLICommand(in: core, failure: "WP-CLI did not turn off \(names).\(done)")
            _ = try await wpCLI(["plugin", "deactivate"] + extra + group.map(\.folder))
            turnedOff += group.map(\.name)
        }

        let rest = found.plugins.filter { !$0.canTurnOff }
        let restText = rest.isEmpty ? "" : " \(Self.capitalized(EnglishList.joined(rest.map(\.description)))) can still send mail itself."
        return "Nexus turned off \(EnglishList.joined(turnedOff)) in this copy of \(host). The live site does not change.\(restText)"
    }

    struct MailSources {
        let plugins: [WordPressMailPlugin]
        let mailer: String
        let core: URL?
    }

    private enum MailCheckResult {
        case checked(MailSources)
        case unknown(String)
    }

    private func mailCheck(host: String) async -> MailCheckResult {
        let target: WordPressTarget

        do {
            target = try await wordPressTarget(host)
        } catch {
            return .unknown(ErrorText.plain(error))
        }

        guard let core = target.core, target.config != nil else {
            return .checked(MailSources(plugins: [], mailer: WordPressMailPlugins.phpMailer, core: target.core))
        }

        let wpCLI: (@Sendable ([String]) async throws -> String)?

        do {
            wpCLI = try await wpCLICommand(in: core, failure: "WP-CLI did not load the site.")
        } catch {
            wpCLI = nil
        }

        guard let wpCLI else {
            return await listCheck(target)
        }

        do {
            let answer = try await generalMailCheck(wpCLI)
            return .checked(Self.sources(of: answer, core: core))
        } catch {
            return .unknown(ErrorText.plain(error))
        }
    }

    // A plugin sends mail itself in one of four ways. It sets another mailer than mail() in
    // phpmailer_init, for example SMTP. It replaces the global PHPMailer. It defines wp_mail()
    // itself. Or it answers pre_wp_mail and sends through an API. The check runs each callback of
    // phpmailer_init on a new PHPMailer, which sends nothing. It cannot run pre_wp_mail, because a
    // callback can send there. So code on that filter is uncertain.
    static func sources(of answer: GeneralMailCheck, core: URL) -> MailSources {
        let sitewide = Set(answer.sitewide.compactMap { $0.split(separator: "/").first.map(String.init) })
        var found: [String: WordPressMailPlugin] = [:]

        let add = { (file: String?, certain: Bool) in
            guard let file, let source = WordPressMailPlugins.source(ofFile: file, in: answer.folders) else {
                return
            }

            if source.folder == WordPressMailPlugins.wpMailSMTP, answer.smtpMailer == WordPressMailPlugins.phpMailer, !answer.changers.contains(file) {
                return
            }

            let kind = source.kind == .plugin && sitewide.contains(source.folder) ? .networkPlugin : source.kind
            let plugin = WordPressMailPlugin(folder: source.folder, name: WordPressMailPlugins.known[source.folder] ?? source.folder, kind: kind, certain: certain)

            if found[source.folder]?.certain != true {
                found[source.folder] = plugin
            }
        }

        answer.changers.forEach { add($0, true) }
        [answer.wpMail, answer.phpmailer].forEach { add($0, true) }
        answer.preWPMail.forEach { add($0, false) }

        return MailSources(plugins: found.values.sorted { $0.folder < $1.folder }, mailer: answer.smtpMailer ?? WordPressMailPlugins.phpMailer, core: core)
    }

    private func generalMailCheck(_ wpCLI: @escaping @Sendable ([String]) async throws -> String) async throws -> GeneralMailCheck {
        let output = try await Self.evalAnswer(wpCLI, arguments: ["--exec=\(Self.mailCheckSetup)", "eval", Self.mailCheckSource], separator: Self.mailCheckSeparator, failure: "WP-CLI did not load the site")

        guard let answer = try? JSONDecoder().decode(GeneralMailCheck.self, from: Data(output.utf8)) else {
            throw RuntimeError.unsupported("Nexus cannot read the answer of WP-CLI.")
        }

        return answer
    }

    // Without WP-CLI: the known plugins in active_plugins and active_sitewide_plugins, and in
    // mu-plugins. It needs the database on a Nexus instance.
    private func listCheck(_ target: WordPressTarget) async -> MailCheckResult {
        guard let config = target.config, let name = config.database, let prefix = config.safeTablePrefix,
              let port = config.address?.localPort, let instance = await mysqlInstances().first(where: { $0.port == port && $0.running }),
              let (_, client, work) = try? await runningClient(instance.id) else {
            return .unknown("Nexus needs WP-CLI, or the database of the site on a running Nexus instance. Install WP-CLI on the Packages screen.")
        }

        defer { try? FileManager.default.removeItem(at: work) }

        let option = { (option: String) async -> String in
            let rows = (try? await client.rows("SELECT option_value FROM \(Self.sqlName(name)).\(Self.sqlName("\(prefix)options")) WHERE option_name = \(Self.sqlText(option))")) ?? []
            return rows.first?.first ?? ""
        }
        let sitewideText = ((try? await client.rows("SELECT meta_value FROM \(Self.sqlName(name)).\(Self.sqlName("\(prefix)sitemeta")) WHERE meta_key = 'active_sitewide_plugins'")) ?? []).first?.first ?? ""
        let sitewide = Set(WordPressMailPlugins.activeFolders(in: sitewideText))
        let active = Set(WordPressMailPlugins.activeFolders(in: await option("active_plugins"))).union(sitewide)
        let mailer = WordPressMailPlugins.wpMailSMTPMailer(in: await option("wp_mail_smtp")) ?? WordPressMailPlugins.phpMailer
        let contentFolder = target.type == .bedrock ? target.project.appending(path: "web/app") : (target.core ?? target.project).appending(path: "wp-content")
        let mustUse = Set(WordPressMailPlugins.mustUseFolders(in: contentFolder.appending(path: "mu-plugins")))

        let plugins = active.union(mustUse)
            .filter { WordPressMailPlugins.known[$0] != nil }
            .filter { $0 != WordPressMailPlugins.wpMailSMTP || mailer != WordPressMailPlugins.phpMailer }
            .sorted()
            .map { folder in
                let kind: WordPressMailPlugins.SourceKind = active.contains(folder) ? (sitewide.contains(folder) ? .networkPlugin : .plugin) : .mustUse
                return WordPressMailPlugin(folder: folder, name: WordPressMailPlugins.known[folder] ?? folder, kind: kind)
            }

        return .checked(MailSources(plugins: plugins, mailer: mailer, core: target.core))
    }

    struct GeneralMailCheck: Decodable {
        let folders: WordPressMailPlugins.Folders
        let sitewide: [String]
        let smtpMailer: String?
        let changers: [String]
        let preWPMail: [String]
        let wpMail: String?
        let phpmailer: String?
    }

    static let mailCheckTimeout: Duration = .seconds(20)
    static let mailCheckSeparator = "@@nexus-mail-check@@"

    // Runs before WordPress loads. A filter in $wp_filter before plugin.php becomes a normal filter.
    // No cron job runs: the list of ready jobs is empty. A constant such as DISABLE_WP_CRON does not
    // work here, because Bedrock refuses a constant that is defined before its configuration.
    static let mailCheckSetup = "function nexus_block_mail() { return false; } function nexus_no_cron_jobs() { return array(); } $GLOBALS['wp_filter']['pre_wp_mail'][PHP_INT_MIN][] = array('function' => 'nexus_block_mail', 'accepted_args' => 1); $GLOBALS['wp_filter']['pre_get_ready_cron_jobs'][PHP_INT_MIN][] = array('function' => 'nexus_no_cron_jobs', 'accepted_args' => 1);"

    static let mailCheckSource = #"""
    $nexus_real = function ($path) {
        return is_string($path) && $path !== '' ? (realpath($path) ?: $path) : null;
    };

    $nexus_file = function ($callback) use ($nexus_real) {
        try {
            if (is_string($callback) && strpos($callback, '::') !== false) {
                $callback = explode('::', $callback, 2);
            }

            if (is_array($callback)) {
                return $nexus_real((new ReflectionMethod(is_object($callback[0]) ? get_class($callback[0]) : $callback[0], $callback[1]))->getFileName());
            }

            if ($callback instanceof Closure || is_string($callback)) {
                return $nexus_real((new ReflectionFunction($callback))->getFileName());
            }

            if (is_object($callback)) {
                return $nexus_real((new ReflectionMethod($callback, '__invoke'))->getFileName());
            }
        } catch (Throwable $error) {
        }

        return null;
    };

    global $wp_filter, $phpmailer;

    if (! class_exists('PHPMailer\\PHPMailer\\PHPMailer')) {
        require_once ABSPATH . WPINC . '/PHPMailer/PHPMailer.php';
        require_once ABSPATH . WPINC . '/PHPMailer/Exception.php';
    }

    $nexus_changers = [];
    $nexus_pre = [];

    foreach (isset($wp_filter['phpmailer_init']) ? $wp_filter['phpmailer_init']->callbacks : [] as $nexus_entries) {
        foreach ($nexus_entries as $nexus_entry) {
            $nexus_mailer = new PHPMailer\PHPMailer\PHPMailer(true);
            $nexus_mailer->isMail();

            try {
                call_user_func($nexus_entry['function'], $nexus_mailer);
            } catch (Throwable $error) {
            }

            $nexus_safe = $nexus_mailer->Mailer === 'mail'
                || ($nexus_mailer->Mailer === 'sendmail' && $nexus_mailer->Sendmail === ini_get('sendmail_path'));

            if (! $nexus_safe) {
                $nexus_changers[] = $nexus_file($nexus_entry['function']);
            }
        }
    }

    foreach (isset($wp_filter['pre_wp_mail']) ? $wp_filter['pre_wp_mail']->callbacks : [] as $nexus_entries) {
        foreach ($nexus_entries as $nexus_entry) {
            if ($nexus_entry['function'] !== 'nexus_block_mail') {
                $nexus_pre[] = $nexus_file($nexus_entry['function']);
            }
        }
    }

    $nexus_smtp = null;

    try {
        if (class_exists('\\WPMailSMTP\\Options')) {
            $nexus_smtp = (string) \WPMailSMTP\Options::init()->get('mail', 'mailer');
        }
    } catch (Throwable $error) {
    }

    echo "\n@@nexus-mail-check@@" . json_encode([
        'folders' => [
            'plugins' => $nexus_real(WP_PLUGIN_DIR) ?? WP_PLUGIN_DIR,
            'mustUse' => $nexus_real(WPMU_PLUGIN_DIR) ?? WPMU_PLUGIN_DIR,
            'themes' => $nexus_real(get_theme_root()) ?? get_theme_root(),
            'root' => $nexus_real(ABSPATH) ?? ABSPATH,
        ],
        'sitewide' => is_multisite() ? array_map('strval', array_keys((array) get_site_option('active_sitewide_plugins', []))) : [],
        'smtpMailer' => $nexus_smtp,
        'changers' => array_values(array_filter($nexus_changers)),
        'preWPMail' => array_values(array_filter($nexus_pre)),
        'wpMail' => $nexus_real((new ReflectionFunction('wp_mail'))->getFileName()),
        'phpmailer' => isset($phpmailer) && is_object($phpmailer) ? $nexus_real((new ReflectionClass($phpmailer))->getFileName()) : null,
    ]) . "@@nexus-mail-check@@\n";
    """#

    // Certain code sends each mail itself. Code on pre_wp_mail can send each mail itself, or it can
    // block each mail. Nexus turns off only a plugin with certain code.
    static func mailPluginWarning(_ plugins: [WordPressMailPlugin]) -> String {
        let certain = plugins.filter(\.certain)
        let uncertain = plugins.filter { !$0.certain }
        var parts: [String] = []

        if !certain.isEmpty {
            let one = certain.count == 1
            parts.append("\(capitalized(EnglishList.joined(certain.map(\.description)))) \(one ? "sends" : "send") each mail \(one ? "itself" : "themselves") and not through Nexus. So a mail can reach a real person.")
        }

        if !uncertain.isEmpty {
            parts.append("\(capitalized(EnglishList.joined(uncertain.map(\.description)))) can send each mail \(uncertain.count == 1 ? "itself" : "themselves"). Check this code.")
        }

        let turnOff = plugins.filter(\.canTurnOff)

        if !turnOff.isEmpty {
            parts.append("Turn off the \(turnOff.count == 1 ? "plugin" : "plugins") in this copy of the site.")
        }

        if certain.contains(where: { !$0.canTurnOff }) {
            parts.append("Nexus cannot turn off a theme, a file in mu-plugins or another file. Change that code in this copy of the site.")
        }

        return parts.joined(separator: " ")
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func mailerTitle(_ mailer: String) -> String {
        ["smtp": "SMTP", "sendgrid": "SendGrid", "sendinblue": "Brevo", "smtpcom": "SMTP.com", "amazonses": "Amazon SES", "gmail": "Gmail", "outlook": "Outlook", "zoho": "Zoho"][mailer] ?? mailer.capitalized
    }
}
