import Foundation
import Testing
@testable import NexusCore

struct ValetReaderTests {
    private struct Fixture {
        let root: URL
        let valet: URL
        let stubs: URL
        let homebrew: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "nexus-valet-\(UUID().uuidString)", directoryHint: .isDirectory)
            valet = root.appending(path: ".config/valet", directoryHint: .isDirectory)
            stubs = root.appending(path: ".composer/vendor/laravel/valet/cli/stubs", directoryHint: .isDirectory)
            homebrew = root.appending(path: "homebrew", directoryHint: .isDirectory)

            for folder in [valet.appending(path: "Sites"), valet.appending(path: "Nginx"), stubs, homebrew.appending(path: "bin")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func write(_ text: String, to path: String, in folder: URL) throws {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        func folder(_ path: String) throws -> URL {
            let url = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.standardizedFileURL
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func valetGivesItsParkedFoldersLinksAndIsolatedPHP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sites = try fixture.folder("Sites")
        let api = try fixture.folder("Code/api-server")
        let config = #"{"tld": "test", "loopback": "127.0.0.1", "paths": ["\#(fixture.valet.path(percentEncoded: false))Sites", "\#(sites.path(percentEncoded: false))"]}"#
        try fixture.write(config, to: "config.json", in: fixture.valet)
        try FileManager.default.createSymbolicLink(at: fixture.valet.appending(path: "Sites/api"), withDestinationURL: api)
        try FileManager.default.createSymbolicLink(at: fixture.valet.appending(path: "Sites/api-v2"), withDestinationURL: api)
        try fixture.write("server {\n    listen VALET_LOOPBACK:80;\n    fastcgi_pass \"unix:VALET_HOME_PATH/valet.sock\";\n}\n", to: "site.valet.conf", in: fixture.stubs)
        try fixture.write("# ISOLATED_PHP_VERSION=php@8.3\nserver {\n    listen 127.0.0.1:80;\n    add_header Access-Control-Allow-Origin \"*\" always;\n    fastcgi_pass \"unix:/Users/ann/.config/valet/valet83.sock\";\n}\n", to: "Nginx/api.test", in: fixture.valet)

        let setup = try #require(ValetReader.read(valet: fixture.valet, stubs: fixture.stubs, homebrew: nil))

        #expect(setup.parkedFolders == [sites])
        #expect(setup.links == [HerdSetup.Link(names: ["api", "api-v2"], folder: api)])
        #expect(setup.siteFile(of: "api.test")?.php == "8.3")
        #expect(setup.siteFile(of: "api.test")?.ownLines == [#"add_header Access-Control-Allow-Origin "*" always;"#])
        #expect(setup.workspaces.isEmpty)
    }

    @Test func theLinkedFormulaOfHomebrewIsTheDefaultPHP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let php = fixture.homebrew.appending(path: "bin/php")
        try FileManager.default.createSymbolicLink(atPath: php.path(percentEncoded: false), withDestinationPath: "../Cellar/php@8.5/8.5.13/bin/php")

        #expect(ValetReader.defaultPHP(homebrew: fixture.homebrew) == "8.5")

        try FileManager.default.removeItem(at: php)
        try FileManager.default.createSymbolicLink(atPath: php.path(percentEncoded: false), withDestinationPath: "../Cellar/php/8.6.0_1/bin/php")

        #expect(ValetReader.defaultPHP(homebrew: fixture.homebrew) == "8.6")
    }

    @Test func thePHPLinesAreTheChangesToHomebrewAndTheMemoryLimitsOfValet() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = "[PHP]\nmax_execution_time = 30\nmemory_limit = 128M\n;date.timezone =\n"
        try fixture.write(original, to: "opt/php@8.5/.bottle/etc/php/8.5/php.ini", in: fixture.homebrew)
        try fixture.write("[PHP]\nmax_execution_time = 123\nmemory_limit = 128M\ndate.timezone = Europe/Amsterdam\nextension=\"redis.so\"\n", to: "etc/php/8.5/php.ini", in: fixture.homebrew)
        try fixture.write("; Max memory per instance\nmemory_limit = 512M\nupload_max_filesize = 512M\npost_max_size = 512M\n", to: "etc/php/8.5/conf.d/php-memory-limits.ini", in: fixture.homebrew)
        try fixture.write("error_log=\"\(fixture.valet.path(percentEncoded: false))Log/php-fpm.log\"\nlog_errors=on\n", to: "etc/php/8.5/conf.d/error_log.ini", in: fixture.homebrew)
        try fixture.write(original, to: "etc/php/8.3/php.ini", in: fixture.homebrew)
        try fixture.write(original, to: "opt/php@8.3/.bottle/etc/php/8.3/php.ini", in: fixture.homebrew)

        let lines = ValetReader.phpIniLines(homebrew: fixture.homebrew, valet: fixture.valet)

        #expect(lines == ["8.5": ["max_execution_time=123", "date.timezone=Europe/Amsterdam", "memory_limit=512M", "upload_max_filesize=512M", "post_max_size=512M"]])
    }

    @Test func noConfigurationMeansNoValet() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(ValetReader.read(valet: fixture.valet, stubs: nil, homebrew: nil) == nil)
    }
}
