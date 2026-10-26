import Foundation
import Testing
@testable import NexusRuntime

struct ManifestTests {
    private let json = """
    {
      "schema": 1,
      "generated": "2026-10-26T16:00:00Z",
      "repository": "NexusLocal/binaries",
      "packages": [
        {"name": "php", "version": "8.5.12", "line": "8.5", "revision": 1,
         "url": "https://github.com/NexusLocal/binaries/releases/download/php-8.5.12-r1/php-8.5.12-macos-arm64.tar.xz",
         "sha256": "c873c5547ff88b3a3a08bcb515b87fd123d0dfb6091c8a854fd1ec08684faeca", "size": 27474164,
         "format": "tar.xz", "minimum_macos": "27.0", "architecture": "arm64", "license": "PHP-3.01"},
        {"name": "node", "version": "24.22.1", "line": "24", "revision": 1,
         "url": "https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-arm64.tar.xz",
         "sha256": "654ba79de6155647e22321932b45f2a1ccb705976cc337c9b8e278beb085a628",
         "format": "tar.xz", "minimum_macos": "27.0", "architecture": "arm64", "upstream": true},
        {"name": "composer", "version": "2.10.3", "line": "2", "revision": 1,
         "url": "https://getcomposer.org/download/2.10.3/composer.phar",
         "sha256": "7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4d0000000000",
         "format": "phar", "minimum_macos": "27.0", "architecture": "arm64", "upstream": true}
      ]
    }
    """

    @Test func decodesTheManifestThatPublishWrites() throws {
        let manifest = try Manifest.decode(from: Data(json.utf8))

        #expect(manifest.schema == 1)
        #expect(manifest.packages.count == 3)
        #expect(manifest.packages[0].minimumMacOS == "27.0")
        #expect(manifest.packages[2].format == .phar)
    }

    @Test func findsAPackageByNameAndLine() throws {
        let manifest = try Manifest.decode(from: Data(json.utf8))

        let php = manifest.package(named: "php", line: "8.5")

        #expect(php?.version == "8.5.12")
        #expect(manifest.package(named: "php", line: "8.1") == nil)
        #expect(manifest.packages(named: "node").map(\.line) == ["24"])
    }
}
