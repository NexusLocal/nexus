import Crypto
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

    @Test func aPublicNameGetsNoCertificate() {
        #expect(throws: HostNameError.publicHost("github.com")) {
            try authority.hostCertificate(for: ["shop.test", "github.com"])
        }
    }

    private func macOSAcceptsACertificateSignedWithoutTheAuthority(for host: String, root: RootCertificate) throws -> Bool {
        let key = P256.Signing.PrivateKey()
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: clock.now.addingTimeInterval(-60),
            notValidAfter: clock.now.addingTimeInterval(86_400),
            issuer: root.certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: try Certificate.PrivateKey(root.privateKey)
        )

        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(try CertificateAuthority.secCertificate(leaf), SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
        let evaluation = try #require(trust)
        SecTrustSetAnchorCertificates(evaluation, [root.secCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(evaluation, true)

        return SecTrustEvaluateWithError(evaluation, nil)
    }

    @Test func macOSRefusesAPublicNameEvenWhenTheRootKeySignsIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rootCertificate = try authority.root()

        #expect(try macOSAcceptsACertificateSignedWithoutTheAuthority(for: "shop.test", root: rootCertificate))
        #expect(try macOSAcceptsACertificateSignedWithoutTheAuthority(for: "shop.local", root: rootCertificate))
        #expect(try !macOSAcceptsACertificateSignedWithoutTheAuthority(for: "github.com", root: rootCertificate))
        #expect(try !macOSAcceptsACertificateSignedWithoutTheAuthority(for: "test.github.com", root: rootCertificate))
    }

    @Test func anInvalidHostGetsNoCertificate() {
        #expect(throws: HostNameError.self) {
            try authority.hostCertificate(for: ["../../etc/passwd"])
        }
        #expect(throws: TLSError.noHosts) {
            try authority.hostCertificate(for: [])
        }
    }

    @Test func trustMarksTheRootAsTrusted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try authority.root()
        let before = authority.isTrusted()

        try authority.trust()

        #expect(!before)
        #expect(authority.isTrusted())
        #expect(store.certificateCount == 1)
    }

    @Test func removeDeletesTheRootAndTheHostCertificates() throws {
        let certificate = try authority.hostCertificate(for: ["shop.test"])
        try authority.trust()

        try authority.remove()

        #expect(try store.privateKey() == nil)
        #expect(!authority.isTrusted())
        #expect(!FileManager.default.fileExists(atPath: certificate.certificateFile.path(percentEncoded: false)))
    }
}
