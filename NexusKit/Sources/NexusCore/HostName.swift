import Foundation

public enum HostNameError: Error, Equatable, CustomStringConvertible {
    case invalidHost(String)
    case unsupportedTLD(String)

    public var description: String {
        switch self {
        case .invalidHost(let host):
            "\(host) is not a valid host name. Use letters, digits, hyphens and dots, for example shop.test."
        case .unsupportedTLD(let tld):
            ".\(tld) cannot be the dev TLD. Nexus supports \(HostName.devTLDs.map { ".\($0)" }.joined(separator: ", "))."
        }
    }
}

public enum HostName {
    // Only names that public DNS never uses. A resolver file for a real TLD, such as .com or
    // .dev, would send every lookup of that TLD on this Mac to Nexus.
    public static let devTLDs: Set<String> = ["test", "internal", "localhost"]

    public static func validatedTLD(_ tld: String) throws -> String {
        let tld = tld.lowercased()

        guard devTLDs.contains(tld) else {
            throw HostNameError.unsupportedTLD(tld)
        }

        return tld
    }

    public static func validated(_ host: String) throws -> String {
        let host = host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)

        guard host.utf8.count <= 253, labels.count >= 2, labels.allSatisfy(isValidLabel) else {
            throw HostNameError.invalidHost(host)
        }

        return host
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else {
            return false
        }

        return label.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }
}
