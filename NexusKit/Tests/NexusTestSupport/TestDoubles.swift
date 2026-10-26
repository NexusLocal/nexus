import Darwin
import Foundation
import NexusIPC
import NexusTLS
@preconcurrency import Security
import Synchronization

public final class MemoryKeyStore: RootKeyStore {
    private struct Contents: @unchecked Sendable {
        var key: SecKey?
        var certificates: [SecCertificate] = []
        var trusted: [SecCertificate] = []
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

    public func isTrusted(_ certificate: SecCertificate) -> Bool {
        contents.withLock { $0.trusted.contains { CFEqual($0, certificate) } }
    }

    public func trust(_ certificate: SecCertificate) throws {
        contents.withLock { $0.trusted.append(certificate) }
    }

    public func removeAll() throws {
        contents.withLock { $0 = Contents() }
    }
}

public final class RecordingHelper: PrivilegedHelper {
    private let state = Mutex<(requests: [HelperRequest], reachable: Bool, refused: Set<String>)>(([], true, []))

    public init() {}

    public var requests: [HelperRequest] {
        state.withLock { $0.requests }
    }

    public func setReachable(_ reachable: Bool) {
        state.withLock { $0.reachable = reachable }
    }

    public func refuseResolver(for tld: String) {
        state.withLock { _ = $0.refused.insert(tld) }
    }

    public func send(_ request: HelperRequest) async throws {
        try state.withLock {
            guard $0.reachable else {
                throw HelperError.notReachable("the test helper is off")
            }

            if case .setResolver(let tld, _) = request, $0.refused.contains(tld) {
                throw HelperError.refused("/etc/resolver/\(tld) belongs to another app")
            }

            $0.requests.append(request)
        }
    }
}

public func freeUDPPort() -> Int {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    return Int(UInt16(bigEndian: bound.sin_port))
}
