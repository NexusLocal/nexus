import Foundation
import Testing
@testable import NexusCore

struct WpressCipherTests {
    static let signature = "AAECAwQFBgcICQoLDA0OD4xRwy+CTishEu+sFms0htOKNWh1zC/kMPWSXCxUXYx+9P0SO6sUnRulsh3BNGc52/0W0DnURnQcC8F/PxrPBu/eCwgkCX6mu/MJxbkFNfko3xkOSuPxAOsYnhrVWSl0px71fF+BhZfjL7Pt9eOTtjXdKAN+Y92U/QA5vmViHEizHBS/74FocJ88hV6Z0mO6ig=="

    @Test func theKeyIsTheFirstSixteenBytesOfSHA1AndSixteenNULBytes() {
        let hex = WpressKey(password: "secret").bytes.map { String(format: "%02x", $0) }.joined()

        #expect(hex == "e5e9fa1ba31ecd1ae84f75caaa474f3a00000000000000000000000000000000")
    }

    @Test func theSignatureOfThePluginTakesOnlyItsPassword() {
        #expect(WpressCipher.isPassword("secret", of: Self.signature))
        #expect(!WpressCipher.isPassword("Secret", of: Self.signature))
        #expect(!WpressCipher.isPassword("", of: Self.signature))
        #expect(!WpressCipher.isPassword("secret ", of: Self.signature))
        #expect(!WpressCipher.isPassword("secret\n", of: Self.signature))
    }

    @Test func aSignatureThatIsNotBase64OrTooShortIsNoPassword() {
        let key = WpressKey(password: "secret")

        #expect(!WpressCipher.isPassword("secret", of: "not base64"))
        #expect(!WpressCipher.isPassword("secret", of: "AAAA"))
        #expect(WpressCipher.decrypt(Data(count: 17), key: key) == nil)
        #expect(WpressCipher.decrypt(Data(count: 31), key: key) == nil)
    }
}
