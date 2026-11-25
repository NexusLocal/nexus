import CryptoKit
import Foundation

// The manifest with the signature of the owner (group 8, docs/group8-signed-packages.md). The
// owner signs the bytes of manifest.json on the Mac of the owner with sign_update of Sparkle, an
// Ed25519 signature. The file holds those bytes in base64. So the check reads the exact bytes that
// the owner signed, and no step writes the JSON again before it.
public struct SignedManifest: Decodable, Sendable {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case invalidSignature
        case older(than: Date)

        public var description: String {
            switch self {
            case .invalidSignature:
                "Nexus installs no packages now. The list of packages on GitHub has no valid signature. Your installed packages keep working."
            case .older:
                "Nexus installs no packages now. The list of packages on GitHub is older than the list that Nexus read before. Your installed packages keep working."
            }
        }
    }

    // The main key is in the Keychain of the Mac of the owner. The backup key is in the password
    // manager of the owner. It signs only when the main key is lost, and the next release of the
    // app then gets a new pair.
    public static let ownerKeys = [
        "r059QQm/hcLCujZRF7W/I2w4i2Kt5hkQ+tD4dmt4Wzg=",
        "JuJIJF4NHOKAflXx3sOemb2VJgJ5P+qVuL41gJe6rPo=",
    ]

    // JSONDecoder reads Data from base64.
    let manifest: Data
    let signature: Data

    // The bytes of manifest.json when one of the keys signed them.
    public static func verifiedBytes(of data: Data, keys: [String] = ownerKeys) throws(Problem) -> Data {
        guard let signed = try? JSONDecoder().decode(SignedManifest.self, from: data) else {
            throw .invalidSignature
        }

        let publicKeys = keys.compactMap { Data(base64Encoded: $0) }.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }

        guard publicKeys.contains(where: { $0.isValidSignature(signed.signature, for: signed.manifest) }) else {
            throw .invalidSignature
        }

        return signed.manifest
    }
}
