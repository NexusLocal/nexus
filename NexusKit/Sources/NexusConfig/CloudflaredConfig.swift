import Foundation

// The config files of cloudflared and its arguments (group 4, 4b and 4h). cloudflared reads only a
// file of Nexus. So a config.yml of the user has no effect. Each file has at least one key, because
// cloudflared logs an error for a file without a key (check E, 2026-11-20). A stop of cloudflared
// waits up to grace-period for open requests. The default of 30 seconds is longer than the stop
// timeout of nexusd.
public enum CloudflaredConfig {
    // The file of a quick link has no tunnel, credentials-file, origincert or ingress key. So
    // cloudflared opens a quick tunnel.
    public static let quickLinkFile = """
        # Nexus writes this file. Each quick link of Nexus reads this file and no other one.
        no-autoupdate: true
        grace-period: 2s

        """

    // The login of the own domain reads this file and no other one (group 4, 4h).
    public static let commandFile = """
        # Nexus writes this file. Each command of the own domain reads this file and no other one.
        no-autoupdate: true

        """

    // The tunnel of the own domain (way R): no tunnel and no rule. Cloudflare keeps the rules. The
    // token of the tunnel comes in TUNNEL_TOKEN.
    public static let remoteTunnelFile = """
        # Nexus writes this file. The tunnel of the own domain reads this file and no other one.
        no-autoupdate: true
        grace-period: 2s

        """

    public static func quickLinkArguments(config: URL, metricsPort: Int, port: Int) -> [String] {
        ["tunnel", "--no-autoupdate", "--config", config.path(percentEncoded: false), "--metrics", "127.0.0.1:\(metricsPort)", "--url", "http://127.0.0.1:\(port)"]
    }

    public static func ownDomainRunArguments(config: URL, metricsPort: Int) -> [String] {
        ["tunnel", "--no-autoupdate", "--config", config.path(percentEncoded: false), "--metrics", "127.0.0.1:\(metricsPort)", "run"]
    }

    public static func loginArguments(config: URL) -> [String] {
        ["tunnel", "--config", config.path(percentEncoded: false), "login"]
    }

    // The ingress rules of a remotely managed tunnel. Each public host gets one rule in the order of
    // the hosts. The last rule is http_status:404. rules maps a public host to the port of its share
    // block.
    public static func ingress(_ rules: [String: Int]) -> [[String: String]] {
        rules.sorted { $0.key < $1.key }.map { ["hostname": $0.key, "service": "http://127.0.0.1:\($0.value)"] } + [["service": "http_status:404"]]
    }
}
