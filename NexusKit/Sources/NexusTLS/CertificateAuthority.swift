import Crypto
import Darwin
import Foundation
import NexusCore
@preconcurrency import Security
import SwiftASN1
import X509

public struct RootCertificate: @unchecked Sendable {
    public let certificate: Certificate
    public let secCertificate: SecCertificate
    let privateKey: SecKey
}

public struct HostCertificate: Codable, Sendable, Equatable {
    public let hosts: [String]
    public let certificateFile: URL
    public let keyFile: URL
    public let notValidAfter: Date
}

// The root CA of Nexus and the certificates that it signs for each host. The user trusts the
// root one time. After that, every host certificate works in Safari and Chrome without a
// question.
public struct CertificateAuthority: Sendable {
    public static let rootValidity: TimeInterval = 10 * 365 * 86_400
    // Apple accepts at most 825 days for a TLS server certificate. 397 days also passes the
    // stricter rule for public certificates.
    public static let hostValidity: TimeInterval = 397 * 86_400
    public static let renewalMargin: TimeInterval = 30 * 86_400

    // Browsers refuse a certificate of this root for a public name or for an IP address, also
    // when the key is used outside nexusd.
    static let nameConstraints = NameConstraints(
        permittedDNSDomains: HostName.privateSuffixes.sorted(),
        excludedIPRanges: [
            ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 8)),
            ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 32)),
        ]
    )

    private let store: any RootKeyStore
    private let folder: URL
    private let now: @Sendable () -> Date

    public init(paths: NexusPaths, store: any RootKeyStore = LoginKeychainStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.folder = paths.certs
        self.now = now
    }

    // The public certificate of the root CA. A browser with its own certificate store needs it,
    // for example Firefox.
    public var rootCertificateFile: URL {
        folder.appending(path: "nexus-root-ca.pem", directoryHint: .notDirectory)
    }

    // The keychain can hold an expired certificate next to a new one for the same key. The valid
    // certificate that expires last is the root.
    public func existingRoot() throws -> RootCertificate? {
        guard let key = try store.privateKey() else {
            return nil
        }

        let valid = try store.certificates(for: key).compactMap { secCertificate -> RootCertificate? in
            guard let certificate = try? Certificate(secCertificate), certificate.notValidAfter > now() else {
                return nil
            }
            return RootCertificate(certificate: certificate, secCertificate: secCertificate, privateKey: key)
        }

        return valid.max { $0.certificate.notValidAfter < $1.certificate.notValidAfter }
    }

    // Loads the root CA from the keychain, or makes it the first time.
    public func root() throws -> RootCertificate {
        if let existing = try existingRoot() {
            try writeRootFile(existing.certificate)
            return existing
        }

        let key = try store.privateKey() ?? store.createPrivateKey()
        let signer = try Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            OrganizationName("Nexus")
            OrganizationalUnitName(NSUserName())
            CommonName(LoginKeychainStore.label)
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signer.publicKey,
            notValidBefore: now().addingTimeInterval(-86_400),
            notValidAfter: now().addingTimeInterval(Self.rootValidity),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
                Critical(Self.nameConstraints)
                SubjectKeyIdentifier(hash: signer.publicKey)
            },
            issuerPrivateKey: signer
        )

        let secCertificate = try Self.secCertificate(certificate)
        try store.add(secCertificate)
        try writeRootFile(certificate)
        return RootCertificate(certificate: certificate, secCertificate: secCertificate, privateKey: key)
    }

    public func isTrusted() -> Bool {
        guard let root = try? existingRoot() else {
            return false
        }

        return isTrusted(root)
    }

    public func isTrusted(_ root: RootCertificate) -> Bool {
        store.isTrusted(root.secCertificate)
    }

    // macOS asks for the password of the user before it changes a trust setting.
    public func trust() throws {
        try store.trust(root().secCertificate)
    }

    // Removes the trust settings, the key, the certificates and every host certificate. A key of
    // a trusted root must not stay behind when Nexus is removed.
    public func remove() throws {
        try store.removeAll()

        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // Gives the certificate for these hosts. An existing certificate stays in use while it has
    // the same hosts, comes from the current root and is valid for more than 30 days.
    public func hostCertificate(for hosts: [String]) throws -> HostCertificate {
        try hostCertificate(for: hosts, root: root())
    }

    // For many hosts at once: the caller reads the root from the keychain one time.
    public func hostCertificate(for hosts: [String], root: RootCertificate) throws -> HostCertificate {
        var seen: Set<String> = []
        let hosts = try hosts.map(HostName.validated).filter { seen.insert($0).inserted }

        guard let primary = hosts.first else {
            throw TLSError.noHosts
        }

        let certificateFile = folder.appending(path: "\(primary).crt", directoryHint: .notDirectory)
        let keyFile = folder.appending(path: "\(primary).key", directoryHint: .notDirectory)

        if let current = currentCertificate(certificateFile: certificateFile, keyFile: keyFile, hosts: hosts, root: root) {
            return current
        }

        let key = P256.Signing.PrivateKey()
        let publicKey = Certificate.PublicKey(key.publicKey)

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now().addingTimeInterval(-3_600),
            notValidAfter: now().addingTimeInterval(Self.hostValidity),
            issuer: root.certificate.subject,
            subject: try DistinguishedName {
                OrganizationName("Nexus")
                CommonName(primary)
            },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(hosts.map { GeneralName.dnsName($0) })
                AuthorityKeyIdentifier(keyIdentifier: try root.certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: try Certificate.PrivateKey(root.privateKey)
        )

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.write(key.pemRepresentation, to: keyFile, permissions: 0o600)
        try Self.write(try certificate.serializeAsPEM().pemString, to: certificateFile, permissions: 0o644)

        return HostCertificate(hosts: hosts, certificateFile: certificateFile, keyFile: keyFile, notValidAfter: certificate.notValidAfter)
    }

    private func currentCertificate(certificateFile: URL, keyFile: URL, hosts: [String], root: RootCertificate) -> HostCertificate? {
        guard let certificatePEM = try? String(contentsOf: certificateFile, encoding: .utf8),
              let keyPEM = try? String(contentsOf: keyFile, encoding: .utf8),
              let certificate = try? Certificate(pemEncoded: certificatePEM),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
              let names = try? certificate.extensions.subjectAlternativeNames else {
            return nil
        }

        let dnsNames = names.compactMap { name -> String? in
            guard case .dnsName(let value) = name else {
                return nil
            }
            return value
        }

        guard Set(dnsNames) == Set(hosts),
              certificate.publicKey == Certificate.PublicKey(key.publicKey),
              root.certificate.publicKey.isValidSignature(certificate.signature, for: certificate),
              certificate.notValidAfter.timeIntervalSince(now()) > Self.renewalMargin else {
            return nil
        }

        return HostCertificate(hosts: hosts, certificateFile: certificateFile, keyFile: keyFile, notValidAfter: certificate.notValidAfter)
    }

    private func writeRootFile(_ certificate: Certificate) throws {
        let pem = try certificate.serializeAsPEM().pemString

        if (try? String(contentsOf: rootCertificateFile, encoding: .utf8)) == pem {
            return
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.write(pem, to: rootCertificateFile, permissions: 0o644)
    }

    static func secCertificate(_ certificate: Certificate) throws -> SecCertificate {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)

        guard let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw TLSError.unreadableCertificate
        }

        return secCertificate
    }

    // Writes to a new file with its final permissions, then renames it. So a key file is never
    // readable by other users, also not for a moment.
    private static func write(_ text: String, to file: URL, permissions: mode_t) throws {
        let temporary = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, permissions)

        guard descriptor >= 0 else {
            throw TLSError.fileWrite(path: file.path(percentEncoded: false), reason: String(cString: strerror(errno)))
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        guard rename(temporary.path(percentEncoded: false), file.path(percentEncoded: false)) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw TLSError.fileWrite(path: file.path(percentEncoded: false), reason: reason)
        }
    }
}
