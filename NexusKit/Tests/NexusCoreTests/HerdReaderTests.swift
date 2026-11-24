import Foundation
import Testing
@testable import NexusCore

struct HerdReaderTests {
    private struct Fixture {
        let root: URL
        let herd: URL
        let stubs: URL

        var valet: URL {
            herd.appending(path: "config/valet", directoryHint: .isDirectory)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "nexus-herd-\(UUID().uuidString)", directoryHint: .isDirectory)
            herd = root.appending(path: "Library/Application Support/Herd", directoryHint: .isDirectory)
            stubs = root.appending(path: "stubs", directoryHint: .isDirectory)

            for folder in ["config/valet/Sites", "config/valet/Nginx", "config/php/85", "config/php/83", "bin"] {
                try FileManager.default.createDirectory(at: herd.appending(path: folder), withIntermediateDirectories: true)
            }

            try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String, in folder: URL? = nil) throws {
            let file = (folder ?? herd).appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        func project(_ path: String) throws -> URL {
            let folder = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        func link(_ name: String, to folder: URL) throws {
            try FileManager.default.createSymbolicLink(at: valet.appending(path: "Sites/\(name)"), withDestinationURL: folder)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let siteTemplate = """
    server {
        listen VALET_LOOPBACK:80;
        server_name VALET_SITE www.VALET_SITE *.VALET_SITE;
        client_max_body_size 1024M;
        fastcgi_pass $herd_sock;
        error_log "HERD_HOME_PATH/Log/nginx-error.log";
    }
    """

    private let secureTemplate = """
    server {
        listen VALET_LOOPBACK:443 ssl;
        server_name VALET_SITE www.VALET_SITE *.VALET_SITE;
        ssl_certificate "VALET_CERT";
        client_max_body_size 1024M;
        fastcgi_pass $herd_sock;
    }
    """

    @Test func noConfigurationGivesNoSetup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(HerdReader.read(herd: fixture.herd, stubs: nil) == nil)
    }

    @Test func theParkedFoldersLeaveOutTheSitesFolderOfHerdAndFoldersThatAreGone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let code = try fixture.project("Herd")
        try fixture.write(#"{"tld":"test","paths":["\#(fixture.valet.path(percentEncoded: false))Sites/","\#(code.path(percentEncoded: false))","/nexus/no/such/folder"]}"#, to: "config/valet/config.json")

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: nil))

        #expect(setup.tld == "test")
        #expect(setup.parkedFolders.map(\.lastPathComponent) == ["Herd"])
    }

    @Test func twoLinksToOneFolderAreOneSiteWithAnAlias() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = try fixture.project("Code/api-server")
        let legacy = try fixture.project("Code/legacy-app")
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.link("api", to: api)
        try fixture.link("api-v2", to: api)
        try fixture.link("legacy", to: legacy)

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: nil))

        #expect(setup.links.map(\.names) == [["api", "api-v2"], ["legacy"]])
        #expect(setup.links.first?.folder.lastPathComponent == "api-server")
    }

    @Test func aSiteFileGivesItsPHPVersionItsProxyAndItsHTTPS() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.write("# ISOLATED_PHP_VERSION=8.3\nserver {\n    listen 127.0.0.1:443 ssl;\n}\n", to: "config/valet/Nginx/api.test")
        try fixture.write("# ISOLATED_PHP_VERSION=php@8.1\nserver {\n    listen 127.0.0.1:80;\n}\n", to: "config/valet/Nginx/legacy.test")
        try fixture.write("# valet stub: proxy.valet.conf\nserver {\n    location / {\n        proxy_pass http://127.0.0.1:3000;\n    }\n}\n", to: "config/valet/Nginx/admin.test")

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: nil))

        #expect(setup.siteFile(of: "api.test") == HerdSetup.SiteFile(host: "api.test", php: "8.3", secured: true))
        #expect(setup.siteFile(of: "legacy.test")?.php == "8.1")
        #expect(setup.siteFile(of: "admin.test")?.proxy == "http://127.0.0.1:3000")
    }

    @Test func onlyTheLinesThatNoTemplateHasAreLinesOfTheUser() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(siteTemplate, to: "site.valet.conf", in: fixture.stubs)
        try fixture.write(secureTemplate, to: "secure.valet.conf", in: fixture.stubs)
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.write("""
        # ISOLATED_PHP_VERSION=8.3
        server {
            listen 127.0.0.1:443 ssl;
            server_name api.test www.api.test *.api.test;
            add_header Access-Control-Allow-Origin "*" always;
            ssl_certificate "/Users/ann/Library/Application Support/Herd/config/valet/Certificates/api.test.crt";
            client_max_body_size 64M;
            fastcgi_pass $herd_sock_83;
        }
        """, to: "config/valet/Nginx/api.test")

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: fixture.stubs))

        #expect(setup.siteFile(of: "api.test")?.ownLines == [#"add_header Access-Control-Allow-Origin "*" always;"#])
    }

    @Test func thePHPIniLinesKeepTheLastValueAndLeaveOutThePathsOfHerd() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.write("""
        curl.cainfo=\(fixture.herd.path(percentEncoded: false))config/php/cacert.pem
        pcre.jit=0
        memory_limit=128M
        auto_prepend_file=/Applications/Herd.app/Contents/Resources/valet/dump-loader.php
        extension=/Applications/Herd.app/Contents/Resources/herd-ext/herd-85-arm64.so
        ; a comment
        memory_limit=512M
        extension=/opt/homebrew/lib/php/pecl/20250925/swoole.so
        max_execution_time=123
        """, to: "config/php/85/php.ini")
        try fixture.write("pcre.jit=0\noutput_buffering=4096\n", to: "config/php/83/php.ini")

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: nil))

        #expect(setup.phpIniLines == ["8.5": ["memory_limit=512M", "extension=/opt/homebrew/lib/php/pecl/20250925/swoole.so", "max_execution_time=123"]])
    }

    @Test func theDefaultPHPIsTheTargetOfTheLinkPHP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.write("", to: "bin/php85")
        try FileManager.default.createSymbolicLink(atPath: fixture.herd.appending(path: "bin/php").path(percentEncoded: false), withDestinationPath: "php85")

        #expect(HerdReader.read(herd: fixture.herd, stubs: nil)?.defaultPHP == "8.5")
    }

    @Test func theWorkspacesGiveTheirKindTheirFolderAndTheirSite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"paths":[]}"#, to: "config/valet/config.json")
        try fixture.write(#"{"workspaces":[{"kind":"worktree","path":"/Users/ann/Herd/shop-feature","parent_site":"shop"},{"kind":"clone","path":"/Users/ann/Herd/shop-copy","parent_site":"shop"}]}"#, to: "config/valet/workspaces.json")

        let setup = try #require(HerdReader.read(herd: fixture.herd, stubs: nil))

        #expect(setup.workspaces.map(\.kind) == ["worktree", "clone"])
        #expect(setup.workspaces.map(\.site) == ["shop", "shop"])
    }
}
