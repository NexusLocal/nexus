import Foundation
import Testing
@testable import NexusIPC

struct SiteMailTests {
    @Test func theAnswerOfAnOlderNexusdHasNoChangesAndNoWayBack() throws {
        let older = Data(#"{"sendsToNexus":false,"canSendToNexus":true,"destination":"smtp.postmarkapp.com"}"#.utf8)

        let mail = try NexusMessageCoding.decode(SiteMail.self, from: older)

        #expect(mail == SiteMail(sendsToNexus: false, canSendToNexus: true, destination: "smtp.postmarkapp.com"))
    }

    @Test func theChangesAndTheWayBackGoThroughTheCoding() throws {
        let mail = SiteMail(sendsToNexus: true, changes: [EnvKeyChange(key: "MAIL_PORT", value: "1025", isNew: false)], canRestore: true)

        #expect(try NexusMessageCoding.decode(SiteMail.self, from: NexusMessageCoding.encode(mail)) == mail)
    }
}
