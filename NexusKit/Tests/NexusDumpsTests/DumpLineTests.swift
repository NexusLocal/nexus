import Foundation
import NexusCore
import Testing
@testable import NexusDumps

struct DumpLineTests {
    private func decode(_ line: String) throws -> DumpEvent {
        try DumpLine.decode(Data(line.utf8))
    }

    @Test func aDumpOfACommandKeepsEachField() throws {
        let event = try decode(WireLines.commandDumps[0])

        guard case .dump(let request, let dump) = event else {
            Issue.record("not a dump: \(event)")
            return
        }

        #expect(request == DumpEnvelope(
            id: "7fc34bcf0060",
            kind: .command,
            command: "php /Users/tim/Sites/tools/plain.php",
            cwd: "/Users/tim/Sites/tools",
            root: "/Users/tim/Sites/tools",
            started: Date(timeIntervalSince1970: 1794414394.794107),
            pid: 99714
        ))
        #expect(dump == CaughtDump(
            requestID: "7fc34bcf0060",
            seq: 1,
            time: Date(timeIntervalSince1970: 1794414394.794884),
            kind: .dump,
            file: "/Users/tim/Sites/tools/plain.php",
            line: 5,
            text: "array:1 [\n  \"name\" => \"Nexus\"\n]",
            treeJSON: #"{"kind":"array","count":1,"children":[{"key":"name","kind":"string","value":"Nexus"}]}"#
        ))
        #expect(dump.decodedTree()?.children?.first?.value == "Nexus")
    }

    @Test func aWebRequestGetsItsPathAndQueryAsTheTarget() throws {
        let event = try decode(WireLines.pageDumps[0])

        let header = event.request.header

        #expect(header.kind == .http)
        #expect(header.method == "GET")
        #expect(header.target == "/index.php?action=twice")
        #expect(header.url == "http://127.0.0.1:18431/index.php?action=twice")
        #expect(header.host == "127.0.0.1")
        #expect(header.root == "/Users/tim/Sites/shop/public")
        #expect(header.dumpCount == 0)
    }

    @Test func aCommandGetsItsCommandLineAsTheTarget() throws {
        let header = try decode(WireLines.commandDD).request.header

        #expect(header.target == "php /Users/tim/Sites/tools/stop.php")
        #expect(header.displayMethod == "CLI")
        #expect(header.method == nil)
        #expect(header.root == "/Users/tim/Sites/tools")
    }

    @Test func aDDKeepsItsKind() throws {
        guard case .dump(_, let dump) = try decode(WireLines.pageDD) else {
            Issue.record("not a dump")
            return
        }

        #expect(dump.kind == .dd)
        #expect(dump.label == nil)
    }

    @Test func anEndGivesTheStatusTheExitCodeAndTheDuration() throws {
        let page = try decode(WireLines.pageDDEnd)
        let command = try decode(WireLines.commandDDEnd)

        #expect(page == .end(request: page.request, status: 500, exitCode: nil, duration: 0.000451))
        #expect(command == .end(request: command.request, status: nil, exitCode: 1, duration: 0.003211))
    }

    @Test func aBlockedEventGivesItsReasonAndDetail() throws {
        let event = try decode(WireLines.blocked)

        #expect(event == .blocked(request: event.request, reason: .varDumperFormat, detail: "server"))
        #expect(event.request.host == "127.0.0.1")
    }

    @Test(arguments: [
        (WireLines.pageDumps[0].replacingOccurrences(of: #"{"v":1,"#, with: #"{"v":2,"#), 2),
        (#"{"v":3,"type":"something new"}"#, 3),
    ])
    func anUnknownVersionIsRefusedBeforeTheOtherKeys(line: String, version: Int) {
        #expect(throws: DumpLineError.unknownVersion(version)) {
            try decode(line)
        }
    }

    @Test func anUnknownTypeIsRefused() {
        let line = WireLines.pageEnd.replacingOccurrences(of: #""type":"end""#, with: #""type":"start""#)

        #expect(throws: DumpLineError.unknownType("start")) {
            try decode(line)
        }
    }

    @Test(arguments: [#""id":"","#, ""])
    func aRequestWithoutAnIDIsRefused(id: String) {
        let line = WireLines.pageEnd.replacingOccurrences(of: #""id":"18cffb9d2606","#, with: id)

        #expect(throws: DumpLineError.missingRequestID) {
            try decode(line)
        }
    }

    @Test func aLineThatIsNotJSONIsRefused() {
        #expect(throws: (any Error).self) {
            try decode("Warning: something went wrong")
        }
    }

    // The example of "Exact wire format" in docs/dump-viewer-part2.md.
    private static let entriesLine = #"{"v":1,"type":"entries","request":{"id":"a1b2c3d4e5f6","kind":"http","method":"GET","url":"https://shop.test/checkout","host":"shop.test","root":"/Users/tim/Sites/shop/public","started":1763040728.1,"pid":4242},"entries":[{"seq":4,"time":1763040728.12,"kind":"query","file":"/Users/tim/Sites/shop/app/Http/Controllers/CheckoutController.php","line":38,"label":"mysql","text":"select * from `carts` where `user_id` = 7 limit 1","pattern":"select * from `carts` where `user_id` = ? limit 1","ms":0.84,"truncated":false},{"seq":5,"time":1763040728.13,"kind":"log","file":"/Users/tim/Sites/shop/app/Http/Controllers/OrderController.php","line":77,"label":"error","text":"Order 1042 has no invoice.","tree":"{\"kind\":\"array\",\"count\":0}","detail":"stack","truncated":false},{"seq":6,"time":1763040728.14,"kind":"job","file":"/Users/tim/Sites/shop/app/Http/Controllers/CheckoutController.php","line":63,"label":"queued","text":"App\\Jobs\\SendOrderMail","detail":"redis · default","ref":"9f1c0f6e-uuid-of-the-job","truncated":false}]}"#

    private static let workerRequest = #""request":{"id":"b2c3d4e5f6a1","kind":"job","command":"php artisan queue:work","cwd":"/Users/tim/Sites/shop","root":"/Users/tim/Sites/shop","started":1763040730.2,"pid":4300,"job":{"system":"laravel","name":"App\\Jobs\\SendOrderMail","queue":"default","connection":"redis","uuid":"9f1c0f6e","attempt":1,"maxTries":3}}"#

    @Test func anEntriesLineGivesEachEntryWithItsFields() throws {
        guard case .entries(let request, let entries) = try decode(Self.entriesLine) else {
            Issue.record("not an entries event")
            return
        }

        #expect(request.id == "a1b2c3d4e5f6")
        #expect(request.header.target == "/checkout")
        #expect(entries.map(\.seq) == [4, 5, 6])
        #expect(entries.map(\.kind) == [.query, .log, .job])
        #expect(entries.allSatisfy { entry in entry.requestID == "a1b2c3d4e5f6" && entry.number == 0 })
        #expect(entries[0] == CaughtDump(
            requestID: "a1b2c3d4e5f6",
            seq: 4,
            time: Date(timeIntervalSince1970: 1763040728.12),
            kind: .query,
            file: "/Users/tim/Sites/shop/app/Http/Controllers/CheckoutController.php",
            line: 38,
            label: "mysql",
            text: "select * from `carts` where `user_id` = 7 limit 1",
            milliseconds: 0.84,
            pattern: "select * from `carts` where `user_id` = ? limit 1"
        ))
        #expect(entries[1].treeJSON == #"{"kind":"array","count":0}"#)
        #expect(entries[1].detail == "stack")
        #expect(entries[1].isError)
        #expect(entries[2].text == "App\\Jobs\\SendOrderMail")
        #expect(entries[2].detail == "redis · default")
        #expect(entries[2].ref == "9f1c0f6e-uuid-of-the-job")
        #expect(entries[2].milliseconds == nil)
    }

    @Test func anEntryCanHaveTheIDOfAnActionAsItsRef() throws {
        let line = Self.entriesLine.replacingOccurrences(of: #""ref":"9f1c0f6e-uuid-of-the-job""#, with: #""ref":4711"#)

        guard case .entries(_, let entries) = try decode(line) else {
            Issue.record("not an entries event")
            return
        }

        #expect(entries.last?.ref == "4711")
    }

    @Test(arguments: [
        (#""text":"Order 1042 has no invoice.","#, ""),
        (#""kind":"log""#, #""kind":"trace""#),
        (#""seq":5,"#, #""seq":5,"ms":"slow","#),
        (#""seq":5,"#, #""seq":5,"ref":4.5,"#),
    ])
    func aBadEntryIsLeftOutAndTheOtherEntriesOfItsLineStay(_ original: String, _ replacement: String) throws {
        let line = Self.entriesLine.replacingOccurrences(of: original, with: replacement)

        guard case .entries(_, let entries) = try decode(line) else {
            Issue.record("not an entries event")
            return
        }

        #expect(entries.map(\.seq) == [4, 6])
    }

    @Test func aJobOfAWorkerIsItsOwnRequestWithItsJob() throws {
        let line = #"{"v":1,"type":"entries","# + Self.workerRequest + #","entries":[]}"#

        let header = try decode(line).request.header

        #expect(header.kind == .job)
        #expect(header.target == "App\\Jobs\\SendOrderMail")
        #expect(header.displayMethod == "JOB")
        #expect(header.method == nil)
        #expect(header.root == "/Users/tim/Sites/shop")
        #expect(header.job == JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail", queue: "default", connection: "redis", uuid: "9f1c0f6e", attempt: 1, maxTries: 3, command: "php artisan queue:work"))
    }

    @Test func theJobOfAWorkerKeepsTheCommandLineOfTheWorker() throws {
        let line = #"{"v":1,"type":"entries","# + Self.workerRequest + #","entries":[]}"#
        let withoutCommand = line.replacingOccurrences(of: #""command":"php artisan queue:work","#, with: "")

        let header = try decode(line).request.header
        let headerWithoutCommand = try decode(withoutCommand).request.header

        #expect(header.job?.command == "php artisan queue:work")
        #expect(headerWithoutCommand.job?.command == nil)
        #expect(headerWithoutCommand.job?.queuedBy == nil)
    }

    @Test func aCommandOrAWebRequestHasNoJob() throws {
        let command = DumpEnvelope(id: "c1", kind: .command, command: "php artisan migrate", cwd: "/Users/tim/Sites/shop", started: Date(timeIntervalSince1970: 0))

        #expect(command.header.job == nil)
        #expect(command.header.target == "php artisan migrate")
    }

    @Test func theEndOfAJobGivesItsOutcomeAndTheDroppedQueries() throws {
        let line = #"{"v":1,"type":"end","# + Self.workerRequest + #","status":null,"exit":null,"duration":0.42,"outcome":"failed","droppedQueries":704}"#

        let event = try decode(line)

        #expect(event == .end(request: event.request, status: nil, exitCode: nil, duration: 0.42, outcome: .failed, droppedQueries: 704))
    }

    @Test func anEndWithAnUnknownOutcomeStillEndsTheRequest() throws {
        let line = #"{"v":1,"type":"end","# + Self.workerRequest + #","status":null,"exit":null,"duration":0.42,"outcome":"exploded"}"#

        let event = try decode(line)

        #expect(event == .end(request: event.request, status: nil, exitCode: nil, duration: 0.42))
    }

    @Test func aBlockedEventForSaveQueriesNamesTheConfigFile() throws {
        let line = WireLines.blocked
            .replacingOccurrences(of: #""reason":"var_dumper_format""#, with: #""reason":"savequeries""#)
            .replacingOccurrences(of: #""detail":"server""#, with: #""detail":"/Users/tim/Sites/blog/wp-config.php""#)

        let event = try decode(line)

        #expect(event == .blocked(request: event.request, reason: .savequeries, detail: "/Users/tim/Sites/blog/wp-config.php"))
    }

    @Test func aDumpWithoutItsTextIsRefused() {
        let line = WireLines.commandDD.replacingOccurrences(of: #""text":"\"stop here\"","#, with: "")

        #expect(throws: (any Error).self) {
            try decode(line)
        }
    }
}
