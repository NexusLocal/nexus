import CommonCrypto
import CryptoKit
import Foundation

// The login of MongoDB with a user and a password (RFC 5802 and RFC 7677). The password does not go
// over the connection. The server also proves that it knows the password.
struct ScramSHA256 {
    // A server of Nexus asks for 15,000 rounds. A much larger number would only cost time.
    static let iterations = 4_096...1_000_000

    private let user: String
    private let password: String
    private let nonce: String

    init(user: String, password: String, nonce: String = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()) {
        self.user = user
        self.password = password
        self.nonce = nonce
    }

    private var firstMessageBare: String {
        let name = user.replacing("=", with: "=3D").replacing(",", with: "=2C")
        return "n=\(name),r=\(nonce)"
    }

    var firstMessage: String {
        "n,,\(firstMessageBare)"
    }

    struct Answer: Equatable {
        let message: String
        let serverSignature: String
    }

    // The answer to the first message of the server. That message gives the nonce of both sides, the
    // salt and the number of rounds.
    func answer(to serverMessage: String) throws -> Answer {
        let fields = Self.fields(of: serverMessage)

        guard let serverNonce = fields["r"], serverNonce.hasPrefix(nonce), serverNonce.count > nonce.count,
              let salt = fields["s"].flatMap({ Data(base64Encoded: $0) }), !salt.isEmpty,
              let rounds = fields["i"].flatMap({ Int($0) }), Self.iterations.contains(rounds) else {
            throw MongoDBError.loginFailed
        }

        let salted = SymmetricKey(data: try Self.saltedPassword(password, salt: salt, rounds: rounds))
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: salted))
        let storedKey = SymmetricKey(data: Data(SHA256.hash(data: clientKey)))
        let finalBare = "c=biws,r=\(serverNonce)"
        let authMessage = Data("\(firstMessageBare),\(serverMessage),\(finalBare)".utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: storedKey))
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        let serverKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: salted)))
        let serverSignature = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: serverKey))

        return Answer(message: "\(finalBare),p=\(proof.base64EncodedString())", serverSignature: serverSignature.base64EncodedString())
    }

    static func serverSignature(in message: String) -> String? {
        fields(of: message)["v"]
    }

    private static func fields(of message: String) -> [String: String] {
        let pairs = message.split(separator: ",").compactMap { part -> (String, String)? in
            guard let equals = part.firstIndex(of: "=") else {
                return nil
            }

            return (String(part[..<equals]), String(part[part.index(after: equals)...]))
        }

        return Dictionary(pairs) { first, _ in first }
    }

    // SASLprep changes a password to its compatibility form (NFKC). A password of ASCII characters
    // stays the same.
    private static func saltedPassword(_ password: String, salt: Data, rounds: Int) throws -> Data {
        let prepared = Array(password.precomposedStringWithCompatibilityMapping.utf8)
        var key = Data(count: Int(CC_SHA256_DIGEST_LENGTH))

        let status = key.withUnsafeMutableBytes { key in
            salt.withUnsafeBytes { salt in
                prepared.withUnsafeBytes { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: CChar.self).baseAddress,
                        password.count,
                        salt.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        key.bindMemory(to: UInt8.self).baseAddress,
                        key.count
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MongoDBError.loginFailed
        }

        return key
    }
}
