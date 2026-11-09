import Foundation
import Testing
@testable import NexusRuntime

struct GitHubReleaseAssetTests {
    @Test func theLatestManifestGoesToTheLatestReleaseOfTheAPI() throws {
        let location = try #require(GitHubReleaseAsset.location(of: Manifest.defaultURL))

        #expect(location == .init(repository: "NexusLocal/binaries", tag: nil, name: "manifest.json"))
        #expect(GitHubReleaseAsset.releaseURL(of: location).absoluteString == "https://api.github.com/repos/NexusLocal/binaries/releases/latest")
    }

    @Test func aPackageGoesToTheReleaseOfItsTag() throws {
        let url = try #require(URL(string: "https://github.com/NexusLocal/binaries/releases/download/httpd-2.4.70-r1/httpd-2.4.70-macos-arm64.tar.gz"))
        let location = try #require(GitHubReleaseAsset.location(of: url))

        #expect(location == .init(repository: "NexusLocal/binaries", tag: "httpd-2.4.70-r1", name: "httpd-2.4.70-macos-arm64.tar.gz"))
        #expect(GitHubReleaseAsset.releaseURL(of: location).absoluteString == "https://api.github.com/repos/NexusLocal/binaries/releases/tags/httpd-2.4.70-r1")
    }

    @Test(arguments: [
        "https://example.com/NexusLocal/binaries/releases/latest/download/manifest.json",
        "http://github.com/NexusLocal/binaries/releases/latest/download/manifest.json",
        "https://github.com/NexusLocal/binaries/archive/refs/tags/v1.zip",
        "https://github.com/NexusLocal/binaries/releases/tag/httpd-2.4.70-r1",
    ])
    func anotherURLGetsNoTryThroughTheAPI(url: String) throws {
        #expect(GitHubReleaseAsset.location(of: try #require(URL(string: url))) == nil)
    }

    @Test func theAssetURLComesFromTheReleaseWithTheSameName() throws {
        let release = Data("""
        {"assets": [
            {"name": "manifest.json.sig", "url": "https://api.github.com/repos/NexusLocal/binaries/releases/assets/1"},
            {"name": "manifest.json", "url": "https://api.github.com/repos/NexusLocal/binaries/releases/assets/2"}
        ]}
        """.utf8)

        #expect(try GitHubReleaseAsset.assetURL(named: "manifest.json", in: release)?.absoluteString == "https://api.github.com/repos/NexusLocal/binaries/releases/assets/2")
        #expect(try GitHubReleaseAsset.assetURL(named: "other.json", in: release) == nil)
        #expect(GitHubReleaseAsset.assetRequest(try #require(URL(string: "https://api.github.com/x"))).value(forHTTPHeaderField: "Accept") == "application/octet-stream")
    }

    @Test(arguments: [(504, true), (502, true), (500, true), (429, true), (404, false), (403, false), (200, false)])
    func onlyAFailureOnTheSideOfGitHubGetsTheTry(status: Int, tries: Bool) {
        #expect(GitHubReleaseAsset.isTemporaryFailure(status) == tries)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_NETWORK_TESTS"] != nil))
    func theAPIGivesTheRealManifest() async throws {
        let request = try #require(try await GitHubReleaseAsset.apiRequest(for: Manifest.defaultURL))
        let (data, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Manifest.decode(from: data).repository.isEmpty == false)
    }
}
