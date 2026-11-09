import Foundation

// GitHub serves a release asset at two addresses: the download address on github.com and the API
// of the release. On 2026-11-09 the download address gave HTTP status 504 for manifest.json for
// minutes, also in other repositories. The API gave the same file at that moment. So a download
// that fails on the side of GitHub tries the API once. Without a login the API allows 60 requests
// an hour, and Nexus uses it only after such a failure.
public enum GitHubReleaseAsset {
    struct Location: Equatable {
        let repository: String
        // nil is the latest release.
        let tag: String?
        let name: String
    }

    struct Release: Decodable {
        let assets: [Asset]
    }

    // url is the address of the asset in the API.
    struct Asset: Decodable {
        let name: String
        let url: URL
    }

    // A status for a failure on the side of GitHub. A missing file gives 404, and the API cannot
    // help then.
    public static func isTemporaryFailure(_ status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    // The request for the asset through the API. A URL that is no release asset on github.com,
    // or a release without that asset, gives nil.
    public static func apiRequest(for url: URL, session: URLSession = .shared) async throws -> URLRequest? {
        guard let location = location(of: url) else {
            return nil
        }

        var request = URLRequest(url: releaseURL(of: location))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        return try assetURL(named: location.name, in: data).map(assetRequest)
    }

    // github.com/<owner>/<repository>/releases/latest/download/<name> or
    // github.com/<owner>/<repository>/releases/download/<tag>/<name>.
    static func location(of url: URL) -> Location? {
        guard url.scheme == "https", url.host() == "github.com" else {
            return nil
        }

        let parts = url.pathComponents.filter { $0 != "/" }

        guard parts.count == 6, parts[2] == "releases" else {
            return nil
        }

        let repository = "\(parts[0])/\(parts[1])"

        if parts[3] == "latest", parts[4] == "download" {
            return Location(repository: repository, tag: nil, name: parts[5])
        }

        guard parts[3] == "download" else {
            return nil
        }

        return Location(repository: repository, tag: parts[4], name: parts[5])
    }

    static func releaseURL(of location: Location) -> URL {
        let release = location.tag.map { "tags/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)" } ?? "latest"
        return URL(string: "https://api.github.com/repos/\(location.repository)/releases/\(release)")!
    }

    static func assetURL(named name: String, in release: Data) throws -> URL? {
        try JSONDecoder().decode(Release.self, from: release).assets.first { $0.name == name }?.url
    }

    static func assetRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }
}
