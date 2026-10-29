import Foundation

// Another app can own /etc/resolver/<tld>, for example Laravel Herd. Only the first line of the
// file tells the two apart.
public enum ResolverFileOwner: Sendable, Equatable {
    case missing
    case nexus
    case otherApp
}

public enum ResolverFile {
    public static let marker = "# Written by Nexus. Nexus removes this file when you remove Nexus."
    public static let folder = URL(filePath: "/etc/resolver", directoryHint: .isDirectory)

    public static func owner(of file: URL) -> ResolverFileOwner {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return .missing
        }

        let contents = try? String(contentsOf: file, encoding: .utf8)

        return contents?.hasPrefix(marker) == true ? .nexus : .otherApp
    }
}
