import Foundation

public enum HostNameError: Error, Equatable, CustomStringConvertible {
    case invalidHost(String)
    case publicHost(String)
    case unsupportedTLD(String)

    public var description: String {
        switch self {
        case .invalidHost(let host):
            "\(host) is not a valid host name. Use letters, digits, hyphens and dots, for example shop.test."
        case .publicHost(let host):
            "\(host) can be a real name in public DNS, so Nexus does not use it. Use a name that ends in \(HostName.privateSuffixes.sorted().map { ".\($0)" }.joined(separator: ", "))."
        case .unsupportedTLD(let tld):
            ".\(tld) cannot be the dev TLD. Nexus supports \(HostName.devTLDs.sorted().map { ".\($0)" }.joined(separator: ", "))."
        }
    }
}

public enum HostName {
    // Only names that public DNS never uses. A resolver file for a real TLD, such as .com or
    // .dev, would send every lookup of that TLD on this Mac to Nexus.
    public static let devTLDs: Set<String> = ["test", "internal", "localhost"]

    // The names that Nexus signs a certificate for and writes to /etc/hosts. Any program of the
    // user can ask nexusd for both, so a public name such as github.com would let that program
    // read the HTTPS traffic of Safari and Chrome for that name.
    public static let privateSuffixes: Set<String> = devTLDs.union(["local", "example", "invalid", "home.arpa"])

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

        guard privateSuffixes.contains(where: { host.hasSuffix(".\($0)") }) else {
            throw HostNameError.publicHost(host)
        }

        return host
    }

    // A name in the old dev TLD gets the new one: shop.test becomes shop.internal. Another name,
    // for example blog.local, stays as it is.
    public static func movingTLD(_ host: String, from old: String, to new: String) -> String {
        guard host.hasSuffix(".\(old)") else {
            return host
        }

        return "\(host.dropLast(old.count))\(new)"
    }

    // Makes a DNS label from a folder name: "My Shop_2" becomes "my-shop-2".
    public static func label(from name: String) -> String {
        let lowered = name.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")

        return String(collapsed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
