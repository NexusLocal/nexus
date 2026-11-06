import Foundation
import NexusCore
import Testing
@testable import NexusLaravel

struct LaravelMailTests {
    private func configuration(_ settings: [String: ConfigSetting]) -> LaravelConfiguration {
        LaravelConfiguration(version: "12.0.0", settings: settings, databaseConnections: [], redisConnections: [])
    }

    private func key(_ value: ConfigValue, _ name: String) -> ConfigSetting {
        ConfigSetting(value: value, keys: [name], exact: true)
    }

    // The smtp mailer of Laravel 12 with the values of a .env for Postmark.
    private var postmark: [String: ConfigSetting] {
        [
            "mail.default": key(.text("smtp"), "MAIL_MAILER"),
            "mail.mailers.smtp.transport": ConfigSetting(value: .text("smtp")),
            "mail.mailers.smtp.url": key(.null, "MAIL_URL"),
            "mail.mailers.smtp.scheme": key(.null, "MAIL_SCHEME"),
            "mail.mailers.smtp.host": key(.text("smtp.postmarkapp.com"), "MAIL_HOST"),
            "mail.mailers.smtp.port": key(.number(587), "MAIL_PORT"),
            "mail.mailers.smtp.username": key(.text("token"), "MAIL_USERNAME"),
            "mail.mailers.smtp.password": key(.text("secret"), "MAIL_PASSWORD"),
            "mail.mailers.sendmail.transport": ConfigSetting(value: .text("sendmail")),
            "mail.mailers.sendmail.path": key(.text("/usr/sbin/sendmail -bs -i"), "MAIL_SENDMAIL_PATH"),
        ]
    }

    @Test func aProviderHostIsARealRouteWithAWarning() {
        let route = LaravelMail.route(configuration(postmark), nexusPort: 1025)

        #expect(route == .real("smtp.postmarkapp.com"))
        #expect(route.warning == "This site sends mail through smtp.postmarkapp.com. So a mail can reach a real person.")
    }

    @Test func theKeysOfNexusChangeOnlyWhatMustChange() {
        let keys = LaravelMail.nexusKeys(configuration(postmark), user: "shop.test", nexusPort: 1025)

        #expect(keys.problems.isEmpty)
        #expect(keys.keys == ["MAIL_HOST": "127.0.0.1", "MAIL_PORT": "1025", "MAIL_USERNAME": "shop.test", "MAIL_PASSWORD": ""])
    }

    @Test func afterTheChangeTheSiteSendsToNexus() {
        var settings = postmark
        settings["mail.mailers.smtp.host"] = key(.text("127.0.0.1"), "MAIL_HOST")
        settings["mail.mailers.smtp.port"] = key(.number(1025), "MAIL_PORT")

        #expect(LaravelMail.route(configuration(settings), nexusPort: 1025) == .nexus)
        #expect(LaravelMail.route(configuration(settings), nexusPort: 11025) == .local("the SMTP server on port 1025"))
    }

    @Test(arguments: [
        ("sendmail", MailRoute.real("the sendmail of macOS")),
        ("log", MailRoute.local("log")),
        ("postmark", MailRoute.real("Postmark")),
    ])
    func eachMailerHasItsRoute(mailer: String, route: MailRoute) {
        var settings = postmark
        settings["mail.default"] = key(.text(mailer), "MAIL_MAILER")

        #expect(LaravelMail.route(configuration(settings), nexusPort: 1025) == route)
        #expect(LaravelMail.nexusKeys(configuration(settings), user: "shop.test", nexusPort: 1025).keys["MAIL_MAILER"] == "smtp")
    }

    @Test func aFailoverMailerSendsThroughItsFirstMailer() {
        var settings = postmark
        settings["mail.default"] = key(.text("failover"), "MAIL_MAILER")
        settings["mail.mailers.failover.transport"] = ConfigSetting(value: .text("failover"))
        settings["mail.mailers.failover.mailers.0"] = ConfigSetting(value: .text("smtp"))

        #expect(LaravelMail.route(configuration(settings), nexusPort: 1025) == .real("smtp.postmarkapp.com"))
    }

    @Test func aURLWinsOverTheHostAndGetsNull() {
        var settings = postmark
        settings["mail.mailers.smtp.url"] = key(.text("smtp://token:secret@smtp.resend.com:465"), "MAIL_URL")

        #expect(LaravelMail.route(configuration(settings), nexusPort: 1025) == .real("smtp.resend.com"))
        #expect(LaravelMail.nexusKeys(configuration(settings), user: "shop.test", nexusPort: 1025).keys["MAIL_URL"] == "null")
    }

    @Test func aFixedMailerOrHostIsAProblem() {
        var settings = postmark
        settings["mail.default"] = ConfigSetting(value: .text("postmark"))
        settings["mail.mailers.smtp.host"] = ConfigSetting(value: .text("smtp.postmarkapp.com"))

        let keys = LaravelMail.nexusKeys(configuration(settings), user: "shop.test", nexusPort: 1025)

        #expect(keys.problems == [
            "config/mail.php gives the mailer postmark. So the mail does not reach the mail service of Nexus.",
            "config/mail.php gives the smtp mailer the host smtp.postmarkapp.com. So the mail does not reach the mail service of Nexus.",
        ])
    }

    @Test func implicitTLSGetsAWarningAndIsTurnedOff() {
        var settings = postmark
        settings["mail.mailers.smtp.host"] = key(.text("127.0.0.1"), "MAIL_HOST")
        settings["mail.mailers.smtp.port"] = key(.number(1025), "MAIL_PORT")
        settings["mail.mailers.smtp.scheme"] = key(.text("smtps"), "MAIL_SCHEME")

        #expect(LaravelMail.encryptionWarning(configuration(settings)) != nil)
        #expect(LaravelMail.nexusKeys(configuration(settings), user: "shop.test", nexusPort: 1025).keys["MAIL_SCHEME"] == "null")
    }

    @Test func aWorkspaceGetsTheMailKeysWithItsHost() {
        let request = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/Sites/shop", workspaceFolder: "/w/fix", mysqlPorts: [], postgresqlPorts: [], redisPorts: [], smtpPort: 11025)

        let plan = WorkspaceEnvPlan(configuration: configuration(postmark), request: request)

        #expect(plan.mailKeys == ["MAIL_HOST": "127.0.0.1", "MAIL_PORT": "11025", "MAIL_USERNAME": "{host}", "MAIL_PASSWORD": ""])
        #expect(plan.isolatingKeys.isSuperset(of: ["MAIL_HOST", "MAIL_PORT", "MAIL_USERNAME"]))
        #expect(plan.warnings.isEmpty)
    }

    @Test func aWorkspaceWhoseMailCannotReachNexusGetsAWarningAndStaysIsolated() {
        var settings = postmark
        settings["mail.mailers.smtp.host"] = ConfigSetting(value: .text("smtp.postmarkapp.com"))
        let request = WorkspaceEnvRequest(workspace: "fix", mainFolder: "/Sites/shop", workspaceFolder: "/w/fix", mysqlPorts: [], postgresqlPorts: [], redisPorts: [], smtpPort: 11025)

        let plan = WorkspaceEnvPlan(configuration: configuration(settings), request: request)

        #expect(plan.problems.isEmpty)
        #expect(plan.warnings == ["config/mail.php gives the smtp mailer the host smtp.postmarkapp.com. So the mail does not reach the mail service of Nexus. A mail of this workspace can then reach a real person."])
    }
}

struct NodeMailTests {
    @Test func anAPIKeyOfAProviderIsARealRoute() {
        let route = NodeMail.route(["RESEND_API_KEY": "re_123", "SMTP_HOST": "127.0.0.1"], nexusPort: 1025)

        #expect(route == .real("Resend"))
    }

    @Test func theSMTPKeysOfAWorkspaceLeadToNexusAndAnAPIKeyGivesAWarning() {
        let values = ["SMTP_HOST": "smtp.sendgrid.net", "SMTP_PORT": "587", "SMTP_USER": "apikey", "SMTP_PASS": "x", "SENDGRID_API_KEY": "SG.1"]

        let mail = NodeMail.nexusKeys(values, user: "{host}", nexusPort: 11025)

        #expect(mail.keys == ["SMTP_HOST": "127.0.0.1", "SMTP_PORT": "11025", "SMTP_USER": "{host}", "SMTP_PASS": ""])
        #expect(mail.warnings == ["SENDGRID_API_KEY sends the mail of this workspace through SendGrid. So a mail can reach a real person."])
    }

    @Test func anAppWithoutMailKeysHasNoRoute() {
        #expect(NodeMail.route(["DATABASE_URL": "postgres://127.0.0.1:5432/app"], nexusPort: 1025) == nil)
    }
}
