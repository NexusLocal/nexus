import Foundation

// The texts of the own domain (group 4, 4h). The approved texts come from docs/group4/ux-texts.md.
// The owner approved the other texts in contract 4h.
extension ShareText {
    // The help line about sleep with an own domain (ux-texts.md: "With an own domain the last
    // sentence is ...").
    public static func sleepHelp(ownDomain domain: String) -> String {
        "\(sleepStopsLink) \(ownDomainSleepHelp(domain))"
    }

    public enum OwnDomain {
        // Settings > Sharing and the frames of "Sheet Own Domain".
        public static let title = "Your own domain"
        public static let intro = "Give your links a fixed address on your own domain, for example shop.example.com. The address stays the same for each share and after a sleep. You need a free Cloudflare account and a domain that uses Cloudflare."
        public static let setUp = "Set Up…"
        public static let whichDomain = "Which domain?"
        public static let domainHelp = "Use a separate domain for development. Nexus adds a record for each site to this domain."
        public static let openCloudflare = "Open Cloudflare"
        public static let checkAgain = "Check Again"
        public static let continueButton = "Continue"
        public static let done = "Done"
        public static let disconnect = "Disconnect…"
        public static let keyNote = "Nexus gets a key from Cloudflare. Nexus uses it only for its own tunnel and the addresses of your links."
        public static let removeKey = "Remove the key of Nexus at Cloudflare: My Profile > API Tokens."
        public static let removeKeyLink = "My Profile > API Tokens"
        public static let apiTokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!
        public static let cloudflareURL = URL(string: "https://dash.cloudflare.com/")!
        public static let domainRow = "Domain"
        public static let tunnelRow = "Tunnel"
        public static let addressesRow = "Addresses"
        public static let noAddress = "No address yet"
        public static let editLabel = "Change the name of the address"
        public static let addressHelp = "Gives the link a new random address (random) or a name on your own domain, for example shop."

        public static func step(_ number: Int) -> String {
            "Step \(number) of 3"
        }

        public static func notOnCloudflare(_ domain: String) -> String {
            "\(domain) does not use Cloudflare yet. Add it to Cloudflare and change its nameservers at the company where you bought it. You can also buy a new domain at Cloudflare."
        }

        // The design shows the first sentence as the title of step 2.
        public static let connectTitle = "Connect Nexus to Cloudflare."

        public static func connectHelp(_ domain: String) -> String {
            "Your browser opens. Log in, select \(domain) and click Authorize."
        }

        public static func connectSteps(_ domain: String) -> String {
            "\(connectTitle) \(connectHelp(domain))"
        }

        // The design shows the first sentence as the title of step 3.
        public static let connectedTitle = "Connected."

        public static func connectedHelp(_ domain: String) -> String {
            "Your links can use \(domain) now."
        }

        // The failures of the setup.
        public static let notADomain = "Type a domain, for example example.com."
        public static let loginTimedOut = "Cloudflare did not answer in 10 minutes. Click Try Again to start again."
        public static let noKey = "The login at Cloudflare gave no key to Nexus. Click Try Again to start again."
        public static let keyMissing = "Nexus cannot read its Cloudflare key in the Keychain of this Mac. Disconnect your domain in Settings > Sharing. Then connect it again."
        public static let noAnswer = "Nexus did not reach Cloudflare. Check the network connection of this Mac. Then click Try Again."
        public static let noAnswerAtDisconnect = "Nexus did not reach Cloudflare. Check the network connection of this Mac. Then click Disconnect again."

        public static func noNameservers(_ domain: String) -> String {
            "Nexus found no nameservers for \(domain). Type the main domain of your account at Cloudflare, for example example.com."
        }

        public static func waitsForCloudflare(_ domain: String) -> String {
            "Nexus waits for Cloudflare. Select \(domain) in the browser and click Authorize."
        }

        public static let openPageAgain = "Open the Page Again"

        public static func otherDomain(selected: String, asked: String) -> String {
            "You selected \(selected) at Cloudflare, not \(asked). Nexus did not use that key. Click Try Again and select \(asked)."
        }

        public static func tunnelNotMade(_ name: String, log: String) -> String {
            "Cloudflare did not make the tunnel \(name) for this Mac. \(cloudflaredLog(log))"
        }

        public static func keyNotSaved(_ reason: String) -> String {
            "Nexus cannot save the Cloudflare key in the Keychain of this Mac. \(reason)"
        }

        public static func inUse(_ domain: String) -> String {
            "Nexus uses \(domain) already. Disconnect it in Settings > Sharing first."
        }

        // The failures of a link on the own domain.
        public static let labelProblem = "Use one name without dots, for example shop or shop-dev."

        public static func recordExists(_ address: String) -> String {
            "\(address) is already in your DNS records. Nexus does not change records that it did not make. Choose another name."
        }

        public static func labelInUse(host: String, address: String) -> String {
            "\(host) uses \(address) already. Choose another name."
        }

        public static func recordNotAdded(_ address: String, log: String) -> String {
            "Cloudflare did not add the DNS record \(address). \(cloudflaredLog(log))"
        }

        // Way R: a link that the tunnel did not get (group 4, 4h). It has the form of the texts
        // of the tunnel and of the DNS record above.
        public static func rulesNotChanged(_ name: String, log: String) -> String {
            "Cloudflare did not change the addresses of the tunnel \(name). \(cloudflaredLog(log))"
        }

        // The last sentence of a failure at Cloudflare.
        private static func cloudflaredLog(_ log: String) -> String {
            "The log of the program that makes the public links (cloudflared) is \(log)."
        }

        // Disconnect.
        public static func disconnectTitle(_ domain: String) -> String {
            "Disconnect \(domain)?"
        }

        public static func disconnectMessage(domain: String, tunnel: String, records: [String]) -> String {
            guard !records.isEmpty else {
                return "Nexus stops each link on \(domain). Then Nexus deletes the tunnel \(tunnel). Your DNS records stay as they are."
            }

            return "Nexus stops each link on \(domain). Then Nexus deletes the tunnel \(tunnel) and the DNS records that it made: \(EnglishList.joined(records)). Your other DNS records stay as they are."
        }

        public static func keptRecords(_ records: [String]) -> String? {
            switch records.count {
            case 0:
                nil
            case 1:
                "Nexus did not delete the DNS record \(records[0]). Delete it at Cloudflare if you do not need it."
            default:
                "Nexus did not delete the DNS records \(EnglishList.joined(records)). Delete them at Cloudflare if you do not need them."
            }
        }

        public static func keptTunnel(_ name: String) -> String {
            "Nexus did not delete the tunnel \(name). Delete it at Cloudflare in Networking > Tunnels if you do not need it."
        }

        // The notes after a removal of the domain, in Settings and after nexus uninstall.
        public static func keptLines(records: [String], tunnel: String?) -> [String] {
            [keptRecords(records), tunnel.map(keptTunnel)].compactMap { $0 }
        }

        public static func checkFailedTitle(_ domain: String) -> String {
            "Nexus did not check \(domain)"
        }

        public static func disconnectFailedTitle(_ domain: String) -> String {
            "Nexus did not disconnect \(domain)"
        }

        public static func uninstallStopped(_ domain: String, reason: String) -> String {
            "Nexus did not disconnect \(domain). Nexus stopped the removal and changed nothing else. \(reason)"
        }

        public static func uninstallItem(_ domain: String) -> String {
            "its own domain \(domain) at Cloudflare"
        }

        public static func setupStopped(_ domain: String) -> String {
            "Nexus stopped the setup of \(domain)."
        }

        // The answer of a cancel without a setup. No screen shows it.
        public static let noSetup = "No setup of a domain runs."

        // The lines of activity.log.
        public static func connectedLine(_ domain: String, tunnel: String) -> String {
            "Nexus connected \(domain) with the tunnel \(tunnel)."
        }

        public static func removedLine(_ domain: String, tunnel: String, keptRecords: Int) -> String {
            "Nexus removed \(domain) and the tunnel \(tunnel). \(Count.text(keptRecords, "DNS record")) \(keptRecords == 1 ? "stays" : "stay")."
        }

        public static func removedWithTunnelLine(_ domain: String, tunnel: String, keptRecords: Int) -> String {
            "Nexus removed \(domain). The tunnel \(tunnel) and \(Count.text(keptRecords, "DNS record")) stay at Cloudflare."
        }

        public static func addedRecordLine(host: String, domain: String) -> String {
            "Nexus added a DNS record for \(host) to \(domain)."
        }

        public static func setupTunnelDeletedLine(_ domain: String, tunnel: String) -> String {
            "The setup of \(domain) did not end. So Nexus deleted its new tunnel \(tunnel)."
        }

        public static func setupTunnelKeptLine(_ domain: String, tunnel: String) -> String {
            "The setup of \(domain) did not end. Nexus did not delete its new tunnel \(tunnel). Delete it at Cloudflare in Networking > Tunnels."
        }

        public static func rulesNotChangedLine(_ tunnel: String, reason: String) -> String {
            "Nexus did not change the addresses of the tunnel \(tunnel): \(reason)"
        }
    }
}
