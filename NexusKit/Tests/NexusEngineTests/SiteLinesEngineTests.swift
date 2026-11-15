import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine

// The custom nginx and Apache lines of a PHP site (owner, 2026-11-14).
extension NexusEngineTests {
    private static let fakeNginx = #"""
        #!/bin/sh
        [ "$1" = "-t" ] || exec /bin/sleep 600
        /usr/bin/awk '
            /include ".*\/sites\/.*";/ {
                file = $0
                sub(/^[^"]*"/, "", file)
                sub(/";.*$/, "", file)
                number = 0
                while ((getline text < file) > 0) {
                    number++
                    if (text ~ /client_max_body_siz /) {
                        print "2026/11/14 22:10:19 [emerg] 1#1: unknown directive \"client_max_body_siz\" in " file ":" number
                        exit 1
                    }
                }
                close(file)
            }
        ' "$5" >&2

        """#

    private static let fakeHTTPD = #"""
        #!/bin/sh
        [ "$1" = "-t" ] || exec /bin/sleep 600
        /usr/bin/awk '
            /Include ".*\/sites\/.*"/ {
                file = $0
                sub(/^[^"]*"/, "", file)
                sub(/".*$/, "", file)
                number = 0
                while ((getline text < file) > 0) {
                    number++
                    if (text ~ /LimitRequestBodyy/) {
                        print "AH00526: Syntax error on line " number " of " file ":"
                        print "Invalid command \047LimitRequestBodyy\047, perhaps misspelled or defined by a module not included in the server configuration"
                        exit 1
                    }
                }
                close(file)
            }
        ' "$3" >&2

        """#

    private func makeLinesEngine(root: URL, sites: [Site], parked: [ParkedFolder] = [], apache: Bool = false) throws -> NexusEngine {
        var state = EngineState()
        state.sites = sites
        state.parked = parked
        let runtimes: [(name: String, line: String)] = [("nginx", "1.30"), ("php", "8.5")] + (apache ? [("httpd", "2.4")] : [])
        let engine = try makeSiteEngine(root: root, state: state, runtimes: runtimes)
        let paths = linesPaths(root)

        try writeProgram(Self.fakeNginx, to: paths.runtime("nginx", line: "1.30").appending(path: "sbin/nginx"))

        if apache {
            try writeProgram(Self.fakeHTTPD, to: paths.runtime("httpd", line: "2.4").appending(path: "bin/httpd"))
        }

        return engine
    }

    private func linesPaths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory), pharLinks: root)
    }

    private func writeProgram(_ script: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
    }

    private func siteFolder(_ name: String, in root: URL) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<?php echo '\(name)';".utf8).write(to: folder.appending(path: "index.php"))
        return folder
    }

    private func text(of file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    @Test func aWrongNginxLineKeepsTheOldLinesAndNamesTheLine() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeLinesEngine(root: root, sites: [Site(host: "shop.test", folder: try siteFolder("shop", in: root), php: "8.5")])
        let paths = linesPaths(root)
        let file = paths.siteLinesFile("shop.test", server: .nginx)

        let good = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_size 100m;"]))
        let wrong = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_siz 100m;"]))
        let lines = await engine.handle(.siteLines(host: "shop.test"))

        #expect(good == .done(message: "shop.test gets the new nginx lines at the next start of nginx."))
        #expect(wrong == .invalidSiteLines(SiteLinesError(host: "shop.test", server: .nginx, line: 1, message: "unknown directive \"client_max_body_siz\"")))
        #expect(lines == .lines(["client_max_body_size 100m;"]))
        #expect(text(of: file) == SiteLinesFile.contents(["client_max_body_size 100m;"], server: .nginx))
        #expect(text(of: paths.nginxConfig)?.contains("include \"\(file.path(percentEncoded: false))\";") == true)
        #expect(await engine.stateStore.current().sites.first?.nginxLines == ["client_max_body_size 100m;"])
    }

    @Test func aWrongApacheLineKeepsTheOldLinesAndNamesTheLine() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeLinesEngine(root: root, sites: [Site(host: "blog.test", folder: try siteFolder("blog", in: root), php: "8.5", server: .apache)], apache: true)
        let paths = linesPaths(root)
        let file = paths.siteLinesFile("blog.test", server: .apache)
        let good = ["LimitRequestBody 104857600", "Header set X-Robots-Tag \"noindex\""]

        let saved = await engine.handle(.setSiteLines(host: "blog.test", lines: good))
        let wrong = await engine.handle(.setSiteLines(host: "blog.test", lines: ["Header set X-Robots-Tag \"noindex\"", "LimitRequestBodyy 1"]))
        let lines = await engine.handle(.siteLines(host: "blog.test"))

        #expect(saved == .done(message: "blog.test gets the new Apache lines at the next start of Apache."))
        #expect(wrong == .invalidSiteLines(SiteLinesError(host: "blog.test", server: .apache, line: 2, message: "Invalid command 'LimitRequestBodyy', perhaps misspelled or defined by a module not included in the server configuration")))
        #expect(lines == .lines(good))
        #expect(text(of: file) == SiteLinesFile.contents(good, server: .apache))
        #expect(text(of: paths.apacheConfig)?.contains("    Include \"\(file.path(percentEncoded: false))\"\n</VirtualHost>") == true)
        #expect(text(of: paths.nginxConfig)?.contains("sites/blog.test.conf") == false)
        #expect(await engine.stateStore.current().sites.first?.nginxLines == nil)
    }

    @Test func emptyLinesRemoveTheIncludeAndTheFile() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeLinesEngine(root: root, sites: [Site(host: "shop.test", folder: try siteFolder("shop", in: root), php: "8.5")])
        let paths = linesPaths(root)
        let file = paths.siteLinesFile("shop.test", server: .nginx)

        _ = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_size 100m;"]))
        let existed = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        let cleared = await engine.handle(.setSiteLines(host: "shop.test", lines: ["", " "]))
        let lines = await engine.handle(.siteLines(host: "shop.test"))

        #expect(existed)
        #expect(cleared == .done(message: "shop.test gets the new nginx lines at the next start of nginx."))
        #expect(lines == .lines([]))
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(text(of: paths.nginxConfig)?.contains("sites/shop.test.conf") == false)
        #expect(await engine.stateStore.current().sites.first?.nginxLines == nil)
    }

    @Test func aLineBreakInALineStartsANewLine() {
        #expect(NexusEngine.siteLines(["a\nb", "c"]) == ["a", "b", "c"])
        #expect(NexusEngine.siteLines(["a\r\nb"]) == ["a", "b"])
        #expect(NexusEngine.siteLines(["", " \n "]) == nil)
    }

    @Test func emptyLinesAlsoRemoveTheLinesOfTheOtherWebserver() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let site = Site(host: "shop.test", folder: try siteFolder("shop", in: root), php: "8.5", apacheLines: ["Header set X-Robots-Tag \"noindex\""])
        let engine = try makeLinesEngine(root: root, sites: [site])

        _ = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_size 100m;"]))
        let kept = await engine.stateStore.current().sites.first?.apacheLines
        _ = await engine.handle(.setSiteLines(host: "shop.test", lines: []))
        let stored = await engine.stateStore.current().sites.first

        #expect(kept == ["Header set X-Robots-Tag \"noindex\""])
        #expect(stored?.nginxLines == nil)
        #expect(stored?.apacheLines == nil)
    }

    @Test func onlyAPHPSiteThatRunsGetsLines() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = Site(host: "app.test", folder: try siteFolder("app", in: root), php: "", runsAs: .node)
        let old = Site(host: "shop.test", folder: try siteFolder("shop", in: root), php: "8.3")
        let engine = try makeLinesEngine(root: root, sites: [app, old])

        let node = await engine.handle(.setSiteLines(host: "app.test", lines: ["client_max_body_size 100m;"]))
        let missing = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_size 100m;"]))
        let unknown = await engine.handle(.siteLines(host: "none.test"))

        #expect(node == .failure(message: "Only a PHP site has custom nginx or Apache lines. app.test runs as a Node.js app."))
        #expect(missing == .failure(message: "shop.test does not run. So Nexus cannot check its new lines. PHP 8.3 is not installed. Run: nexus install php 8.3"))
        #expect(unknown == .failure(message: "Nexus has no site none.test."))
        #expect(await engine.stateStore.current().sites == [app, old])
    }

    @Test func aSiteOfAParkedFolderGetsItsLinesAsAnAddedSite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = root.appending(path: "Sites", directoryHint: .isDirectory)
        _ = try siteFolder("blog", in: parked)
        let engine = try makeLinesEngine(root: root, sites: [], parked: [ParkedFolder(folder: parked, php: "8.5")])

        let saved = await engine.handle(.setSiteLines(host: "blog.test", lines: ["client_max_body_size 100m;"]))
        let sites = await engine.stateStore.current().sites

        #expect(saved == .done(message: "blog.test gets the new nginx lines at the next start of nginx."))
        #expect(sites.map(\.host) == ["blog.test"])
        #expect(sites.first?.nginxLines == ["client_max_body_size 100m;"])
    }

    @Test func theSiteListHasTheLines() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeLinesEngine(root: root, sites: [Site(host: "shop.test", folder: try siteFolder("shop", in: root), php: "8.5", apacheLines: ["LimitRequestBody 1"])])

        _ = await engine.handle(.setSiteLines(host: "shop.test", lines: ["client_max_body_size 100m;"]))
        let site = await engine.siteInfo().first

        #expect(site?.nginxLines == ["client_max_body_size 100m;"])
        #expect(site?.apacheLines == ["LimitRequestBody 1"])
    }
}
