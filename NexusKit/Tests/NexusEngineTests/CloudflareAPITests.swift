import Foundation
import Testing
@testable import NexusEngine

struct CloudflareAPITests {
    static func pem(zone: String = "zone-1", account: String = "account-1", token: String = "secret-token", type: String = "ARGO TUNNEL TOKEN") -> Data {
        let json = Data(#"{"zoneID":"\#(zone)","accountID":"\#(account)","apiToken":"\#(token)","endpoint":""}"#.utf8).base64EncodedString()
        let lines = stride(from: 0, to: json.count, by: 64).map { start in
            String(json.dropFirst(start).prefix(64))
        }

        return Data((["-----BEGIN \(type)-----"] + lines + ["-----END \(type)-----", ""]).joined(separator: "\n").utf8)
    }

    @Test func theCertOfTheLoginGivesTheZoneTheAccountAndTheToken() {
        let cert = CloudflareCert.parse(Self.pem())

        #expect(cert == CloudflareCert(zoneID: "zone-1", accountID: "account-1", apiToken: "secret-token"))
    }

    @Test func aPEMOfAnotherTypeOrWithoutATokenGivesNoCert() {
        #expect(CloudflareCert.parse(Self.pem(type: "CERTIFICATE")) == nil)
        #expect(CloudflareCert.parse(Self.pem(token: "")) == nil)
        #expect(CloudflareCert.parse(Data("no pem".utf8)) == nil)
    }

    @Test func aRequestHasTheMethodThePathTheQueryAndTheToken() throws {
        let request = CloudflareAPI.request("GET", "zones/zone-1/dns_records", query: [URLQueryItem(name: "name", value: "shop.example.com")], token: "secret-token")

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records?name=shop.example.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.httpBody == nil)
    }

    @Test func aRequestWithABodySendsJSON() {
        let request = CloudflareAPI.request("PUT", "accounts/account-1/cfd_tunnel/tunnel-1/configurations", token: "secret-token", body: Data("{}".utf8))

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/client/v4/accounts/account-1/cfd_tunnel/tunnel-1/configurations")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test func anAnswerWithSuccessGivesItsResult() throws {
        let data = Data(#"{"success":true,"errors":[],"messages":[],"result":{"id":"tunnel-1","name":"nexus-macbook-pro"}}"#.utf8)

        struct Tunnel: Decodable, Equatable {
            let id: String
        }

        #expect(try CloudflareAPI.result(Tunnel.self, from: data, status: 200) == Tunnel(id: "tunnel-1"))
        #expect(try CloudflareAPI.result(String.self, from: Data(#"{"success":true,"errors":[],"result":"eyJh"}"#.utf8), status: 200) == "eyJh")
    }

    @Test func anAnswerWithoutSuccessGivesItsStatusAndItsMessages() {
        let data = Data(#"{"success":false,"errors":[{"code":81053,"message":"An A, AAAA, or CNAME record with that host already exists."}],"result":null}"#.utf8)

        #expect(throws: CloudflareAPIError.failed(status: 400, message: "An A, AAAA, or CNAME record with that host already exists.")) {
            try CloudflareAPI.check(data, status: 400)
        }

        #expect(throws: CloudflareAPIError.failed(status: 200, message: "")) {
            try CloudflareAPI.check(Data(#"{"success":false,"errors":[]}"#.utf8), status: 200)
        }
    }

    @Test func theStatusOfARefusalAMissingThingAndANameThatExistsHasItsOwnError() {
        let data = Data(#"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#.utf8)

        #expect(throws: CloudflareAPIError.refused) { try CloudflareAPI.check(data, status: 403) }
        #expect(throws: CloudflareAPIError.refused) { try CloudflareAPI.check(data, status: 401) }
        #expect(throws: CloudflareAPIError.notFound) { try CloudflareAPI.check(data, status: 404) }
        #expect(throws: CloudflareAPIError.conflict) { try CloudflareAPI.check(data, status: 409) }
    }

    @Test func theLoginPageIsTheFirstAddressOfTheDashboard() {
        let log = """
            A browser window should have opened at the following URL:

            https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2Fx

            If the browser failed to open, please visit the URL above directly in your browser.
            https://dash.cloudflare.com/other
            """

        #expect(CloudflaredOutput.loginPage(in: log) == "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2Fx")
        #expect(CloudflaredOutput.loginPage(in: "Please open the following URL and log in with your Cloudflare account:\n\n  https://dash.cloudflare.com/argotunnel?callback=y\n") == "https://dash.cloudflare.com/argotunnel?callback=y")
        #expect(CloudflaredOutput.loginPage(in: "Visit https://dash.cloudflare.com/argotunnel in the browser.\nhttps://example.com/argotunnel") == nil)
    }

    // The end of the log of cloudflared 2026.11.0 after its last poll for the cert.
    static let loginWaitEndedLog = """
        2026-11-21T08:09:41Z ERR Failed to write the certificate.

        Your browser will download the certificate instead. You will have to manually
        copy it to the following path:

        /Users/user/Library/Application Support/Nexus/data/share/own-domain/.cloudflared/cert.pem
         error="Failed to fetch resource"
        Failed to fetch resource

        """

    // The end of the log after a failure of Cloudflare during the wait.
    static let otherLoginErrorLog = #"2026-11-21T08:09:41Z ERR Failed to write the certificate. error="error on request 502: Bad Gateway""#

    @Test func theEndOfTheLastPollIsTheEndOfTheWaitForTheClick() {
        #expect(CloudflaredOutput.loginWaitEnded(in: Self.loginWaitEndedLog))
        #expect(!CloudflaredOutput.loginWaitEnded(in: Self.otherLoginErrorLog))
        #expect(!CloudflaredOutput.loginWaitEnded(in: ""))
    }
}
