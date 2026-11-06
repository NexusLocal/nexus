import Foundation
import Testing
@testable import NexusMail

struct SendmailRequestTests {
    @Test func theArgumentsOfPHPGiveThePortAndReadTheHeaders() throws {
        let request = try SendmailRequest.parse(["-S", "127.0.0.1:11025", "-t", "-i", "-oi", "-fshop@example.com"])

        #expect(request == SendmailRequest(port: 11025, from: "shop@example.com", recipients: [], readsHeaders: true))
    }

    @Test func aValueCanFollowItsFlagAndARecipientCanFollowTheFlags() throws {
        let request = try SendmailRequest.parse(["-S127.0.0.1:1025", "-f", "a@b.test", "-F", "Shop", "--", "-odd@example.com"])

        #expect(request == SendmailRequest(port: 1025, from: "a@b.test", recipients: ["-odd@example.com"], readsHeaders: false))
    }

    @Test(arguments: [["-S", "smtp.example.com:25"], ["-S"], ["-bs", "-S", "127.0.0.1:1025"]])
    func aWrongArgumentIsRefused(_ arguments: [String]) {
        #expect(throws: SendmailError.self) {
            try SendmailRequest.parse(arguments)
        }
    }

    @Test func theRecipientsAndTheSenderComeFromTheHeaders() throws {
        let data = Data("""
            To: "Doe, John" <john@example.com>, jane@example.com
            Cc: undisclosed-recipients:;
            Bcc: audit@example.com (the audit),
             second@example.com
            From: Shop <shop@example.com>
            Subject: Hi

            To: body@example.com

            """.utf8)

        let message = try SendmailRequest(port: 1025).message(from: data, user: "/Sites/shop/public")

        #expect(message.recipients == ["john@example.com", "jane@example.com", "audit@example.com", "second@example.com"])
        #expect(message.from == "shop@example.com")
        #expect(message.user == "/Sites/shop/public")
        #expect(message.data == data)
    }

    @Test func aRecipientInTheArgumentsWinsOverTheHeadersWithoutT() throws {
        let data = Data("To: header@example.com\nSubject: Hi\n\nBody\n".utf8)

        let message = try SendmailRequest(port: 1025, recipients: ["argument@example.com"]).message(from: data, user: nil)

        #expect(message.recipients == ["argument@example.com"])
        #expect(message.from == "")
    }

    @Test func aMailWithoutARecipientIsRefused() {
        #expect(throws: SendmailError.self) {
            try SendmailRequest(port: 1025).message(from: Data("Subject: Hi\n\nBody\n".utf8), user: nil)
        }
    }
}

struct MailTagTests {
    private func router() -> MailRouter {
        let router = MailRouter(outbox: MailOutbox(folder: URL(filePath: "/nonexistent/outbox", directoryHint: .isDirectory)))
        router.setSiteFolders([
            "/Sites/shop": "shop.test",
            "/Sites/shop/.claude/worktrees/fix": "fix.shop.test",
            "/Sites/shop2": "shop2.test",
        ])
        return router
    }

    @Test func theFolderOfAScriptGivesTheHostOfTheSiteThatHoldsIt() {
        let router = router()

        #expect(router.tag(for: "/Sites/shop/public") == "shop.test")
        #expect(router.tag(for: "/Sites/shop") == "shop.test")
        #expect(router.tag(for: "/Sites/shop/.claude/worktrees/fix/public") == "fix.shop.test")
        #expect(router.tag(for: "/Sites/shop2/public") == "shop2.test")
    }

    @Test func aFolderOutsideTheSitesGivesNoTagAndAHostStaysAsItIs() {
        let router = router()

        #expect(router.tag(for: "/tmp") == nil)
        #expect(router.tag(for: "shop.test") == "shop.test")
        #expect(router.tag(for: nil) == nil)
    }
}

struct MailHTMLTests {
    private let style = MailHTML.defaultStyle

    @Test func theDefaultFontGoesFirstInTheHead() {
        let html = "<!DOCTYPE html><html lang=\"en\"><head><style>p{font-family:Georgia}</style></head><body><p>Hi</p></body></html>"

        #expect(MailHTML.withDefaultFont(html) == "<!DOCTYPE html><html lang=\"en\"><head>\(style)<style>p{font-family:Georgia}</style></head><body><p>Hi</p></body></html>")
    }

    @Test func aMailWithoutAHeadGetsTheFontAfterItsDoctypeOrBeforeItsText() {
        #expect(MailHTML.withDefaultFont("<!doctype html><p>Hi</p>") == "<!doctype html>\(style)<p>Hi</p>")
        #expect(MailHTML.withDefaultFont("<p>Hi</p>") == "\(style)<p>Hi</p>")
        #expect(MailHTML.withDefaultFont("<header>Top</header>") == "\(style)<header>Top</header>")
    }
}
