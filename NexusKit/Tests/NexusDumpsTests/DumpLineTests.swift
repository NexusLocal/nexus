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

    @Test func aDumpWithoutItsTextIsRefused() {
        let line = WireLines.commandDD.replacingOccurrences(of: #""text":"\"stop here\"","#, with: "")

        #expect(throws: (any Error).self) {
            try decode(line)
        }
    }
}
