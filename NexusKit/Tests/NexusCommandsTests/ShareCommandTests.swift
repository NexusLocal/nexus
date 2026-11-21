import ArgumentParser
import Darwin
import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusCommands

struct ShareCommandTests {
    private func parse(_ arguments: [String]) throws -> any ParsableCommand {
        try NexusCommand.parseAsRoot(arguments)
    }

    @Test func shareWithoutOptionsLeavesEachOptionToTheDefaults() throws {
        let start = try #require(try parse(["share"]) as? ShareCommand.Start)

        #expect(start.host == nil)
        #expect(start.shareStart(host: "shop.test") == ShareStart(host: "shop.test"))
        #expect(!start.json)
    }

    @Test func forAndUntilStoppedGiveTheirDuration() throws {
        let hour = try #require(try parse(["share", "shop.test", "--for", "1h"]) as? ShareCommand.Start)
        let open = try #require(try parse(["share", "--until-stopped"]) as? ShareCommand.Start)

        #expect(hour.host == "shop.test")
        #expect(hour.shareStart(host: "shop.test").duration == .oneHour)
        #expect(open.shareStart(host: "shop.test").duration == .untilStopped)
    }

    @Test func forWithUntilStoppedSaysWhy() throws {
        let error = try #require(#expect(throws: (any Error).self) { try parse(["share", "--for", "4h", "--until-stopped"]) })

        #expect(NexusCommand.message(for: error) == ShareText.forOrUntilStopped)
    }

    @Test(arguments: [["share", "--for", "2h"], ["share", "--for", "0"], ["share", "--vite", "dev"]])
    func aWrongValueIsRefused(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try parse(arguments) }
    }

    @Test func theFlagsGiveTheirValues() throws {
        let start = try #require(try parse(["share", "--no-password", "--show-errors", "--vite", "build", "--requests"]) as? ShareCommand.Start)
        let other = try #require(try parse(["share", "--password", "--hide-errors", "--vite", "live", "--no-requests", "--json"]) as? ShareCommand.Start)

        #expect(start.shareStart(host: "shop.test") == ShareStart(host: "shop.test", password: false, hidesErrors: false, viteMode: .build, keepsRequests: true))
        #expect(other.shareStart(host: "shop.test") == ShareStart(host: "shop.test", password: true, hidesErrors: true, viteMode: .live, keepsRequests: false))
        #expect(other.json)
    }

    @Test func anAddressInCapitalsGivesTheLabelInLowerCase() throws {
        let start = try #require(try parse(["share", "shop.test", "--address", "Shop"]) as? ShareCommand.Start)

        #expect(start.shareStart(host: "shop.test") == ShareStart(host: "shop.test", address: .ownDomain, label: "shop"))
    }

    @Test func addressRandomGivesARandomAddressWithoutALabel() throws {
        let start = try #require(try parse(["share", "--address", "random"]) as? ShareCommand.Start)

        #expect(start.shareStart(host: "shop.test") == ShareStart(host: "shop.test", address: .random))
    }

    @Test func anotherAddressIsALabelOnTheOwnDomain() throws {
        let start = try #require(try parse(["share", "shop.test", "--address", "shop"]) as? ShareCommand.Start)

        #expect(start.shareStart(host: "shop.test") == ShareStart(host: "shop.test", address: .ownDomain, label: "shop"))
    }

    @Test func anAddressWithADotSaysWhy() throws {
        let error = try #require(#expect(throws: (any Error).self) { try parse(["share", "--address", "shop.dev"]) })

        #expect(NexusCommand.message(for: error) == ShareText.OwnDomain.labelProblem)
    }

    @Test func stopAndListParse() throws {
        let all = try #require(try parse(["share", "stop", "--all"]) as? ShareCommand.Stop)
        let one = try #require(try parse(["share", "stop", "shop.test"]) as? ShareCommand.Stop)
        let list = try #require(try parse(["share", "list", "--json"]) as? ShareCommand.List)

        #expect(all.all)
        #expect(one.host == "shop.test")
        #expect(list.json)
    }

    @Test func theListShowsTheHostTheAddressTheEndAndTheVisitors() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let open = ShareInfo(host: "shop.test", site: "shop.test", url: "https://calm-river-tree-lamp.trycloudflare.com", state: .open, options: .standard, started: started, visitors: 2, log: "/tmp/cloudflared-shop.test.log")
        let starting = ShareInfo(host: "fix.shop.test", site: "shop.test", workspace: "fix", state: .starting(.openLink), options: .standard, started: started, visitors: 1, log: "/tmp/cloudflared-fix.shop.test.log")

        let lines = ShareCommand.List.lines([open, starting])

        #expect(lines == [
            "shop.test      https://calm-river-tree-lamp.trycloudflare.com  until you stop it  2 visitors",
            "fix.shop.test  opens now                                       until you stop it  1 visitor",
        ])
    }

    @Test func theQRCodeHasLinesOfOneWidthWithItsQuietZone() throws {
        let url = "https://calm-river-tree-lamp.trycloudflare.com"
        let modules = TerminalQRCode.modules(for: url)
        let lines = TerminalQRCode.lines(for: url)
        let size = modules.count + 2 * TerminalQRCode.quietZone

        #expect(modules.count == 33)
        #expect(modules.allSatisfy { $0.count == modules.count })
        #expect(Array(modules[0].prefix(7)) == Array(repeating: true, count: 7))
        #expect(Array(modules[0].suffix(7)) == Array(repeating: true, count: 7))
        #expect(lines.count == (size + 1) / 2)
        #expect(lines.allSatisfy { $0.count == size })
        #expect(lines.first?.allSatisfy { $0 == " " } == true)
    }

    @Test func ctrlCGetsItsUsualEffectAgainWhenTheStartThrows() async throws {
        struct Refused: Error {}

        await #expect(throws: Refused.self) {
            _ = try await InterruptStop.during(host: "shop.test") { () async throws -> Int in
                throw Refused()
            }
        }

        var action = sigaction()
        sigaction(SIGINT, nil, &action)

        #expect(action.__sigaction_u.__sa_handler == nil)
    }

    @Test func theJSONOfALinkHasISOTimes() throws {
        let info = ShareInfo(host: "shop.test", site: "shop.test", state: .open, options: .standard, started: Date(timeIntervalSince1970: 1_800_000_000), log: "/tmp/log")

        #expect(try shareJSON(info).contains("\"started\" : \"2027-01-15T08:00:00Z\""))
    }
}
