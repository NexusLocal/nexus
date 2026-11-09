import Foundation
import NexusCore

// Where an application sends its mail (Phase 3, 3c). real means that a mail can reach a real
// person, for example through a provider such as Postmark or through the sendmail of macOS. local
// means a log, an array or an SMTP server on this Mac that is not the receiver of nexusd.
public enum MailRoute: Sendable, Equatable {
    case nexus
    case local(String)
    case real(String)

    // The server or the provider that gets the mail. The inbox of Nexus has none.
    public var destination: String? {
        switch self {
        case .nexus: nil
        case .local(let place), .real(let place): place
        }
    }

    // The warning of the Site screen.
    public var warning: String? {
        guard case .real(let through) = self else {
            return nil
        }

        return "This site sends mail through \(through). So a mail can reach a real person."
    }
}

// The mail settings of a Laravel application, as the probe reads them from config/mail.php.
public enum LaravelMail {
    static let smtpMailer = "mail.mailers.smtp"
    static let localHosts = WorkspaceEnvPlan.localHosts

    // The transports that Laravel and its packages offer for a provider.
    static let providers = [
        "ses": "Amazon SES",
        "ses-v2": "Amazon SES",
        "postmark": "Postmark",
        "resend": "Resend",
        "mailgun": "Mailgun",
        "sendgrid": "SendGrid",
        "brevo": "Brevo",
        "mailjet": "Mailjet",
    ]

    public static func route(_ configuration: LaravelConfiguration, nexusPort: Int) -> MailRoute {
        let settings = configuration.settings
        let mailer = settings["mail.default"]?.value.description ?? "smtp"
        return route(mailer: mailer, settings: settings, nexusPort: nexusPort, depth: 0)
    }

    // A failover or round robin mailer sends through its first mailer while that mailer works.
    private static func route(mailer: String, settings: [String: ConfigSetting], nexusPort: Int, depth: Int) -> MailRoute {
        let path = "mail.mailers.\(mailer)"
        let transport = settings["\(path).transport"]?.value.description ?? mailer

        switch transport {
        case "smtp":
            let (host, port) = server(at: path, settings: settings)

            guard localHosts.contains(host) else {
                return .real(host.isEmpty ? "an SMTP server without a host" : host)
            }

            return port == nexusPort ? .nexus : .local("the SMTP server on port \(port.map(String.init) ?? "25")")
        case "sendmail":
            let command = settings["\(path).path"]?.value.description ?? "/usr/sbin/sendmail -bs -i"

            if command.contains("nexus"), command.contains("sendmail") {
                return .nexus
            }

            return command.hasPrefix("/usr/sbin/sendmail") || command.hasPrefix("sendmail") ? .real("the sendmail of macOS") : .local(command)
        case "log", "array":
            return .local(transport)
        case "failover", "roundrobin":
            guard depth < 3, let first = settings["\(path).mailers.0"]?.value.description else {
                return .local(transport)
            }

            return route(mailer: first, settings: settings, nexusPort: nexusPort, depth: depth + 1)
        default:
            return .real(providers[transport] ?? transport)
        }
    }

    // A URL in the settings of a mailer wins over its host and its port.
    private static func server(at path: String, settings: [String: ConfigSetting]) -> (host: String, port: Int?) {
        if let url = settings["\(path).url"]?.value, url != .null, !url.description.isEmpty, let components = URLComponents(string: url.description) {
            return (components.host ?? "", components.port)
        }

        let host = settings["\(path).host"]?.value.description ?? ""
        let port = settings["\(path).port"].flatMap { Int($0.value.description) }
        return (host, port)
    }

    // The receiver of nexusd has no TLS. A mailer with implicit TLS cannot reach it.
    public static func encryptionWarning(_ configuration: LaravelConfiguration) -> String? {
        let settings = configuration.settings
        let scheme = settings["\(smtpMailer).scheme"]?.value.description
        let encryption = settings["\(smtpMailer).encryption"]?.value

        guard scheme == "smtps" || encryption.map({ asksForTLS($0, laravelVersion: configuration.version) }) == true else {
            return nil
        }

        return "The smtp mailer of this site asks for TLS. The mail service of Nexus has no TLS. \"Send mail to Nexus\" turns TLS off for this site."
    }

    // SwiftMailer, the mailer of Laravel 8 and older, uses TLS for ssl and STARTTLS for tls. Without
    // STARTTLS on the server, each mail fails. Symfony Mailer of Laravel 9 and newer uses STARTTLS
    // only when the server offers it.
    static func asksForTLS(_ encryption: ConfigValue, laravelVersion: String) -> Bool {
        switch encryption.description.lowercased() {
        case "ssl":
            true
        case "tls":
            usesSwiftMailer(laravelVersion)
        default:
            false
        }
    }

    // The version of Lumen starts with its name, for example "Lumen (8.3.4) (Laravel Components ^8.0)".
    static func usesSwiftMailer(_ laravelVersion: String) -> Bool {
        guard let major = laravelVersion.firstMatch(of: /\d+/).flatMap({ Int($0.output) }) else {
            return false
        }

        return major < 9
    }

    // The keys that send the mail of the application to the receiver of nexusd, with the user as the
    // tag of each mail. Only a value that must change gets a key, so the .env gets no line that it
    // does not need. A setting that config/mail.php fixes cannot change. When such a setting sends
    // the mail elsewhere, problems names it. A fixed user name only loses the tag.
    public static func nexusKeys(_ configuration: LaravelConfiguration, user: String, nexusPort: Int) -> (keys: [String: String], problems: [String]) {
        let settings = configuration.settings
        var keys: [String: String] = [:]
        var problems: [String] = []
        let notNexus = "So the mail does not reach the mail service of Nexus."
        let noTLS = "config/mail.php gives the smtp mailer TLS. The mail service of Nexus has no TLS."

        func change(_ path: String, to value: String, when needed: (ConfigValue) -> Bool, problem: String?) {
            guard let setting = settings[path], needed(setting.value) else {
                return
            }

            guard setting.isFixed || !setting.exact else {
                setting.keys.forEach { keys[$0] = value }
                return
            }

            if let problem {
                problems.append(problem)
            }
        }

        let filled = { (value: ConfigValue) in value != .null && !value.description.isEmpty }

        // An application without the mail settings of Laravel sends no mail through Laravel.
        guard let mailer = settings["mail.default"]?.value.description else {
            return (keys, problems)
        }

        change("mail.default", to: "smtp", when: { $0.description != "smtp" }, problem: "config/mail.php gives the mailer \(mailer). \(notNexus)")

        guard settings["\(smtpMailer).transport"] != nil else {
            problems.append("config/mail.php has no smtp mailer. \(notNexus)")
            return (keys, problems)
        }

        let path = { (name: String) in "\(smtpMailer).\(name)" }
        let fixed = { (name: String) in settings[path(name)]?.value.description ?? "" }

        change(path("url"), to: "null", when: filled, problem: "config/mail.php gives the smtp mailer a fixed URL. \(notNexus)")
        change(path("host"), to: WorkspaceEnvPlan.serverHost, when: { $0.description != WorkspaceEnvPlan.serverHost }, problem: localHosts.contains(fixed("host")) ? nil : "config/mail.php gives the smtp mailer the host \(fixed("host")). \(notNexus)")
        change(path("port"), to: String(nexusPort), when: { $0.description != String(nexusPort) }, problem: "config/mail.php gives the smtp mailer the port \(fixed("port")). \(notNexus)")
        change(path("scheme"), to: "null", when: { $0.description == "smtps" }, problem: noTLS)
        change(path("encryption"), to: "null", when: { asksForTLS($0, laravelVersion: configuration.version) }, problem: noTLS)
        change(path("username"), to: user, when: { $0.description != user }, problem: nil)
        change(path("password"), to: "", when: filled, problem: nil)

        return (keys, problems)
    }
}

// A Node.js app has no configuration that Nexus can ask, so Nexus reads the keys of its env files.
public enum NodeMail {
    static let hostKeys = ["SMTP_HOST", "MAIL_HOST", "EMAIL_HOST"]
    static let portKeys = ["SMTP_PORT", "MAIL_PORT", "EMAIL_PORT"]
    static let userKeys = ["SMTP_USER", "SMTP_USERNAME", "MAIL_USER", "MAIL_USERNAME", "EMAIL_USER"]
    static let passwordKeys = ["SMTP_PASS", "SMTP_PASSWORD", "MAIL_PASS", "MAIL_PASSWORD", "EMAIL_PASSWORD"]
    static let secureKeys = ["SMTP_SECURE", "MAIL_SECURE", "EMAIL_SECURE"]
    static let providerKeys = [
        "RESEND_API_KEY": "Resend",
        "SENDGRID_API_KEY": "SendGrid",
        "POSTMARK_API_TOKEN": "Postmark",
        "POSTMARK_SERVER_TOKEN": "Postmark",
        "MAILGUN_API_KEY": "Mailgun",
        "MAILJET_API_KEY": "Mailjet",
        "BREVO_API_KEY": "Brevo",
        "SPARKPOST_API_KEY": "SparkPost",
    ]

    public static func route(_ values: [String: String], nexusPort: Int) -> MailRoute? {
        if let provider = providerKeys.keys.sorted().first(where: { values[$0]?.isEmpty == false }).flatMap({ providerKeys[$0] }) {
            return .real(provider)
        }

        guard let hostKey = hostKeys.first(where: { values[$0]?.isEmpty == false }), let host = values[hostKey] else {
            return nil
        }

        guard WorkspaceEnvPlan.localHosts.contains(host) else {
            return .real(host)
        }

        let port = portKeys.compactMap { values[$0].flatMap(Int.init) }.first
        return port == nexusPort ? .nexus : .local("the SMTP server on port \(port.map(String.init) ?? "25")")
    }

    // The SMTP keys of a workspace lead to the receiver of nexusd. A provider with an API key cannot
    // change, so it gives a warning.
    public static func nexusKeys(_ values: [String: String], user: String, nexusPort: Int) -> (keys: [String: String], warnings: [String]) {
        var keys: [String: String] = [:]

        if hostKeys.contains(where: { values[$0] != nil }) {
            for key in hostKeys where values[key] != nil {
                keys[key] = WorkspaceEnvPlan.serverHost
            }

            for key in portKeys where values[key] != nil {
                keys[key] = String(nexusPort)
            }

            for key in userKeys where values[key] != nil {
                keys[key] = user
            }

            for key in passwordKeys where values[key] != nil {
                keys[key] = ""
            }

            for key in secureKeys where values[key] != nil {
                keys[key] = "false"
            }
        }

        let providers = providerKeys.keys.sorted().filter { values[$0]?.isEmpty == false }
        let warnings = providers.map { "\($0) sends the mail of this workspace through \(providerKeys[$0] ?? $0). So a mail can reach a real person." }
        return (keys, warnings)
    }
}
