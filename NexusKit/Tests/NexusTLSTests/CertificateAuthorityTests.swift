import Foundation
import NexusCore
import NexusTestSupport
@preconcurrency import Security
import Synchronization
import Testing
import X509
@testable import NexusTLS

final class Clock: Sendable {
    private let current = Mutex(Date())

    var now: Date {
        current.withLock { $0 }
    }

    func advance(days: Double) {
        current.withLock { $0 = $0.addingTimeInterval(days * 86_400) }
    }
}

struct CertificateAuthorityTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus TLS \(UUID().uuidString)", directoryHint: .isDirectory)
    private let store = MemoryKeyStore()
    private let clock = Clock()

    private var authority: CertificateAuthority {
        let clock = clock
        return CertificateAuthority(paths: NexusPaths(root: root), store: store, now: { clock.now })
    }

    // Checks the host certificate the way Safari does, with the Nexus root as the only anchor.
    private func macOSAccepts(_ certificate: HostCertificate, for host: String, root: RootCertificate) throws -> Bool {
        let pem = try String(contentsOf: certificate.certificateFile, encoding: .utf8)
        let leaf = try CertificateAuthority.secCertificate(Certificate(pemEncoded: pem))

        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
        let evaluation = try #require(trust)
        SecTrustSetAnchorCertificates(evaluation, [root.secCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(evaluation, true)

        return SecTrustEvaluateWithError(evaluation, nil)
    }

    @Test func theRootIsACertificateAuthorityThatStaysTheSame() throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try authority.root()
        let second = try authority.root()

        #expect(first.certificate == second.certificate)
        #expect(store.certificateCount == 1)
        #expect(try first.certificate.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0))
        #expect(first.certificate.subject.description.contains("CN=Nexus Root CA"))
        #expect(FileManager.default.fileExists(atPath: authority.rootCertificateFile.path(percentEncoded: false)))
    }

    @Test func macOSAcceptsTheHostCertificateForEachHost() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = authority

        let certificate = try authority.hostCertificate(for: ["Shop.test", "api.shop.test", "shop.test"])

        let root = try authority.root()
        #expect(certificate.hosts == ["shop.test", "api.shop.test"])
        #expect(try macOSAccepts(certificate, for: "shop.test", root: root))
        #expect(try macOSAccepts(certificate, for: "api.shop.test", root: root))
        #expect(try !macOSAccepts(certificate, for: "other.test", root: root))
    }

    @Test func theKeyFileIsOnlyReadableByTheUser() throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let certificate = try authority.hostCertificate(for: ["shop.test"])

        let attributes = try FileManager.default.attributesOfItem(atPath: certificate.keyFile.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(certificate.keyFile.lastPathComponent == "shop.test.key")
        #expect(certificate.certificateFile.lastPathComponent == "shop.test.crt")
    }

    @Test func aCurrentCertificateIsUsedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try authority.hostCertificate(for: ["shop.test"])
        let firstPEM = try String(contentsOf: first.certificateFile, encoding: .utf8)

        let second = try authority.hostCertificate(for: ["shop.test"])

        #expect(second == first)
        #expect(try String(contentsOf: second.certificateFile, encoding: .utf8) == firstPEM)
    }

    @Test func otherHostsGiveANewCertificate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try authority.hostCertificate(for: ["shop.test"])

        let second = try authority.hostCertificate(for: ["shop.test", "www.shop.test"])

        #expect(second.hosts == ["shop.test", "www.shop.test"])
        #expect(second.notValidAfter >= first.notValidAfter)
        #expect(try macOSAccepts(second, for: "www.shop.test", root: try authority.root()))
    }

    @Test func aCertificateIsRenewedThirtyDaysBeforeItExpires() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try authority.hostCertificate(for: ["shop.test"])

        clock.advance(days: 366)
        let stillCurrent = try authority.hostCertificate(for: ["shop.test"])
        clock.advance(days: 2)
        let second = try authority.hostCertificate(for: ["shop.test"])

        #expect(stillCurrent == first)
        #expect(second.notValidAfter > first.notValidAfter)
    }

    @Test func aCertificateOfAnotherRootIsReplaced() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try authority.hostCertificate(for: ["shop.test"])
        try store.removeAll()

        let second = try authority.hostCertificate(for: ["shop.test"])

        #expect(second.notValidAfter >= first.notValidAfter)
        #expect(try macOSAccepts(second, for: "shop.test", root: try authority.root()))
    }

    @Test func anInvalidHostGetsNoCertificate() {
        #expect(throws: HostNameError.self) {
            try authority.hostCertificate(for: ["../../etc/passwd"])
        }
        #expect(throws: TLSError.noHosts) {
            try authority.hostCertificate(for: [])
        }
    }

    @Test func anUntrustedRootIsNotTrusted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try authority.root()

        #expect(!authority.isTrusted())
    }
}
