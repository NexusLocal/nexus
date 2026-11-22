import Foundation
import Testing
@testable import NexusMongoDB

struct ScramSHA256Tests {
    private let nonce = "rOprNGfwEbeRWgbNEkqO"
    private let serverMessage = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    @Test func theMessagesAreThoseOfTheExampleInRFC7677() throws {
        let scram = ScramSHA256(user: "user", password: "pencil", nonce: nonce)
        let answer = try scram.answer(to: serverMessage)

        #expect(scram.firstMessage == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        #expect(answer.message == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        #expect(answer.serverSignature == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func aUserWithReservedCharactersIsEscaped() {
        #expect(ScramSHA256(user: "a=b,c", password: "", nonce: "n").firstMessage == "n,,n=a=3Db=2Cc,r=n")
    }

    @Test(arguments: [
        "r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=rOprNGfwEbeRWgbNEkqOx,s=,i=4096",
        "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1",
        "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=99999999",
        "e=other-error",
        "",
    ])
    func aWrongServerMessageGivesAnError(message: String) {
        #expect(throws: MongoDBError.loginFailed) {
            try ScramSHA256(user: "user", password: "pencil", nonce: nonce).answer(to: message)
        }
    }

    @Test func eachLoginHasItsOwnNonce() {
        let first = ScramSHA256(user: "user", password: "pencil").firstMessage
        let second = ScramSHA256(user: "user", password: "pencil").firstMessage

        #expect(first != second)
        #expect(!first.dropFirst("n,,n=user,r=".count).contains(","))
    }
}
