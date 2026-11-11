import Foundation
import NexusCore
import Testing
@testable import NexusIPC

struct DumpListTests {
    private static let started = Date(timeIntervalSince1970: 1_762_850_000)

    private static let list = DumpList(
        requests: [
            DumpedRequest(id: "65f1c2a9e3b1", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", host: "shop.test", site: "shop.test", started: started, status: 200, duration: 0.184, dumpCount: 3, hasDD: true),
            DumpedRequest(id: "a1b2c3", kind: .command, target: "php artisan import:products", site: "shop.test", started: started, exitCode: 0, duration: 3.2, dumpCount: 4),
        ],
        settings: DumpSettings(catchDumps: true, pageMode: .always, commands: false),
        blocked: [DumpBlock(host: "blog.test", reason: .userIni, file: "/Users/x/Sites/blog/.user.ini")],
        receiving: true,
        problem: "nexusd cannot open its dump socket."
    )

    @Test func theDumpCountIsTheSumOfTheRequests() {
        #expect(Self.list.dumpCount == 7)
        #expect(DumpList(requests: [], settings: DumpSettings(), receiving: false).dumpCount == 0)
    }

    @Test func aListGoesThroughTheCoding() throws {
        let decoded = try NexusMessageCoding.decode(DumpList.self, from: NexusMessageCoding.encode(Self.list))

        #expect(decoded == Self.list)
    }
}
