import Foundation
import Testing
@testable import NexusCore

struct OwnDomainTests {
    @Test(arguments: ["shop", "shop-dev", "a1", String(repeating: "a", count: 63)])
    func aGoodLabelHasNoProblem(label: String) {
        #expect(OwnDomainName.labelProblem(label) == nil)
    }

    @Test(arguments: ["", "shop.dev", "-shop", "shop-", "sh_op", "Shop", "shop dev", String(repeating: "a", count: 64)])
    func aBadLabelGetsTheTextOfTheProblem(label: String) {
        #expect(OwnDomainName.labelProblem(label) == "Use one name without dots, for example shop or shop-dev.")
    }

    @Test func theDefaultLabelIsTheFirstLabelOfTheLocalHost() {
        #expect(OwnDomainName.defaultLabel(of: "shop.test") == "shop")
        #expect(OwnDomainName.defaultLabel(of: "cms.shop.test") == "cms")
        #expect(OwnDomainName.defaultLabel(of: "shop-ticket-123.test") == "shop-ticket-123")
    }

    @Test func aDomainLosesItsSpacesItsCapitalsAndItsLastDot() {
        #expect(OwnDomainName.domain(" Example.COM. ", tld: "test") == "example.com")
        #expect(OwnDomainName.domain("dev.example.com", tld: "test") == "dev.example.com")
    }

    @Test(arguments: ["com", "shop.test", "exa mple.com", "https://example.com", "example.com/shop", "*.example.com", "shop.localhost", "printer.local", "example..com", ""])
    func aTextThatIsNotADomainOfTheUserGivesNil(text: String) {
        #expect(OwnDomainName.domain(text, tld: "test") == nil)
    }

    @Test func theAddressIsTheLabelOnTheDomain() {
        #expect(OwnDomainName.address(label: "shop", domain: "example.com") == "shop.example.com")
    }

    @Test func eachMacAndEachVariantHasItsOwnTunnelName() {
        #expect(NexusVariant.release.tunnelName(computer: "Jo’s MacBook Pro") == "nexus-jos-macbook-pro")
        #expect(NexusVariant.dev.tunnelName(computer: "Jo’s MacBook Pro") == "nexus-dev-jos-macbook-pro")
        #expect(NexusVariant.release.tunnelName(computer: "Jo's  Mac (2) ") == "nexus-jos-mac-2")
        #expect(NexusVariant.release.tunnelName(computer: "") == "nexus-mac")
        #expect(NexusVariant.release.tunnelName(computer: "Zoë’s iMac") == "nexus-zo-s-imac")
        #expect(NexusVariant.release.tunnelName(computer: String(repeating: "a", count: 39) + " bc") == "nexus-\(String(repeating: "a", count: 39))")
    }

    @Test func theTextsOfTheSettingsAndTheSheetAreTheApprovedTexts() {
        #expect(ShareText.OwnDomain.title == "Your own domain")
        #expect(ShareText.OwnDomain.intro == "Give your links a fixed address on your own domain, for example shop.example.com. The address stays the same for each share and after a sleep. You need a free Cloudflare account and a domain that uses Cloudflare.")
        #expect(ShareText.OwnDomain.setUp == "Set Up…")
        #expect(ShareText.OwnDomain.whichDomain == "Which domain?")
        #expect(ShareText.OwnDomain.domainHelp == "Use a separate domain for development. Nexus adds a record for each site to this domain.")
        #expect(ShareText.OwnDomain.notOnCloudflare("example.com") == "example.com does not use Cloudflare yet. Add it to Cloudflare and change its nameservers at the company where you bought it. You can also buy a new domain at Cloudflare.")
        #expect(ShareText.OwnDomain.openCloudflare == "Open Cloudflare")
        #expect(ShareText.OwnDomain.checkAgain == "Check Again")
        #expect(ShareText.OwnDomain.connectSteps("example.com") == "Connect Nexus to Cloudflare. Your browser opens. Log in, select example.com and click Authorize.")
        #expect(ShareText.OwnDomain.keyNote == "Nexus gets a key from Cloudflare. Nexus uses it only for its own tunnel and the addresses of your links.")
        #expect("\(ShareText.OwnDomain.connectedTitle) \(ShareText.OwnDomain.connectedHelp("example.com"))" == "Connected. Your links can use example.com now.")
        #expect(ShareText.OwnDomain.disconnect == "Disconnect…")
        #expect(ShareText.OwnDomain.removeKey == "Remove the key of Nexus at Cloudflare: My Profile > API Tokens.")
        #expect(ShareText.OwnDomain.removeKey.contains(ShareText.OwnDomain.removeKeyLink))
        #expect(ShareText.OwnDomain.apiTokensURL.absoluteString == "https://dash.cloudflare.com/profile/api-tokens")
        #expect(ShareText.sleepHelp(ownDomain: "example.com") == "The link works while this Mac is awake and online. After a sleep of more than a few minutes the link stops. Your address on example.com stays the same.")
        #expect(ShareText.OwnDomain.step(2) == "Step 2 of 3")
        #expect(ShareText.OwnDomain.continueButton == "Continue")
        #expect(ShareText.OwnDomain.done == "Done")
        #expect(ShareText.OwnDomain.openPageAgain == "Open the Page Again")
        #expect([ShareText.OwnDomain.domainRow, ShareText.OwnDomain.tunnelRow, ShareText.OwnDomain.addressesRow, ShareText.OwnDomain.noAddress] == ["Domain", "Tunnel", "Addresses", "No address yet"])
        #expect(ShareText.OwnDomain.editLabel == "Change the name of the address")
    }

    @Test func theTextsOfTheSetupAreTheApprovedTexts() {
        #expect(ShareText.OwnDomain.notADomain == "Type a domain, for example example.com.")
        #expect(ShareText.OwnDomain.noNameservers("dev.example.com") == "Nexus found no nameservers for dev.example.com. Type the main domain of your account at Cloudflare, for example example.com.")
        #expect(ShareText.OwnDomain.waitsForCloudflare("example.com") == "Nexus waits for Cloudflare. Select example.com in the browser and click Authorize.")
        #expect(ShareText.OwnDomain.loginTimedOut == "Cloudflare did not answer in 10 minutes. Click Try Again to start again.")
        #expect(ShareText.OwnDomain.noKey == "The login at Cloudflare gave no key to Nexus. Click Try Again to start again.")
        #expect(ShareText.OwnDomain.otherDomain(selected: "other.com", asked: "example.com") == "You selected other.com at Cloudflare, not example.com. Nexus did not use that key. Click Try Again and select example.com.")
        #expect(ShareText.OwnDomain.tunnelNotMade("nexus-macbook-pro", log: "/logs/cloudflared-own-domain.log") == "Cloudflare did not make the tunnel nexus-macbook-pro for this Mac. The log of the program that makes the public links (cloudflared) is /logs/cloudflared-own-domain.log.")
        #expect(ShareText.OwnDomain.keyNotSaved("The user refused.") == "Nexus cannot save the Cloudflare key in the Keychain of this Mac. The user refused.")
        #expect(ShareText.OwnDomain.keyMissing == "Nexus cannot read its Cloudflare key in the Keychain of this Mac. Disconnect your domain in Settings > Sharing. Then connect it again.")
        #expect(ShareText.OwnDomain.inUse("example.com") == "Nexus uses example.com already. Disconnect it in Settings > Sharing first.")
        #expect(ShareText.OwnDomain.noAnswer == "Nexus did not reach Cloudflare. Check the network connection of this Mac. Then click Try Again.")
        #expect(ShareText.OwnDomain.noAnswerAtDisconnect == "Nexus did not reach Cloudflare. Check the network connection of this Mac. Then click Disconnect again.")
        #expect(ShareText.OwnDomain.checkFailedTitle("example.com") == "Nexus did not check example.com")
        #expect(ShareText.OwnDomain.disconnectFailedTitle("example.com") == "Nexus did not disconnect example.com")
        #expect(ShareText.OwnDomain.setupStopped("example.com") == "Nexus stopped the setup of example.com.")
    }

    @Test func theTextsOfTheLinksAreTheApprovedTexts() {
        #expect(ShareText.OwnDomain.labelProblem == "Use one name without dots, for example shop or shop-dev.")
        #expect(ShareText.OwnDomain.recordExists("shop.example.com") == "shop.example.com is already in your DNS records. Nexus does not change records that it did not make. Choose another name.")
        #expect(ShareText.OwnDomain.labelInUse(host: "blog.test", address: "shop.example.com") == "blog.test uses shop.example.com already. Choose another name.")
        #expect(ShareText.OwnDomain.recordNotAdded("shop.example.com", log: "/logs/cloudflared-own-domain.log") == "Cloudflare did not add the DNS record shop.example.com. The log of the program that makes the public links (cloudflared) is /logs/cloudflared-own-domain.log.")
        #expect(ShareText.OwnDomain.addressHelp == "Gives the link a new random address (random) or a name on your own domain, for example shop.")
    }

    @Test func theTextsOfDisconnectAreTheApprovedTexts() {
        #expect(ShareText.OwnDomain.disconnectTitle("example.com") == "Disconnect example.com?")
        #expect(ShareText.OwnDomain.disconnectMessage(domain: "example.com", tunnel: "nexus-macbook-pro", records: ["shop.example.com", "blog.example.com"]) == "Nexus stops each link on example.com. Then Nexus deletes the tunnel nexus-macbook-pro and the DNS records that it made: shop.example.com and blog.example.com. Your other DNS records stay as they are.")
        #expect(ShareText.OwnDomain.disconnectMessage(domain: "example.com", tunnel: "nexus-macbook-pro", records: []) == "Nexus stops each link on example.com. Then Nexus deletes the tunnel nexus-macbook-pro. Your DNS records stay as they are.")
        #expect(ShareText.OwnDomain.keptRecords([]) == nil)
        #expect(ShareText.OwnDomain.keptRecords(["shop.example.com"]) == "Nexus did not delete the DNS record shop.example.com. Delete it at Cloudflare if you do not need it.")
        #expect(ShareText.OwnDomain.keptRecords(["shop.example.com", "blog.example.com"]) == "Nexus did not delete the DNS records shop.example.com and blog.example.com. Delete them at Cloudflare if you do not need them.")
        #expect(ShareText.OwnDomain.keptTunnel("nexus-macbook-pro") == "Nexus did not delete the tunnel nexus-macbook-pro. Delete it at Cloudflare in Networking > Tunnels if you do not need it.")
        #expect(ShareText.OwnDomain.uninstallStopped("example.com", reason: "No network.") == "Nexus did not disconnect example.com. Nexus stopped the removal and changed nothing else. No network.")
        #expect(ShareText.OwnDomain.uninstallItem("example.com") == "its own domain example.com at Cloudflare")
    }

    @Test func theLinesOfTheActivityLogAreTheApprovedLines() {
        #expect(ShareText.OwnDomain.connectedLine("example.com", tunnel: "nexus-macbook-pro") == "Nexus connected example.com with the tunnel nexus-macbook-pro.")
        #expect(ShareText.OwnDomain.removedLine("example.com", tunnel: "nexus-macbook-pro", keptRecords: 2) == "Nexus removed example.com and the tunnel nexus-macbook-pro. 2 DNS records stay.")
        #expect(ShareText.OwnDomain.removedWithTunnelLine("example.com", tunnel: "nexus-macbook-pro", keptRecords: 2) == "Nexus removed example.com. The tunnel nexus-macbook-pro and 2 DNS records stay at Cloudflare.")
        #expect(ShareText.OwnDomain.addedRecordLine(host: "shop.test", domain: "example.com") == "Nexus added a DNS record for shop.test to example.com.")
        #expect(ShareText.OwnDomain.setupTunnelDeletedLine("example.com", tunnel: "nexus-macbook-pro") == "The setup of example.com did not end. So Nexus deleted its new tunnel nexus-macbook-pro.")
        #expect(ShareText.OwnDomain.setupTunnelKeptLine("example.com", tunnel: "nexus-macbook-pro") == "The setup of example.com did not end. Nexus did not delete its new tunnel nexus-macbook-pro. Delete it at Cloudflare in Networking > Tunnels.")
        #expect(ShareText.OwnDomain.rulesNotChangedLine("nexus-macbook-pro", reason: "No answer.") == "Nexus did not change the addresses of the tunnel nexus-macbook-pro: No answer.")
    }
}
