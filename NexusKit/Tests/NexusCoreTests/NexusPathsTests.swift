import Foundation
import Testing
@testable import NexusCore

struct NexusPathsTests {
    @Test func standardRootIsTheNexusFolderInApplicationSupport() {
        let root = NexusPaths.standard.root

        #expect(root.lastPathComponent == "Nexus")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func runtimeFolderContainsTheNameAndTheVersionLine() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.runtime("php", line: "8.5")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/runtimes/php/8.5/")
    }

    @Test func dataFolderJoinsTheServiceAndTheVersionLine() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let folder = paths.dataFolder(service: "mysql", line: "8.4")

        #expect(folder.path(percentEncoded: false) == "/tmp/Nexus Test/data/mysql-8.4/")
    }

    @Test func theLinesOfASiteAreNextToTheConfigurationOfTheirServer() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        #expect(paths.siteLinesFile("shop.test", server: .nginx).path(percentEncoded: false) == "/tmp/Nexus Test/config/nginx/sites/shop.test.conf")
        #expect(paths.siteLinesFile("shop.test", server: .apache).path(percentEncoded: false) == "/tmp/Nexus Test/config/apache/sites/shop.test.conf")
        #expect(paths.siteLinesFolder(.nginx).path(percentEncoded: false) == "/tmp/Nexus Test/config/nginx/sites/")
    }

    @Test func logFileIsNamedAfterTheService() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        let file = paths.log("redis-8.2")

        #expect(file.path(percentEncoded: false) == "/tmp/Nexus Test/logs/redis-8.2.log")
    }

    @Test func theDumpFilesHaveTheirOwnPlaces() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        #expect(paths.dumpSocket.path(percentEncoded: false) == "/tmp/Nexus Test/run/dumps.sock")
        #expect(paths.dumpFolder.path(percentEncoded: false) == "/tmp/Nexus Test/run/dumps/")
        #expect(paths.dumpLog.path(percentEncoded: false) == "/tmp/Nexus Test/logs/dumps.jsonl")
        #expect(paths.dumpLibrary.path(percentEncoded: false) == "/tmp/Nexus Test/php/dumps/")
    }

    @Test func theFilesOfTheLinksHaveTheirOwnPlaces() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        #expect(paths.shareFolder.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/")
        #expect(paths.cloudflaredHome.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/cloudflared/")
        #expect(paths.cloudflaredConfig.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/cloudflared/config.yml")
        #expect(paths.ownDomainConfig.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/cloudflared/own-domain.yml")
        #expect(paths.sharePasswordFile("abc").path(percentEncoded: false) == "/tmp/Nexus Test/data/share/abc.htpasswd")
        #expect(paths.shareVisitorLog("abc").path(percentEncoded: false) == "/tmp/Nexus Test/logs/share-abc.jsonl")
        #expect(paths.shareRequestLog("abc").path(percentEncoded: false) == "/tmp/Nexus Test/logs/share-abc-requests.jsonl")
        #expect(paths.tunnelLog("shop.test").path(percentEncoded: false) == "/tmp/Nexus Test/logs/cloudflared-shop.test.log")
        #expect(paths.ownDomainTunnelLog.path(percentEncoded: false) == "/tmp/Nexus Test/logs/cloudflared-own-domain.log")
    }

    @Test func theSetupOfTheOwnDomainHasItsOwnFolderOutsideTheLogs() {
        let paths = NexusPaths(root: URL(filePath: "/tmp/Nexus Test", directoryHint: .isDirectory))

        #expect(paths.ownDomainFolder.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/own-domain/")
        #expect(paths.ownDomainCommandConfig.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/own-domain/config.yml")
        #expect(paths.ownDomainLoginCert.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/own-domain/.cloudflared/cert.pem")
        #expect(paths.ownDomainLoginLog.path(percentEncoded: false) == "/tmp/Nexus Test/data/share/own-domain/login.log")
    }

    @Test func theNjsModuleOfALinkIsInTheFolderOfTheLinks() {
        let paths = NexusPaths(root: URL(filePath: "/Users/me/Library/Application Support/Nexus Dev", directoryHint: .isDirectory))

        #expect(paths.shareScript("abc").path(percentEncoded: false) == "/Users/me/Library/Application Support/Nexus Dev/data/share/abc.js")
    }

    @Test(arguments: [NexusVariant.release, .dev])
    func theDumpSocketFitsInAUnixSocketPathOfEachVariant(variant: NexusVariant) {
        let paths = NexusPaths(root: .applicationSupportDirectory.appending(path: variant.name, directoryHint: .isDirectory))

        let socket = paths.dumpSocket.path(percentEncoded: false)

        #expect(socket.hasSuffix("/Library/Application Support/\(variant.name)/run/dumps.sock"))
        #expect(socket.utf8.count <= 103)
    }

    @Test(arguments: [NexusVariant.release, .dev])
    func thePoolOfTheLinksHasItsOwnSocketThatFitsInAUnixSocketPath(variant: NexusVariant) {
        let paths = NexusPaths(root: .applicationSupportDirectory.appending(path: variant.name, directoryHint: .isDirectory))

        let socket = paths.phpShareSocket(line: "8.4").path(percentEncoded: false)

        #expect(socket.hasSuffix("/Library/Application Support/\(variant.name)/run/php-share-8.4.sock"))
        #expect(socket.utf8.count < 104)
    }

    @Test func createFoldersMakesEveryFolderInAPathWithSpaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Nexus Paths \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root)

        try paths.createFolders()

        for folder in paths.allFolders {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}
