import Foundation
import NexusCore
@preconcurrency import Security

// The two keys of the own domain (group 4, 4h). cert is the cert.pem of the login. tunnel is the
// token of the tunnel.
public enum CloudflareKey: String, Sendable, CaseIterable {
    case cert
    case tunnel
}

// Keeps the keys of the own domain. The real store is the login keychain. The tests of the engine
// use a store in memory. So they do not change the keychain of the user.
public protocol CloudflareKeyStore: Sendable {
    func save(_ data: Data, as key: CloudflareKey) throws
    func read(_ key: CloudflareKey) throws -> Data?
    func remove(_ key: CloudflareKey) throws
}

// The store of an engine without a keychain, for example in a test. It keeps nothing. Each save
// and each read throws. nexusd gives the engine LoginCloudflareKeyStore.
public struct NoCloudflareKeyStore: CloudflareKeyStore {
    public init() {}

    public func save(_ data: Data, as key: CloudflareKey) throws {
        throw TLSError.keychain(operation: "save the Cloudflare key", status: errSecNotAvailable)
    }

    public func read(_ key: CloudflareKey) throws -> Data? {
        throw TLSError.keychain(operation: "give the Cloudflare key", status: errSecNotAvailable)
    }

    public func remove(_ key: CloudflareKey) throws {}
}

// Generic passwords in the login keychain. Each variant has its own service. So Nexus Dev has its
// own keys. Keychain Access shows the label.
public struct LoginCloudflareKeyStore: CloudflareKeyStore {
    public static let standardService = "\(NexusIdentifiers.app).cloudflare"
    public static let label = "\(NexusVariant.current.name) Cloudflare key"
    public let service: String

    public init(service: String = standardService) {
        self.service = service
    }

    public func save(_ data: Data, as key: CloudflareKey) throws {
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData: data] as CFDictionary)

        if status == errSecSuccess {
            return
        }

        guard status == errSecItemNotFound else {
            throw TLSError.keychain(operation: "save the Cloudflare key", status: status)
        }

        var item = query(key)
        item[kSecAttrLabel] = Self.label
        item[kSecValueData] = data

        let added = SecItemAdd(item as CFDictionary, nil)

        guard added == errSecSuccess else {
            throw TLSError.keychain(operation: "save the Cloudflare key", status: added)
        }
    }

    public func read(_ key: CloudflareKey) throws -> Data? {
        var search = query(key)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw TLSError.keychain(operation: "give the Cloudflare key", status: status)
        }

        return data
    }

    public func remove(_ key: CloudflareKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TLSError.keychain(operation: "remove the Cloudflare key", status: status)
        }
    }

    private func query(_ key: CloudflareKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
    }
}
