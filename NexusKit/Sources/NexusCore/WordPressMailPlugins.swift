import Foundation

// Plugins that send the mail of WordPress themselves, through SMTP or the API of a provider (Phase 4,
// 3h). Such a plugin does not use sendmail_path. So the mail does not reach the inbox of Nexus. A
// copy of a production site can then mail a real customer. The key is the folder of the plugin.
public enum WordPressMailPlugins {
    public static let known: [String: String] = [
        "wp-mail-smtp": "WP Mail SMTP",
        "post-smtp": "Post SMTP",
        "fluent-smtp": "FluentSMTP",
        "easy-wp-smtp": "Easy WP SMTP",
        "smtp-mailer": "SMTP Mailer",
        "wp-mail-bank": "Mail Bank",
        "gosmtp": "GoSMTP",
        "suremails": "SureMail",
        "site-mailer": "Site Mailer",
        "wp-smtp": "WP SMTP",
        "wp-ses": "WP Offload SES",
        "wp-offload-ses": "WP Offload SES",
        "mailgun": "Mailgun",
        "sendgrid-email-delivery-simplified": "SendGrid",
        "postmark-approved-wordpress-plugin": "Postmark",
        "sparkpost": "SparkPost",
        "mailin": "Brevo",
        "mailjet-for-wordpress": "Mailjet",
        "mailersend-official-smtp-integration": "MailerSend",
        "smtp2go": "SMTP2GO",
        "mailpoet": "MailPoet",
    ]

    // WP Mail SMTP with the mailer "mail" uses the mail() of PHP. That mail reaches Nexus.
    public static let wpMailSMTP = "wp-mail-smtp"
    public static let phpMailer = "mail"

    // The folders of the plugins in the option active_plugins, a serialized array of PHP, for
    // example a:1:{i:0;s:29:"wp-mail-smtp/wp_mail_smtp.php";}. The option active_sitewide_plugins
    // of a multisite holds the paths as keys.
    public static func activeFolders(in serialized: String) -> [String] {
        serialized.matches(of: /s:\d+:"([^"]+\.php)"/).compactMap { match in
            String(match.1).split(separator: "/").first.map(String.init)
        }
    }

    // The mailer in the option wp_mail_smtp, for example s:4:"mail";a:2:{s:6:"mailer";s:4:"smtp";...}.
    public static func wpMailSMTPMailer(in serialized: String) -> String? {
        serialized.firstMatch(of: /s:6:"mailer";s:\d+:"([^"]*)"/).map { String($0.1) }
    }

    // A plugin in mu-plugins is always active. It is a file or a folder with the name of the plugin.
    public static func mustUseFolders(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.filter { known[$0] != nil }
    }

    public enum SourceKind: String, Codable, Sendable {
        case plugin
        case networkPlugin = "network_plugin"
        case mustUse = "must_use"
        case theme
        case other
    }

    // The folders of a site as WordPress gives them: WP_PLUGIN_DIR, WPMU_PLUGIN_DIR and the root of
    // the themes. Each path is a real path.
    public struct Folders: Codable, Sendable, Equatable {
        public let plugins: String
        public let mustUse: String
        public let themes: String
        public let root: String

        public init(plugins: String, mustUse: String, themes: String, root: String) {
            self.plugins = plugins
            self.mustUse = mustUse
            self.themes = themes
            self.root = root
        }
    }

    // The plugin, the mu-plugin or the theme that holds a file of PHP. A file of WordPress itself
    // gives nil. Another file gives its path below the folder of the site, for example vendor/x.php.
    public static func source(ofFile path: String, in folders: Folders) -> (kind: SourceKind, folder: String)? {
        let below = { (folder: String) -> String? in
            path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : nil
        }

        if let rest = below(folders.plugins) {
            return (.plugin, String(rest.split(separator: "/").first ?? Substring(rest)))
        }

        if let rest = below(folders.mustUse) {
            return (.mustUse, (String(rest.split(separator: "/").first ?? Substring(rest)) as NSString).deletingPathExtension)
        }

        if let rest = below(folders.themes) {
            return (.theme, String(rest.split(separator: "/").first ?? Substring(rest)))
        }

        if path.contains("/wp-includes/") || path.contains("/wp-admin/") {
            return nil
        }

        return (.other, below(folders.root) ?? path)
    }
}
