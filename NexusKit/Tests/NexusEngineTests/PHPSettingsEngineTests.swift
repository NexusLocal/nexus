import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

// The custom php.ini lines (D60) and the details of the web services in the service list.
extension NexusEngineTests {
    private static let realRuntimes = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"]

    // A php that refuses a line with "==" as PHP does, with the file and the line. For a value
    // "abc" it writes a warning without a line, as PHP does for a wrong number.
    private func makeFakeCheckingPHP(in root: URL) throws -> ManifestPackage {
        let source = root.appending(path: "source/php-8.5.0", directoryHint: .isDirectory)
        let extensions = source.appending(path: "lib/php/extensions/no-debug-non-zts-20250925", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data().write(to: extensions.appending(path: "xdebug.so"))

        let php = source.appending(path: "bin/php")
        let script = #"""
            #!/bin/sh
            custom="$PHP_INI_SCAN_DIR/99-custom.ini"
            [ -f "$custom" ] || exit 0
            /usr/bin/awk -v file="$custom" '
                /==/ { print "PHP:  syntax error, unexpected \047=\047 in " file " on line " NR; exit }
                /= *abc/ { print "Warning: Invalid quantity \"abc\" in Unknown on line 0"; exit }
            ' "$custom" >&2

            """#
        try Data(script.utf8).write(to: php)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path(percentEncoded: false))

        let archive = root.appending(path: "php-8.5.0.tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", root.appending(path: "source").path(percentEncoded: false), "php-8.5.0"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "php", version: "8.5.0", line: "8.5", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    private func makePHPEngine(root: URL, package: ManifestPackage? = nil) throws -> NexusEngine {
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        var state = EngineState()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        return NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: CopyDownloader(),
            manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: package.map { [$0] } ?? [])),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            helperRetryDelay: .milliseconds(50)
        )
    }

    private func customFile(_ root: URL, line: String) -> URL {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
            .phpConfigFolder(line: line)
            .appending(path: "conf.d/99-custom.ini")
    }

    private func phpRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    @Test func aWrongCustomLineKeepsTheOldLinesAndNamesTheLine() async throws {
        let root = phpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makePHPEngine(root: root, package: try makeFakeCheckingPHP(in: root))
        _ = await engine.handle(.install(name: "php", line: "8.5"))

        let saved = await engine.handle(.setCustomSettings(php: "8.5", lines: ["memory_limit = 512M"]))
        let refused = await engine.handle(.setCustomSettings(php: "8.5", lines: ["memory_limit = 256M", "", "post_max_size == 64M"]))
        let kept = await engine.handle(.customSettings(php: "8.5"))

        #expect(saved == .done(message: "PHP 8.5 uses the new custom settings at its next start."))
        #expect(refused == .invalidSettings(PHPSettingsError(php: "8.5", line: 3, message: "syntax error, unexpected '='")))
        #expect(kept == .lines(["memory_limit = 512M"]))
        #expect(try String(contentsOf: customFile(root, line: "8.5"), encoding: .utf8).hasSuffix("\nmemory_limit = 512M\n"))
    }

    @Test func aWarningWithoutALineGetsTheFirstLineThatCausesIt() async throws {
        let root = phpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makePHPEngine(root: root, package: try makeFakeCheckingPHP(in: root))
        _ = await engine.handle(.install(name: "php", line: "8.5"))

        let refused = await engine.handle(.setCustomSettings(php: "8.5", lines: ["memory_limit = 512M", "; a comment", "upload_max_filesize = abc", "max_execution_time = 120"]))

        #expect(refused == .invalidSettings(PHPSettingsError(php: "8.5", line: 3, message: #"Invalid quantity "abc""#)))
        #expect(await engine.handle(.customSettings(php: "8.5")) == .lines([]))
    }

    @Test func theServiceListHasTheExtensionsTheCustomLinesTheDNSNoteAndTheLANSetting() async throws {
        let root = phpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makePHPEngine(root: root, package: try makeFakeCheckingPHP(in: root))
        _ = await engine.handle(.install(name: "php", line: "8.5"))
        _ = await engine.handle(.setCustomSettings(php: "8.5", lines: ["memory_limit = 512M"]))

        var events = await engine.events().makeAsyncIterator()
        guard case .services(let list) = await events.next() else {
            Issue.record("no service list")
            return
        }
        let php = try #require(list.services.first { $0.id == "php-8.5" })
        let dns = try #require(list.services.first { $0.id == NexusEngine.dnsServiceID })

        #expect(php.toggles.map(\.name) == ["xdebug"])
        #expect(php.toggles.first?.help.contains("debugger") == true)
        #expect(php.customSettings == ["memory_limit = 512M"])
        #expect(php.usedBy.isEmpty)
        #expect(dns.note?.contains("/etc/resolver/test") == true)
        #expect(list.lanAccess == false)
    }

    @Test(.enabled(if: realRuntimes != nil))
    func aRealPHPRefusesAWrongLineAndKeepsAGoodOne() async throws {
        let root = phpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makePHPEngine(root: root)
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        let link = paths.runtime("php", line: "8.4")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Self.realRuntimes!).appending(path: "php/8.4"))

        let syntax = await engine.handle(.setCustomSettings(php: "8.4", lines: ["memory_limit = 512M", "upload_max_filesize = 64M", "post_max_size == 64M"]))
        let quantity = await engine.handle(.setCustomSettings(php: "8.4", lines: ["display_errors = Off", "memory_limit = abc"]))
        let hidden = await engine.handle(.setCustomSettings(php: "8.4", lines: ["memory_limit = abc", "memory_limit = 512M", "upload_max_filesize = xyz"]))
        let saved = await engine.handle(.setCustomSettings(php: "8.4", lines: ["memory_limit = 512M", "[xdebug]", "xdebug.mode = coverage"]))

        #expect(syntax == .invalidSettings(PHPSettingsError(php: "8.4", line: 3, message: "syntax error, unexpected '='")))
        guard case .invalidSettings(let error) = quantity, case .invalidSettings(let later) = hidden else {
            Issue.record("PHP took a wrong number: \(quantity), \(hidden)")
            return
        }
        #expect(error.line == 2)
        #expect(error.message.contains("memory_limit"))
        #expect(later.line == 3)
        #expect(later.message.contains("upload_max_filesize"))
        #expect(saved == .done(message: "PHP 8.4 uses the new custom settings at its next start."))
    }
}
