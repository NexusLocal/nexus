import CommonCrypto
import CryptoKit
import Foundation

// The password of a .wpress file of All-in-One WP Migration (ai1wm_encrypt_string and
// ai1wm_decrypt_string in functions.php of 7.113). The key is the first 16 bytes of the SHA-1 of the
// password. PHP fills it with NUL bytes to the 32 bytes of AES-256. Each encrypted part starts with
// its IV of 16 bytes. The rest is AES-256-CBC with PKCS#7 padding.
public struct WpressKey: Sendable, Equatable {
    public let bytes: Data

    public init(password: String) {
        bytes = Data(Insecure.SHA1.hash(data: Data(password.utf8)).prefix(16)) + Data(count: 16)
    }
}

public enum WpressCipher {
    // AI1WM_SIGN_TEXT of constants.php. EncryptedSignature in package.json is this text, encrypted.
    public static let signText = #""How long do you want these messages to remain secret? I want them to remain secret for as long as men are capable of evil." - Neal Stephenson"#
    public static let ivLength = 16

    public static func decrypt(_ part: Data, key: WpressKey) -> Data? {
        guard part.count >= 2 * ivLength, part.count % ivLength == 0 else {
            return nil
        }

        var plain = Data(count: part.count - ivLength)
        var moved = 0

        let status = plain.withUnsafeMutableBytes { output in
            part.withUnsafeBytes { input in
                key.bytes.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, kCCKeySizeAES256, input.baseAddress, input.baseAddress?.advanced(by: ivLength), input.count - ivLength, output.baseAddress, output.count, &moved)
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        return plain.prefix(moved)
    }

    // A wrong key gives bad padding in most cases. The text comparison catches the other cases.
    public static func isPassword(_ password: String, of signature: String) -> Bool {
        guard let encrypted = Data(base64Encoded: signature) else {
            return false
        }

        return decrypt(encrypted, key: WpressKey(password: password)) == Data(signText.utf8)
    }
}
