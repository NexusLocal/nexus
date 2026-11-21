import Foundation

public enum HostNameError: Error, Equatable, CustomStringConvertible {
    case invalidHost(String)
    case publicHost(String)
    case unsupportedTLD(String)
    case wildcardOutsideDevTLD(String, tld: String)
    case wildcardInHostsFile(String, tld: String)

    public var description: String {
        switch self {
        case .invalidHost(let host):
            "\(host) is not a valid host name. Use letters, digits, hyphens and dots, for example shop.test."
        case .wildcardOutsideDevTLD(let host, let tld):
            "\(host) starts with *. Such a name works only in the dev domain .\(tld), because /etc/hosts has no such names. Use for example *.shop.\(tld)."
        case .wildcardInHostsFile(let host, let tld):
            "\(host) starts with *. Such a name does not work with .\(tld). \(HostName.hostsFileReason(tld)) Add each subdomain as an alias, for example blog.shop.\(tld)."
        case .publicHost(let host):
            "\(host) can be a real name in public DNS, so Nexus does not use it. Use a name that ends in \(HostName.privateSuffixes.sorted().map { ".\($0)" }.joined(separator: ", "))."
        case .unsupportedTLD(let tld):
            ".\(tld) cannot be the dev TLD. Nexus supports \(HostName.devTLDList(conjunction: "and"))."
        }
    }
}

public enum HostName {
    // Only names that public DNS never uses. A resolver file for a real TLD, such as .com or
    // .dev, would send every lookup of that TLD on this Mac to Nexus.
    public static let devTLDsInOrder = ["test", "internal", "localhost", "local"]
    public static let devTLDs = Set(devTLDsInOrder)

    public static func devTLDList(conjunction: String) -> String {
        EnglishList.joined(devTLDsInOrder.map { ".\($0)" }, conjunction: conjunction)
    }

    // macOS sends .local names to Bonjour and not to a resolver file (issue #6). So each name needs
    // its own line in /etc/hosts, and a name with *. cannot work.
    public static func usesHostsFile(_ tld: String) -> Bool {
        tld == "local"
    }

    // The DNS server of Nexus answers each name in the dev TLD, so these names need no line in
    // /etc/hosts and can start with *.
    public static func dnsAnswers(_ host: String, tld: String) -> Bool {
        !usesHostsFile(tld) && (host == tld || host.hasSuffix(".\(tld)"))
    }

    public static func hostsFileReason(_ tld: String) -> String {
        "macOS uses .\(tld) for Bonjour. So it finds .\(tld) names only in /etc/hosts."
    }

    public static func hostsFileNote(_ tld: String) -> String {
        "macOS uses .\(tld) for Bonjour. So Nexus writes each site, alias and workspace into /etc/hosts. Subdomains do not work by themselves. Add each one as an alias of its site, for example blog.shop.\(tld)."
    }

    // The names that Nexus signs a certificate for and writes to /etc/hosts. Any program of the
    // user can ask nexusd for both, so a public name such as github.com would let that program
    // read the HTTPS traffic of Safari and Chrome for that name.
    public static let privateSuffixes: Set<String> = devTLDs.union(["example", "invalid", "home.arpa"])

    // The host that a user means with Shop.test, https://shop.test/ or shop.test:443. A text that
    // is not a URL, for example *.shop.test, stays as it is in small letters.
    public static func plain(_ text: String) -> String {
        URLParts(text)?.host ?? text.trimmingCharacters(in: .whitespaces).lowercased()
    }

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

    // A name that starts with *. covers each name below it, for example the sites of a WordPress
    // network on subdomains (Phase 4, 3g). nginx, Apache and the certificate accept it. Below the
    // *. there must be at least two labels, so *.test is no name.
    public static func validatedAllowingWildcard(_ host: String) throws -> String {
        guard host.hasPrefix("*.") else {
            return try validated(host)
        }

        return "*.\(try validated(String(host.dropFirst(2))))"
    }

    // An alias with *. works only in the dev TLD. The DNS server of Nexus answers each name there,
    // and /etc/hosts has no such names.
    public static func validatedAlias(_ alias: String, tld: String) throws -> String {
        let name = try validatedAllowingWildcard(alias)

        if name.hasPrefix("*.") {
            guard name.hasSuffix(".\(tld)") else {
                throw HostNameError.wildcardOutsideDevTLD(name, tld: tld)
            }

            guard !usesHostsFile(tld) else {
                throw HostNameError.wildcardInHostsFile(name, tld: tld)
            }
        }

        return name
    }

    // A name in the old dev TLD gets the new one: shop.test becomes shop.internal. Another name,
    // for example blog.local, stays as it is.
    public static func movingTLD(_ host: String, from old: String, to new: String) -> String {
        guard host.hasSuffix(".\(old)") else {
            return host
        }

        return "\(host.dropLast(old.count))\(new)"
    }

    // D42: every host keeps its subdomains. The label before the TLD gets the workspace name. So
    // a browser sees a separate site, and no cookie goes between the main site and a workspace. A
    // host outside the dev TLD gets the dev TLD. A long label gives way to the workspace name,
    // because a label has at most 63 characters.
    public static func workspaceHost(_ host: String, workspace: String, tld: String) -> String {
        let name = privateSuffixes.first { host.hasSuffix(".\($0)") }.map { host.dropLast($0.count + 1) } ?? host[...]
        var labels = name.split(separator: ".").map(String.init)
        let label = labels.popLast() ?? host
        let room = 63 - workspace.count - 1
        let kept = String(label.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return (labels + ["\(kept)-\(workspace)", tld]).joined(separator: ".")
    }

    // Makes a DNS label from a folder name: "My Shop_2" becomes "my-shop-2".
    public static func label(from name: String) -> String {
        let lowered = name.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")

        return String(collapsed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // 1 to 63 characters of a-z, 0-9 and -, without - at the start or at the end.
    static func isValidLabel(_ label: some StringProtocol) -> Bool {
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
