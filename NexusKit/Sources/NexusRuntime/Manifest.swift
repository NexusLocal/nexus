import Foundation

public struct Manifest: Codable, Sendable, Equatable {
    public static let defaultURL = URL(string: "https://github.com/NexusLocal/binaries/releases/download/manifest/manifest.json")!

    public let schema: Int
    public let generated: Date
    public let repository: String
    public let packages: [ManifestPackage]

    public init(schema: Int, generated: Date, repository: String, packages: [ManifestPackage]) {
        self.schema = schema
        self.generated = generated
        self.repository = repository
        self.packages = packages
    }

    public static func decode(from data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data)
    }

    public func packages(named name: String) -> [ManifestPackage] {
        packages.filter { $0.name == name }
    }

    public func package(named name: String, line: String) -> ManifestPackage? {
        packages.first { $0.name == name && $0.line == line }
    }
}

public struct ManifestPackage: Codable, Sendable, Equatable, Identifiable {
    public enum Format: String, Codable, Sendable {
        case tarXZ = "tar.xz"
        case phar
    }

    public let name: String
    public let version: String
    public let line: String
    public let revision: Int
    public let url: URL
    public let sha256: String
    public let size: Int?
    public let format: Format
    public let minimumMacOS: String
    public let architecture: String
    public let license: String?
    public let upstream: Bool?

    public var id: String { "\(name)-\(line)" }

    public init(
        name: String,
        version: String,
        line: String,
        revision: Int,
        url: URL,
        sha256: String,
        size: Int? = nil,
        format: Format,
        minimumMacOS: String = "27.0",
        architecture: String = "arm64",
        license: String? = nil,
        upstream: Bool? = nil
    ) {
        self.name = name
        self.version = version
        self.line = line
        self.revision = revision
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.format = format
        self.minimumMacOS = minimumMacOS
        self.architecture = architecture
        self.license = license
        self.upstream = upstream
    }

    enum CodingKeys: String, CodingKey {
        case name, version, line, revision, url, sha256, size, format, architecture, license, upstream
        case minimumMacOS = "minimum_macos"
    }
}
