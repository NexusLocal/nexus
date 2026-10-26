import Foundation

public struct InstalledRuntime: Codable, Sendable, Equatable {
    public static let metadataFileName = ".nexus-runtime.json"

    public let name: String
    public let line: String
    public let version: String
    public let revision: Int
    public let sha256: String
    public let installedAt: Date
    public var folder: URL

    public init(name: String, line: String, version: String, revision: Int, sha256: String, installedAt: Date, folder: URL) {
        self.name = name
        self.line = line
        self.version = version
        self.revision = revision
        self.sha256 = sha256
        self.installedAt = installedAt
        self.folder = folder
    }

    public func isSameBuild(as package: ManifestPackage) -> Bool {
        version == package.version && revision == package.revision && sha256 == package.sha256
    }

    enum CodingKeys: String, CodingKey {
        case name, line, version, revision, sha256, installedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        line = try container.decode(String.self, forKey: .line)
        version = try container.decode(String.self, forKey: .version)
        revision = try container.decode(Int.self, forKey: .revision)
        sha256 = try container.decode(String.self, forKey: .sha256)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        folder = URL(filePath: "/")
    }
}
