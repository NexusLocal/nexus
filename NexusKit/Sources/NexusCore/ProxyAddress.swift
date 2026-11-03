import Darwin
import Foundation

public enum ProxyAddressError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let text):
            "\(text) is not an address that Nexus can use. Use a port, for example 3000, or an IP address with a port, for example http://127.0.0.1:3000."
        }
    }
}

// The server of a proxy site (D67). A port alone is a server on this Mac. The host is an IP address
// or localhost. nginx looks up a name when it loads its configuration, and a name that does not
// resolve then stops every site. The result is always scheme://host:port. So nginx gets no path, no
// user and no character that it reads in a special way.
public enum ProxyAddress {
    public static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let withHost = !trimmed.isEmpty && trimmed.allSatisfy(\.isASCIIDigit) ? "127.0.0.1:\(trimmed)" : trimmed
        let full = withHost.contains("://") ? withHost : "http://\(withHost)"

        guard let components = URLComponents(string: full), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else {
            throw ProxyAddressError.invalid(text)
        }

        guard ["http", "https"].contains(scheme), host == "localhost" || isIPAddress(host) else {
            throw ProxyAddressError.invalid(text)
        }

        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil, ["", "/"].contains(components.path) else {
            throw ProxyAddressError.invalid(text)
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)

        guard (1...65535).contains(port) else {
            throw ProxyAddressError.invalid(text)
        }

        return "\(scheme)://\(host):\(port)"
    }

    // The port of an address that reaches this Mac, or nil for another computer. 0.0.0.0, each
    // 127 address and each address of a network interface reach this Mac.
    public static func portOnThisMac(of address: String, interfaces: Set<String> = interfaceAddresses()) -> Int? {
        guard let components = URLComponents(string: address), let host = components.host else {
            return nil
        }

        let bare = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        let local = bare == "localhost" || bare == "0.0.0.0" || bare == "::" || bare == "::1" || bare.hasPrefix("127.") || interfaces.contains(bare)

        return local ? components.port : nil
    }

    // The IPv4 and IPv6 addresses of the network interfaces of this Mac.
    public static func interfaceAddresses() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&first) == 0 else {
            return []
        }

        defer { freeifaddrs(first) }

        var addresses: Set<String> = []
        var current = first

        while let interface = current {
            current = interface.pointee.ifa_next

            guard let address = interface.pointee.ifa_addr, [sa_family_t(AF_INET), sa_family_t(AF_INET6)].contains(address.pointee.sa_family) else {
                continue
            }

            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
                addresses.insert(text.split(separator: "%").first.map(String.init) ?? text)
            }
        }

        return addresses
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var buffer = in6_addr()

        if host.hasPrefix("["), host.hasSuffix("]") {
            return inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &buffer) == 1
        }

        return inet_pton(AF_INET, host, &buffer) == 1
    }
}

extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
