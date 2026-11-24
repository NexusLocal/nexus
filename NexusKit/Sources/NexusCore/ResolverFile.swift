import Foundation

// Another app can own /etc/resolver/<tld>, for example Laravel Herd. Only the first line of the
// file tells the two apart. The file of Herd and Valet has a case of its own, because the move from
// Herd takes it over.
public enum ResolverFileOwner: Sendable, Equatable {
    case missing
    case nexus
    case herdOrValet
    case otherApp
}

// Each variant writes its own first line. Nexus Dev then takes the file of the installed Nexus as
// the file of another app, and the other way round. With one line for both, each removed the file
// of the other as an old dev TLD of its own (2026-11-08). The line of Nexus is the line of 0.2.0.
public enum ResolverFile {
    public static let marker = marker(for: .current)
    public static let folder = URL(filePath: "/etc/resolver", directoryHint: .isDirectory)
    // The file of Herd and of Valet: one nameserver line for their dnsmasq on port 53.
    public static let herdAndValetText = "nameserver 127.0.0.1"

    public static func marker(for variant: NexusVariant) -> String {
        "# Written by \(variant.name). \(variant.name) removes this file when you remove \(variant.name)."
    }

    public static func owner(of file: URL) -> ResolverFileOwner {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return .missing
        }

        let contents = try? String(contentsOf: file, encoding: .utf8)

        if contents?.hasPrefix(marker) == true {
            return .nexus
        }

        return isOfHerdOrValet(contents) ? .herdOrValet : .otherApp
    }

    public static func isOfHerdOrValet(_ contents: String?) -> Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines) == herdAndValetText
    }
}
