import Foundation
import NexusCore
import NexusIPC

// The answer of step 1 of the sheet. Only a failure of nexusd gets the title of text 22.
enum OwnDomainCheckOutcome {
    case checked(OwnDomainCheck)
    case notADomain
    case failed(String?)
}

// The own domain (group 4, 4h). nexusd keeps the domain and runs the setup. The app shows the
// steps. The sample data keeps the domain in the settings.
extension AppModel {
    var ownDomain: OwnDomainInfo? {
        siteList?.ownDomain ?? settings.ownDomain
    }

    // The domain that the links can use. A setup that runs or that failed is not connected.
    var connectedOwnDomain: OwnDomainInfo? {
        ownDomain.flatMap { $0.state == .connected ? $0 : nil }
    }

    // The sample data: not-on-cloudflare.example does not use Cloudflare. Each other domain does.
    func checkOwnDomain(_ text: String) async -> OwnDomainCheckOutcome {
        guard let domain = OwnDomainName.domain(text, tld: settings.tld) else {
            return .notADomain
        }

        guard isLive else {
            let usesCloudflare = domain != "not-on-cloudflare.example"
            let nameservers = usesCloudflare ? ["anna.ns.cloudflare.com", "bob.ns.cloudflare.com"] : ["ns1.example.net", "ns2.example.net"]
            return .checked(OwnDomainCheck(domain: domain, usesCloudflare: usesCloudflare, nameservers: nameservers))
        }

        switch await outcome(of: .checkOwnDomain(domain: domain)) {
        case .answer(.ownDomainCheck(let check)):
            return .checked(check)
        case .failure(let message):
            return .failed(message)
        default:
            return .failed(nil)
        }
    }

    // nil when nexusd started the setup. Else the problem for the sheet.
    func connectOwnDomain(_ text: String) async -> String? {
        guard let domain = OwnDomainName.domain(text, tld: settings.tld) else {
            return ShareText.OwnDomain.notADomain
        }

        guard isLive else {
            settings.ownDomain = OwnDomainInfo(domain: domain, tunnelName: "nexus-macbook-pro", state: .connected)
            return nil
        }

        if case .failure(let message)? = await outcome(of: .connectOwnDomain(domain: domain)) {
            return message
        }

        return nil
    }

    func cancelOwnDomain() {
        guard isLive else {
            if connectedOwnDomain == nil {
                settings.ownDomain = nil
            }

            return
        }

        Task {
            _ = await outcome(of: .cancelOwnDomain)
        }
    }

    // A failure shows in Settings with the title of text 22.
    func disconnectOwnDomain() async -> OwnDomainRemoval? {
        guard isLive else {
            let addresses = settings.ownDomain?.addresses ?? []
            settings.ownDomain = nil
            return OwnDomainRemoval(removedRecords: addresses, keptRecords: [])
        }

        let domain = ownDomain?.domain ?? ""

        guard case .ownDomainRemoval(let removal)? = await perform(.disconnectOwnDomain, failure: ShareText.OwnDomain.disconnectFailedTitle(domain), place: .settings) else {
            return nil
        }

        return removal
    }
}
