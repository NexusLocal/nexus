import Foundation
import NexusIPC
import NexusTLS
@preconcurrency import Security
import Synchronization

// A root key store in memory, so a test never changes the login keychain.
public final class MemoryKeyStore: RootKeyStore {
    private struct Contents: @unchecked Sendable {
        var key: SecKey?
        var certificates: [SecCertificate] = []
    }

    private let contents = Mutex(Contents())

    public init() {}

    public var certificateCount: Int {
        contents.withLock { $0.certificates.count }
    }

    public func privateKey() throws -> SecKey? {
        contents.withLock { $0.key }
    }

    public func createPrivateKey() throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TLSError.keyCreation(String(describing: error?.takeRetainedValue()))
        }

        contents.withLock { $0.key = key }
        return key
    }

    public func certificates(for key: SecKey) throws -> [SecCertificate] {
        contents.withLock { $0.certificates }
    }

    public func add(_ certificate: SecCertificate) throws {
        contents.withLock { $0.certificates.append(certificate) }
    }

    public func removeAll() throws {
        contents.withLock { $0 = Contents() }
    }
}

// Records what nexusd asks the helper, and can act as a helper that the user did not approve.
public final class RecordingHelper: PrivilegedHelper {
    private let state = Mutex<(requests: [HelperRequest], reachable: Bool)>(([], true))

    public init(reachable: Bool = true) {
        state.withLock { $0.reachable = reachable }
    }

    public var requests: [HelperRequest] {
        state.withLock { $0.requests }
    }

    public func setReachable(_ reachable: Bool) {
        state.withLock { $0.reachable = reachable }
    }

    public func send(_ request: HelperRequest) async throws {
        try state.withLock {
            guard $0.reachable else {
                throw HelperError.notReachable("the test helper is off")
            }
            $0.requests.append(request)
        }
    }
}
