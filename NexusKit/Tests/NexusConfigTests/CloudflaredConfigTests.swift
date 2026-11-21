import Foundation
import Testing
@testable import NexusConfig

struct CloudflaredConfigTests {
    @Test func aQuickLinkGetsTheConfigFileAndTheMetricsPortOfNexus() {
        let config = URL(filePath: "/Users/me/Library/Application Support/Nexus/data/share/cloudflared/config.yml")

        let arguments = CloudflaredConfig.quickLinkArguments(config: config, metricsPort: 18_001, port: 18_000)

        #expect(arguments == ["tunnel", "--no-autoupdate", "--config", "/Users/me/Library/Application Support/Nexus/data/share/cloudflared/config.yml", "--metrics", "127.0.0.1:18001", "--url", "http://127.0.0.1:18000"])
    }

    @Test func theFileOfAQuickLinkNamesNoTunnelAndNoCredentials() {
        let lines = CloudflaredConfig.quickLinkFile.split(separator: "\n").map(String.init)

        #expect(lines.contains("no-autoupdate: true"))
        #expect(lines.contains("grace-period: 2s"))
        #expect(!lines.contains { line in ["tunnel:", "credentials-file:", "origincert:", "ingress:"].contains { line.hasPrefix($0) } })
    }

    @Test(arguments: [CloudflaredConfig.quickLinkFile, CloudflaredConfig.commandFile, CloudflaredConfig.remoteTunnelFile])
    func eachFileOfNexusHasAKeySoCloudflaredDoesNotCallItEmpty(file: String) {
        let keys = file.split(separator: "\n").filter { line in !line.hasPrefix("#") && line.contains(": ") }

        #expect(keys.contains("no-autoupdate: true"))
    }

    @Test func theTunnelOfTheOwnDomainNamesNoTunnelNoRuleAndNoKey() {
        let lines = CloudflaredConfig.remoteTunnelFile.split(separator: "\n").map(String.init)

        #expect(lines.contains("grace-period: 2s"))
        #expect(!lines.contains { line in ["tunnel:", "credentials-file:", "origincert:", "ingress:", "token:"].contains { line.hasPrefix($0) } })
    }

    @Test func theTunnelOfTheOwnDomainRunsWithTheConfigFileAndTheMetricsPortOfNexus() {
        let config = URL(filePath: "/Users/me/Library/Application Support/Nexus/data/share/cloudflared/own-domain.yml")

        let arguments = CloudflaredConfig.ownDomainRunArguments(config: config, metricsPort: 18_002)

        #expect(arguments == ["tunnel", "--no-autoupdate", "--config", "/Users/me/Library/Application Support/Nexus/data/share/cloudflared/own-domain.yml", "--metrics", "127.0.0.1:18002", "run"])
    }

    @Test func theLoginGetsTheConfigFileOfNexusAndNoOtherFlag() {
        let config = URL(filePath: "/Users/me/Library/Application Support/Nexus/data/share/own-domain/config.yml")

        #expect(CloudflaredConfig.loginArguments(config: config) == ["tunnel", "--config", "/Users/me/Library/Application Support/Nexus/data/share/own-domain/config.yml", "login"])
    }

    @Test func noArgumentListOverwritesADNSRecordOrHoldsAKey() {
        let config = URL(filePath: "/tmp/config.yml")
        let lists = [CloudflaredConfig.loginArguments(config: config), CloudflaredConfig.ownDomainRunArguments(config: config, metricsPort: 18_002), CloudflaredConfig.quickLinkArguments(config: config, metricsPort: 18_001, port: 18_000)]

        #expect(!lists.joined().contains { ["--overwrite-dns", "--token", "--credentials-contents", "--origincert"].contains($0) })
    }

    @Test func theRulesComeInTheOrderOfTheHostAndEndWithAnError() {
        let rules = CloudflaredConfig.ingress(["shop.example.com": 18_000, "blog.example.com": 18_001])

        #expect(rules == [
            ["hostname": "blog.example.com", "service": "http://127.0.0.1:18001"],
            ["hostname": "shop.example.com", "service": "http://127.0.0.1:18000"],
            ["service": "http_status:404"],
        ])
    }
}
