import Foundation
import Testing
@testable import NexusCommands

struct BackupPasswordTests {
    @Test func oneLineEndGoesFromTheInput() {
        #expect(BackupPassword.fromInput(Data("secret\n".utf8)) == "secret")
        #expect(BackupPassword.fromInput(Data("secret\r\n".utf8)) == "secret")
        #expect(BackupPassword.fromInput(Data("secret\n\n".utf8)) == "secret\n")
        #expect(BackupPassword.fromInput(Data(" pass word ".utf8)) == " pass word ")
    }
}
