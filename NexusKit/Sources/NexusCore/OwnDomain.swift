import Foundation

// The own domain in config/state.json (group 4, 4h). labels maps a local host to its label.
// dnsRecords holds the full names of the records that Nexus made. Only these go at "Disconnect…".
public struct OwnDomainRecord: Codable, Sendable, Equatable {
    public let domain: String
    public let tunnelID: String
    public let tunnelName: String
    public var labels: [String: String]
    public var dnsRecords: [String]
    public var metricsPort: Int

    public init(domain: String, tunnelID: String, tunnelName: String, labels: [String: String] = [:], dnsRecords: [String] = [], metricsPort: Int) {
        self.domain = domain
        self.tunnelID = tunnelID
        self.tunnelName = tunnelName
        self.labels = labels
        self.dnsRecords = dnsRecords
        self.metricsPort = metricsPort
    }

    // The content of each DNS record of Nexus: a CNAME to the tunnel (check E).
    public var tunnelTarget: String {
        "\(tunnelID).cfargotunnel.com"
    }
}

public enum OwnDomainState: Codable, Sendable, Hashable {
    case connecting(loginPage: String?)
    case connected
    // keyMade is true for a failure after the login. Cloudflare then has a key of Nexus.
    case failed(String, keyMade: Bool)
}

// The names of the own domain (group 4, 4h). An address has one level below the domain. The free
// certificate of Cloudflare covers only that level (research 6, section 5).
public enum OwnDomainName {
    // nil for a good label of a host name. Else the text of the problem.
    public static func labelProblem(_ label: String) -> String? {
        HostName.isValidLabel(label) ? nil : ShareText.OwnDomain.labelProblem
    }

    // A typed label in lower case without spaces, as domain(_:tld:) does with a domain. Shop gives
    // shop.
    public static func label(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // The first label of the local host. shop.test gives shop.
    public static func defaultLabel(of host: String) -> String {
        String(host.split(separator: ".").first ?? Substring(host)).lowercased()
    }

    // The domain in lower case without spaces and without the dot at the end. nil for a text that
    // has fewer than two labels or a bad label. nil also for a domain in the TLD of Nexus.
    public static func domain(_ text: String, tld: String) -> String? {
        var domain = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if domain.hasSuffix(".") {
            domain.removeLast()
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        guard labels.count >= 2, labels.allSatisfy({ labelProblem($0) == nil }) else {
            return nil
        }

        guard !HostName.devTLDs.union([tld]).contains(where: { domain.hasSuffix(".\($0)") }) else {
            return nil
        }

        return domain
    }

    public static func address(label: String, domain: String) -> String {
        "\(label).\(domain)"
    }
}
