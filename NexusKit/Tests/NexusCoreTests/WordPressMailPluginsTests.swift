import Foundation
import Testing
@testable import NexusCore

struct WordPressMailPluginsTests {
    @Test func theFoldersOfTheActivePluginsComeFromTheSerializedOption() {
        let active = #"a:3:{i:0;s:19:"akismet/akismet.php";i:1;s:29:"wp-mail-smtp/wp_mail_smtp.php";i:2;s:9:"hello.php";}"#
        let sitewide = #"a:1:{s:23:"post-smtp/postman-smtp.php";i:1700000000;}"#

        #expect(WordPressMailPlugins.activeFolders(in: active) == ["akismet", "wp-mail-smtp", "hello.php"])
        #expect(WordPressMailPlugins.activeFolders(in: sitewide) == ["post-smtp"])
        #expect(WordPressMailPlugins.activeFolders(in: "a:0:{}").isEmpty)
    }

    @Test func theMailerOfWPMailSMTPComesFromItsOption() {
        let smtp = #"a:2:{s:4:"mail";a:3:{s:10:"from_email";s:16:"shop@example.com";s:6:"mailer";s:8:"postmark";s:11:"return_path";b:0;}s:4:"smtp";a:1:{s:4:"host";s:0:"";}}"#
        let php = #"a:1:{s:4:"mail";a:1:{s:6:"mailer";s:4:"mail";}}"#

        #expect(WordPressMailPlugins.wpMailSMTPMailer(in: smtp) == "postmark")
        #expect(WordPressMailPlugins.wpMailSMTPMailer(in: php) == WordPressMailPlugins.phpMailer)
        #expect(WordPressMailPlugins.wpMailSMTPMailer(in: "a:0:{}") == nil)
    }

    @Test func aFileOfPHPBelongsToItsPluginThemeOrMuPlugin() {
        let folders = WordPressMailPlugins.Folders(plugins: "/Users/me/themes/site/wp-content/plugins", mustUse: "/Users/me/themes/site/wp-content/mu-plugins", themes: "/Users/me/themes/site/wp-content/themes", root: "/Users/me/themes/site")

        #expect(WordPressMailPlugins.source(ofFile: "/Users/me/themes/site/wp-content/plugins/fluent-smtp/app/Hooks.php", in: folders)! == (.plugin, "fluent-smtp"))
        #expect(WordPressMailPlugins.source(ofFile: "/Users/me/themes/site/wp-content/mu-plugins/mailer.php", in: folders)! == (.mustUse, "mailer"))
        #expect(WordPressMailPlugins.source(ofFile: "/Users/me/themes/site/wp-content/themes/shop/functions.php", in: folders)! == (.theme, "shop"))
        #expect(WordPressMailPlugins.source(ofFile: "/Users/me/themes/site/vendor/mailer/send.php", in: folders)! == (.other, "vendor/mailer/send.php"))
        #expect(WordPressMailPlugins.source(ofFile: "/Users/me/themes/site/wp-includes/pluggable.php", in: folders) == nil)
    }

    @Test func aKnownPluginInMuPluginsIsActive() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus mu-plugins \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "fluent-smtp"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: folder.appending(path: "mailgun.php"))
        try Data("<?php".utf8).write(to: folder.appending(path: "cache.php"))

        #expect(Set(WordPressMailPlugins.mustUseFolders(in: folder)) == ["fluent-smtp", "mailgun"])
    }
}
