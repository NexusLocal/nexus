import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusLaravel
import NexusRuntime

// The values of the protection of visitors for the share block and the site block (group 4, 4d).
// The lines that use them are in NexusConfig/ShareProtection.swift.
extension NexusEngine {
    // The characters of a password. A person reads each one without doubt: no i, l, o, 0 or 1.
    static let sharePasswordCharacters = Array("abcdefghjkmnpqrstuvwxyz23456789")

    // The keys of the debug tools in .env and their default paths. The default paths are in the
    // rules of ShareProtection already.
    static let debugPathKeys = ["TELESCOPE_PATH": "telescope", "HORIZON_PATH": "horizon", "PULSE_PATH": "pulse", "DEBUGBAR_ROUTE_PREFIX": "_debugbar"]

    // The step of 4d in prepareShare. A link with "Ask visitors for a password" gets its password
    // and its file before nginx names the file.
    func prepareSharePassword(_ record: ShareRecord) async throws {
        guard record.options.password else {
            return
        }

        let password = try writeSharePassword(record.id)
        try await updateShare(record.id) { $0.password = password }
    }

    // The password of a link (overview, 4d). 16 characters from 31 in four groups of four. That is
    // about 79 bits. The file has mode 0600 from its creation. An atomic write would first give the
    // default mode. 4b deletes the file at the end of the link.
    func writeSharePassword(_ id: String) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let password = Self.sharePassword(using: &generator)
        let salt = (0..<8).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let line = ShareProtection.passwordLine(password: password, salt: salt)

        do {
            try FileManager.default.createDirectory(at: paths.shareFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.shareFolder.path(percentEncoded: false))
            try Self.writePrivately(line, to: paths.sharePasswordFile(id))
        } catch {
            throw RuntimeError.unsupported(ShareText.passwordNotSaved(ErrorText.plain(error)))
        }

        return password
    }

    // For example k7mq-2xfh-9pwd-r4tc.
    static func sharePassword(using generator: inout some RandomNumberGenerator) -> String {
        let characters = (0..<16).map { _ in sharePasswordCharacters.randomElement(using: &generator) ?? "a" }

        return stride(from: 0, to: 16, by: 4).map { String(characters[$0..<$0 + 4]) }.joined(separator: "-")
    }

    private static func writePrivately(_ text: String, to file: URL) throws {
        let path = file.path(percentEncoded: false)
        unlink(path)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)

        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    // The pool nexus-share gets each request of a link with hidden errors to a PHP site in nginx or
    // in Apache.
    func shareSocket(for record: ShareRecord, phpLine: String?) -> URL? {
        guard record.options.hidesErrors, let phpLine else {
            return nil
        }

        return paths.phpShareSocket(line: phpLine)
    }

    static func sharePHPLine(of backend: WebBackend, php: String) -> String? {
        guard case .php = backend else {
            return nil
        }

        return php
    }

    // The /vendor/ rule applies only when the document root holds vendor/autoload.php (owner,
    // 2026-11-20). A route of an app such as /vendor/acme then still works through the link. The
    // site of a workspace has its document root in its worktree.
    static func composerInDocumentRoot(site: WebSite?) -> Bool {
        guard case .php(_, let documentRoot, _, _)? = site?.backend else {
            return false
        }

        return FileManager.default.fileExists(atPath: documentRoot.appending(path: "vendor/autoload.php").path(percentEncoded: false))
    }

    // The custom paths of the debug tools in the .env of the Laravel application. That application
    // holds the document root. A path loses its slashes at the start and the end. A default path is
    // left out.
    static func shareDebugPaths(site: WebSite?) -> [String] {
        guard case .php(_, let documentRoot, _, _)? = site?.backend, let root = LaravelProject.root(containing: documentRoot) else {
            return []
        }

        let values = EnvFile.values(of: root.appending(path: ".env"))

        return debugPathKeys.keys.sorted().compactMap { key in
            let path = values[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

            guard !path.isEmpty, path.lowercased() != debugPathKeys[key] else {
                return nil
            }

            return path
        }
    }
}
