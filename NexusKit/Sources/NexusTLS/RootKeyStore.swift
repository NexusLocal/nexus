import Foundation
@preconcurrency import Security

public enum TLSError: Error, Equatable, CustomStringConvertible {
    case keychain(operation: String, status: OSStatus)
    case keyCreation(String)
    case trustSettings(OSStatus)
    case noHosts
    case unreadableCertificate
    case fileWrite(path: String, reason: String)

    public var description: String {
        switch self {
        case .keychain(let operation, let status):
            "The login keychain did not \(operation): \(Self.message(for: status))"
        case .keyCreation(let reason):
            "Nexus could not make the key of its root CA: \(reason)"
        case .trustSettings(let status):
            "macOS did not change the trust setting of the Nexus root CA: \(Self.message(for: status))"
        case .noHosts:
            "A certificate needs at least one host name."
        case .unreadableCertificate:
            "macOS cannot read the new certificate of the Nexus root CA."
        case .fileWrite(let path, let reason):
            "Nexus could not write \(path): \(reason)"
        }
    }

    private static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text) (\(status))"
    }
}

// Keeps the private key and the certificate of the root CA. The real store is the login
// keychain. Tests use a store in memory, so they do not change the keychain of the user.
public protocol RootKeyStore: Sendable {
    func privateKey() throws -> SecKey?
    func createPrivateKey() throws -> SecKey
    func certificates(for key: SecKey) throws -> [SecCertificate]
    func add(_ certificate: SecCertificate) throws
    func removeAll() throws
}

// The key cannot leave the keychain, and only nexusd, which made it, may use it without a
// question from macOS. The certificate must be in the keychain too: macOS finds the root of a
// chain there when a browser checks a certificate of a host.
public struct LoginKeychainStore: RootKeyStore {
    public static let label = "Nexus Root CA"
    static let tag = Data("nl.roodfruit.nexus.root-ca".utf8)

    public init() {}

    public func privateKey() throws -> SecKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Self.tag,
            kSecReturnRef: true,
        ] as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw TLSError.keychain(operation: "give the key of the Nexus root CA", status: status)
        }

        return (item as! SecKey)
    }

    public func createPrivateKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrIsExtractable: false,
                kSecAttrApplicationTag: Self.tag,
                kSecAttrLabel: Self.label,
            ] as [CFString: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TLSError.keyCreation(error.map { $0.takeRetainedValue().localizedDescription } ?? "unknown error")
        }

        return key
    }

    public func certificates(for key: SecKey) throws -> [SecCertificate] {
        try certificates().filter { certificate in
            SecCertificateCopyKey(certificate).flatMap(Self.externalRepresentation) == SecKeyCopyPublicKey(key).flatMap(Self.externalRepresentation)
        }
    }

    public func add(_ certificate: SecCertificate) throws {
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: Self.label,
        ] as CFDictionary, nil)

        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TLSError.keychain(operation: "store the certificate of the Nexus root CA", status: status)
        }
    }

    public func removeAll() throws {
        for certificate in try certificates() {
            let status = SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TLSError.keychain(operation: "remove the certificate of the Nexus root CA", status: status)
            }
        }

        let status = SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: Self.tag] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TLSError.keychain(operation: "remove the key of the Nexus root CA", status: status)
        }
    }

    private func certificates() throws -> [SecCertificate] {
        var items: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &items)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let found = items as? [SecCertificate] else {
            throw TLSError.keychain(operation: "give the certificate of the Nexus root CA", status: status)
        }

        return found
    }

    private static func externalRepresentation(_ key: SecKey) -> Data? {
        SecKeyCopyExternalRepresentation(key, nil) as Data?
    }
}
