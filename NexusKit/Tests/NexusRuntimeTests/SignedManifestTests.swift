import CryptoKit
import Foundation
import Testing
@testable import NexusRuntime

struct SignedManifestTests {
    private let bytes = Data(#"{"schema": 1, "generated": "2026-11-25T12:00:00Z", "repository": "NexusLocal/binaries", "packages": []}"#.utf8)

    private func signed(_ manifest: Data, with key: Curve25519.Signing.PrivateKey, signature: Data? = nil) throws -> Data {
        let signature = try signature ?? key.signature(for: manifest)
        return try JSONSerialization.data(withJSONObject: ["manifest": manifest.base64EncodedString(), "signature": signature.base64EncodedString()])
    }

    private func publicKey(of key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    @Test func aManifestSignedWithAKnownKeyGivesItsExactBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = try signed(bytes, with: key)

        let verified = try SignedManifest.verifiedBytes(of: file, keys: [publicKey(of: Curve25519.Signing.PrivateKey()), publicKey(of: key)])

        #expect(verified == bytes)
        #expect(try Manifest.decode(from: verified).repository == "NexusLocal/binaries")
    }

    @Test func aChangedByteAnUnknownKeyOrAFileWithoutASignatureIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        var changed = bytes
        changed[changed.startIndex] ^= 1
        let changedFile = try signed(changed, with: key, signature: key.signature(for: bytes))
        let otherKeyFile = try signed(bytes, with: Curve25519.Signing.PrivateKey())

        #expect(throws: SignedManifest.Problem.invalidSignature) { try SignedManifest.verifiedBytes(of: changedFile, keys: [publicKey(of: key)]) }
        #expect(throws: SignedManifest.Problem.invalidSignature) { try SignedManifest.verifiedBytes(of: otherKeyFile, keys: [publicKey(of: key)]) }
        #expect(throws: SignedManifest.Problem.invalidSignature) { try SignedManifest.verifiedBytes(of: bytes, keys: [publicKey(of: key)]) }
    }

    @Test func theRefusalTellsThatTheInstalledPackagesKeepWorking() {
        #expect(SignedManifest.Problem.invalidSignature.description == "Nexus installs no packages now. The list of packages on GitHub has no valid signature. Your installed packages keep working.")
    }

    @Test func theAppTrustsOnlyTheTwoKeysOfTheOwner() throws {
        #expect(SignedManifest.ownerKeys == ["r059QQm/hcLCujZRF7W/I2w4i2Kt5hkQ+tD4dmt4Wzg=", "JuJIJF4NHOKAflXx3sOemb2VJgJ5P+qVuL41gJe6rPo="])

        for key in SignedManifest.ownerKeys {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Data(base64Encoded: key)))
        }
    }

    @Test func nexusReadsTheSignedManifestOfTheLatestRelease() {
        #expect(Manifest.defaultURL.lastPathComponent == "manifest.signed.json")
    }
}
