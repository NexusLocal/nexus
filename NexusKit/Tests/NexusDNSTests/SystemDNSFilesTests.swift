import Foundation
import NexusCore
import Testing
@testable import NexusDNS

struct SystemDNSFilesTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "Nexus DNS Files \(UUID().uuidString)", directoryHint: .isDirectory)

    private var files: SystemDNSFiles {
        SystemDNSFiles(
            resolverFolder: folder.appending(path: "resolver", directoryHint: .isDirectory),
            hostsFile: folder.appending(path: "hosts", directoryHint: .notDirectory)
        )
    }

    private func writeHosts(_ contents: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: files.hostsFile)
    }

    private func hosts() throws -> String {
        try String(contentsOf: files.hostsFile, encoding: .utf8)
    }

    private func resolver(_ tld: String) throws -> String {
        try String(contentsOf: files.resolverFolder.appending(path: tld), encoding: .utf8)
    }

    @Test func setResolverWritesTheNameserverAndThePort() throws {
        defer { try? FileManager.default.removeItem(at: folder) }

        let changed = try files.setResolver(tld: "test", port: 10053)

        #expect(changed)
        #expect(try resolver("test") == "\(SystemDNSFiles.resolverMarker)\nnameserver 127.0.0.1\nport 10053\n")
    }

    @Test func setResolverWithTheSameContentsChangesNothing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try files.setResolver(tld: "test", port: 10053)

        #expect(try files.setResolver(tld: "test", port: 10053) == false)
        #expect(try files.setResolver(tld: "test", port: 10054))
        #expect(try resolver("test").hasSuffix("port 10054\n"))
    }

    @Test func setResolverRefusesAFileOfAnotherApp() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: files.resolverFolder, withIntermediateDirectories: true)
        try Data("nameserver 127.0.0.1\n".utf8).write(to: files.resolverFolder.appending(path: "test"))

        #expect(throws: SystemDNSFilesError.self) {
            try files.setResolver(tld: "test", port: 10053)
        }
        #expect(try files.removeResolver(tld: "test") == false)
        #expect(try resolver("test") == "nameserver 127.0.0.1\n")
    }

    @Test func setResolverRefusesARealTLDAndAPath() {
        #expect(throws: HostNameError.unsupportedTLD("com")) {
            try files.setResolver(tld: "com", port: 10053)
        }
        #expect(throws: HostNameError.self) {
            try files.setResolver(tld: "../hosts", port: 10053)
        }
    }

    @Test func setResolverRefusesALowPort() {
        #expect(throws: SystemDNSFilesError.invalidPort(53)) {
            try files.setResolver(tld: "test", port: 53)
        }
    }

    @Test func removeResolverRemovesTheFileOfNexus() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try files.setResolver(tld: "test", port: 10053)

        #expect(try files.removeResolver(tld: "test"))
        #expect(!FileManager.default.fileExists(atPath: files.resolverFolder.appending(path: "test").path(percentEncoded: false)))
    }

    @Test func setHostsAddsABlockAndKeepsEveryOtherLine() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeHosts("127.0.0.1\tlocalhost\n127.0.0.1 mamp-site.local # MAMP PRO\n")

        try files.setHosts(["shop.local", "Api.Shop.Local", "shop.local"])

        #expect(try hosts() == """
            127.0.0.1\tlocalhost
            127.0.0.1 mamp-site.local # MAMP PRO
            # Nexus begin
            127.0.0.1 api.shop.local
            ::1 api.shop.local
            127.0.0.1 shop.local
            ::1 shop.local
            # Nexus end

            """)
    }

    @Test func setHostsReplacesTheOldBlock() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeHosts("a\n# Nexus begin\n127.0.0.1 old.local\n# Nexus end\nb\n")

        try files.setHosts(["new.local"])

        #expect(try hosts() == "a\nb\n# Nexus begin\n127.0.0.1 new.local\n::1 new.local\n# Nexus end\n")
    }

    @Test func setHostsWithNoHostsRemovesTheBlock() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = "127.0.0.1 localhost\n"
        try writeHosts(original)
        try files.setHosts(["shop.local"])

        try files.setHosts([])

        #expect(try hosts() == original)
        #expect(try files.setHosts([]) == false)
    }

    @Test func setHostsRefusesABlockWithoutAnEnd() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = "# Nexus begin\n127.0.0.1 mamp.local\n"
        try writeHosts(original)

        #expect(throws: SystemDNSFilesError.self) {
            try files.setHosts([])
        }
        #expect(try hosts() == original)
    }

    @Test func setHostsRefusesAnInvalidHost() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeHosts("127.0.0.1 localhost\n")

        for host in ["localhost", "a b.local", "evil.local\n1.2.3.4 bank.com", "-a.local", "a..local", "github.com", "local"] {
            #expect(throws: HostNameError.self) {
                try files.setHosts([host])
            }
        }
        #expect(try hosts() == "127.0.0.1 localhost\n")
    }
}
