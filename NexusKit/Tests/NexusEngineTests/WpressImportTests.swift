import Foundation
import NexusCore
import NexusIPC
import NexusRuntime
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    static let wpressFiles: [(path: String, data: Data)] = {
        let dump = (0..<30_000).map { "INSERT INTO `SERVMASK_PREFIX_posts` VALUES (\($0),'Post \($0)','https://shop.example/?p=\($0)');\n" }.joined()

        return [
            ("database.sql", Data(dump.utf8.prefix(1_300_000))),
            ("plugins/a/exact.bin", Data((0..<1_024_000).map { _ in UInt8.random(in: .min ... .max) })),
            ("plugins/a/empty.txt", Data()),
            ("plugins/a/package.json", Data(#"{"name": "a", "private": true}"#.utf8)),
            ("multisite.json", Data(#"{"Network": false, "Sites": []}"#.utf8)),
        ]
    }()

    func storedSize(_ path: String, in entries: [WpressArchive.Entry]) -> Int64? {
        entries.first { $0.header.path == path }?.header.size
    }

    func originalSize(_ path: String) -> Int64? {
        Self.wpressFiles.first { $0.path == path }.map { Int64($0.data.count) }
    }

    func expectOriginalBytes(wpContent: URL, other: URL) throws {
        for file in Self.wpressFiles {
            let place = ["database.sql", "multisite.json"].contains(file.path) ? other : wpContent

            #expect(try Data(contentsOf: place.appending(path: file.path)) == file.data, "\(file.path)")
        }
    }

    @Test(arguments: [("secret", .gzip), ("secret", .bzip2), ("secret", nil), (nil, .gzip), (nil, nil)] as [(String?, BackupCompression?)])
    func eachKindOfWpressFileUnpacksToItsOriginalBytes(password: String?, compression: BackupCompression?) throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: "shop.wpress")
        let wpContent = root.appending(path: "shop/wp-content", directoryHint: .isDirectory)
        let other = root.appending(path: ".backup", directoryHint: .isDirectory)
        try WpressFixture.write(Self.wpressFiles, to: archive, password: password, compression: compression)

        let entries = try WpressArchive.entries(archive)
        let coding = WpressCoding(key: password.map { WpressKey(password: $0) }, compression: compression, plainByName: false)
        try WpressArchive.extract(archive, entries: entries, coding: coding, wpContent: wpContent, other: other)

        let isCoded = password != nil || compression != nil
        #expect((storedSize("plugins/a/package.json", in: entries) != originalSize("plugins/a/package.json")) == isCoded)
        #expect(storedSize("multisite.json", in: entries) == originalSize("multisite.json"))
        try expectOriginalBytes(wpContent: wpContent, other: other)
    }

    @Test func aBackupBefore7102KeepsEachPackageJSONPlain() throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: "shop.wpress")
        let wpContent = root.appending(path: "shop/wp-content", directoryHint: .isDirectory)
        let other = root.appending(path: ".backup", directoryHint: .isDirectory)
        try WpressFixture.write(Self.wpressFiles, to: archive, password: "secret", compression: nil, pluginVersion: "7.101")

        let entries = try WpressArchive.entries(archive)
        let coding = WpressCoding(key: WpressKey(password: "secret"), compression: nil, plainByName: true)
        try WpressArchive.extract(archive, entries: entries, coding: coding, wpContent: wpContent, other: other)

        #expect(storedSize("plugins/a/package.json", in: entries) == originalSize("plugins/a/package.json"))
        #expect(storedSize("multisite.json", in: entries) != originalSize("multisite.json"))
        try expectOriginalBytes(wpContent: wpContent, other: other)
    }

    @Test func thePluginVersionPicksThePlainFiles() {
        #expect(WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "7.80"))
        #expect(WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "7.101"))
        #expect(!WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "7.102"))
        #expect(!WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "7.113"))
        #expect(!WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "8.0"))
        #expect(!WpressCoding.keepsEachPackageJSONPlain(pluginVersion: "x"))
        #expect(!WpressCoding.keepsEachPackageJSONPlain(pluginVersion: nil))
    }

    @Test func theInspectionGivesTheSignatureAndTheCompression() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let compressed = root.appending(path: "shop.wpress")
        let passwordOnly = root.appending(path: "blog.wpress")
        try WpressFixture.write(Self.wpressFiles, to: compressed, password: "secret", compression: .gzip)
        try WpressFixture.write(Self.wpressFiles, to: passwordOnly, password: "secret", compression: nil)

        let ofCompressed = await engine.handle(.inspectBackup(path: compressed.path(percentEncoded: false)))
        let ofPasswordOnly = await engine.handle(.inspectBackup(path: passwordOnly.path(percentEncoded: false)))

        guard case .backup(let compressedInfo) = ofCompressed, case .backup(let passwordInfo) = ofPasswordOnly else {
            Issue.record("nexusd did not read the backups: \(ofCompressed), \(ofPasswordOnly)")
            return
        }
        #expect(compressedInfo.problem == nil)
        #expect(compressedInfo.passwordSignature != nil)
        #expect(compressedInfo.compression == .gzip)
        #expect(compressedInfo.dumpBytes == nil)
        #expect(passwordInfo.problem == nil)
        #expect(passwordInfo.passwordSignature != nil)
        #expect(passwordInfo.compression == nil)
        #expect(passwordInfo.dumpBytes != nil)
    }

    @Test func anUnknownCompressionIsRefused() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let archive = root.appending(path: "shop.wpress")
        try WpressFixture.write(Self.wpressFiles, to: archive, password: nil, compression: .gzip, compressionType: "zstd")

        let response = await engine.handle(.inspectBackup(path: archive.path(percentEncoded: false)))

        guard case .backup(let info) = response else {
            Issue.record("nexusd did not read the backup: \(response)")
            return
        }
        #expect(info.problem == "This backup is compressed with zstd. Nexus can read only gzip and bzip2.")
    }

    @Test func aPasswordWithoutASignatureIsRefused() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let archive = root.appending(path: "shop.wpress")
        try WpressFixture.write(Self.wpressFiles, to: archive, password: "secret", compression: nil, signs: false)

        let response = await engine.handle(.inspectBackup(path: archive.path(percentEncoded: false)))

        guard case .backup(let info) = response else {
            Issue.record("nexusd did not read the backup: \(response)")
            return
        }
        #expect(info.problem == "This backup has a password, but its package.json has no EncryptedSignature. So Nexus cannot check the password. Export the site again.")
    }

    @Test func anImportNeedsTheRightPassword() async throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root)
        let parent = root.appending(path: "Sites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let archive = root.appending(path: "shop.wpress")
        try WpressFixture.write(Self.wpressFiles, to: archive, password: "secret", compression: .gzip)
        let path = archive.path(percentEncoded: false)
        let folder = parent.path(percentEncoded: false)

        let wrong = await engine.handle(.importSite(SiteImport(backup: path, name: "shop", parent: folder, password: "wrong")))
        let missing = await engine.handle(.importSite(SiteImport(backup: path, name: "shop", parent: folder)))

        #expect(wrong == .failure(message: "This is not the password of the backup."))
        #expect(missing == .failure(message: "This backup has a password. Type the password of the backup."))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
    }

    @Test func aDamagedPartGivesAClearError() throws {
        let root = siteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: "shop.wpress")
        try WpressFixture.write(Self.wpressFiles, to: archive, password: nil, compression: .gzip)
        let entries = try WpressArchive.entries(archive)
        let dump = try #require(entries.first { $0.header.path == "database.sql" })
        var bytes = try Data(contentsOf: archive)
        bytes[Int(dump.offset)] = 0x7F
        try bytes.write(to: archive)
        let coding = WpressCoding(key: nil, compression: .gzip, plainByName: false)

        #expect(throws: RuntimeError.unsupported("Nexus cannot unpack database.sql from shop.wpress. The backup is damaged or not complete.")) {
            try WpressArchive.extract(archive, entries: entries, coding: coding, wpContent: root.appending(path: "shop/wp-content"), other: root.appending(path: ".backup"))
        }
    }
}
